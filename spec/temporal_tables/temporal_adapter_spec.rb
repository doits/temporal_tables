# frozen_string_literal: true

require 'spec_helper'

describe TemporalTables::TemporalAdapter do
  let(:connection) { ActiveRecord::Base.connection }
  let(:postgres) { TemporalTables::DatabaseHelper.adapter_name == 'postgresql' }

  # Schema changes outlive the example, so each one works on tables of its own.
  before do
    connection.create_table(:spells, temporal: true, force: true) { |t| t.string :name }
  end

  after do
    connection.drop_table :spells, if_exists: true
    connection.drop_table :incantations, if_exists: true
  end

  def history_objects_exist?(table)
    objects = [
      TemporalTables::DatabaseHelper.table_exists?("#{table}_h"),
      *%w[ai au ad].map { |trigger| TemporalTables::DatabaseHelper.trigger_exists?("#{table}_#{trigger}") }
    ]
    objects += %w[ai au ad].map { |f| TemporalTables::DatabaseHelper.function_exists?("#{table}_#{f}()") } if postgres
    raise "#{table} has only some of its history objects: #{objects.inspect}" unless objects.uniq.size == 1

    objects.first
  end

  describe '#drop_table' do
    it 'removes the history table, its triggers and functions, too' do
      expect { connection.drop_table :spells }.to change { history_objects_exist?(:spells) }.from(true).to(false)
    end
  end

  describe '#remove_temporal_table' do
    it 'removes the history table, its triggers and functions' do
      expect { connection.remove_temporal_table :spells }
        .to change { history_objects_exist?(:spells) }.from(true).to(false)
      expect(connection.table_exists?(:spells)).to be(true)
    end
  end

  describe '#rename_table' do
    it 'moves the history table and its triggers to the new name' do
      connection.execute "insert into spells (name) values ('Alohomora')"

      expect { connection.rename_table :spells, :incantations }
        .to change { history_objects_exist?(:spells) }.from(true).to(false)
        .and change { history_objects_exist?(:incantations) }.from(false).to(true)

      connection.execute "update incantations set name = 'Lumos'"
      expect(connection.select_values('select name from incantations_h order by eff_from, name'))
        .to eq(%w[Alohomora Lumos])
    end

    it 'moves the history copies of its indexes along' do
      connection.add_index :spells, :name
      connection.rename_table :spells, :incantations

      expect(connection.indexes(:incantations_h).map(&:name)).to include('index_incantations_on_name_h')

      connection.remove_index :incantations, :name
      expect(connection.indexes(:incantations_h).map(&:name)).not_to include('index_incantations_on_name_h')
    end
  end

  describe '#create_table' do
    it 'keys the history table by history_id, whatever key and default the table has' do
      skip 'PostgreSQL only' unless postgres

      connection.create_table(:incantations, id: :uuid, default: -> { 'gen_random_uuid()' }, temporal: true) do |t|
        t.string :name
      end
      connection.execute "insert into incantations (name) values ('Lumos')"

      expect(connection.primary_key(:incantations_h)).to eq('history_id')
      expect(connection.select_values('select name from incantations_h')).to eq(['Lumos'])
    end
  end

  describe 'a table, key and column named by reserved words' do
    after do
      connection.drop_table :references, if_exists: true
      connection.drop_table :grant, if_exists: true
    end

    it 'keeps its history through a rename and goes with it' do
      connection.create_table(:references, primary_key: :check, temporal: true) { |t| t.integer :order }
      connection.add_index :references, :order
      order = connection.quote_column_name(:order)
      connection.execute "insert into #{connection.quote_table_name(:references)} (#{order}) values (1)"
      connection.rename_table :references, :grant
      connection.execute "update #{connection.quote_table_name(:grant)} set #{order} = 2"
      connection.execute "delete from #{connection.quote_table_name(:grant)}"

      closed_versions = connection.select_values(<<~SQL)
        select #{order} from #{connection.quote_table_name(:grant_h)}
        where eff_to < '#{TemporalTables::END_OF_TIME}' order by #{order}
      SQL
      expect(closed_versions.map(&:to_i)).to eq([1, 2])
      expect { connection.drop_table :grant }.to change { history_objects_exist?(:grant) }.to(false)
    end
  end

  describe 'a column of the history table' do
    def history_column(name)
      connection.columns(:spells_h).find { |c| c.name == name.to_s }
    end

    it 'stays nullable and without default, whatever the live column says' do
      connection.add_column :spells, :power, :integer, null: false, default: 1
      connection.add_column :spells, :school, :string
      connection.change_column :spells, :school, :string, null: false, default: 'charms'

      expect([history_column(:power), history_column(:school)].map { |c| [c.null, c.default] })
        .to eq([[true, nil], [true, nil]])
    end

    it 'takes the NULL a live column allows again' do
      connection.add_column :spells, :power, :integer, null: false, default: 1
      connection.change_column_null :spells, :power, true

      connection.execute "insert into spells (name, power) values ('Nox', null)"
      expect(connection.select_values('select power from spells_h')).to eq([nil])
    end

    it 'keeps the precision and scale of a table that exists already' do
      connection.create_table(:incantations) { |t| t.decimal :power, precision: 4, scale: 2 }
      connection.add_temporal_table :incantations

      power = connection.columns(:incantations_h).find { |c| c.name == 'power' }
      expect([power.precision, power.scale]).to eq([4, 2])
    end
  end

  describe 'a generated column' do
    def double_powers(table)
      connection.select_values("select double_power from #{table}_h order by eff_from, eff_to").map(&:to_i)
    end

    def history_column_generated?(table)
      connection.columns("#{table}_h").find { |c| c.name == 'double_power' }.virtual?
    end

    [true, false].each do |stored|
      # Rails hands back the stored column it read first for a virtual one with
      # the same name and expression, so both kinds share them here.
      context "when #{stored ? 'stored' : 'virtual'}" do
        let(:expression) { 'power * 2' }

        before do
          next if stored || !postgres
          next if connection.database_version >= 180_000 && ActiveRecord.version >= Gem::Version.new('8.1')

          skip 'virtual generated columns need PostgreSQL 18 and Rails 8.1'
        end

        it 'keeps its values in a plain history column, created with the table' do
          connection.create_table(:incantations, temporal: true) do |t|
            t.integer :power
            t.virtual :double_power, type: :integer, as: expression, stored: stored
          end
          connection.execute 'insert into incantations (power) values (2)'
          connection.execute 'update incantations set power = 3'

          expect(double_powers(:incantations)).to eq([4, 6])
          expect(history_column_generated?(:incantations)).to be(false)
        end

        it 'keeps its values in a plain history column, added later' do
          connection.add_column :spells, :power, :integer
          connection.add_column :spells, :double_power, :virtual, type: :integer, as: expression, stored: stored
          connection.execute "insert into spells (name, power) values ('Lumos', 2)"
          connection.execute 'update spells set power = 3'

          expect(double_powers(:spells)).to eq([4, 6])
          expect(history_column_generated?(:spells)).to be(false)
        end
      end
    end

    it 'leaves out a history column that an earlier add_column made generated, too' do
      connection.add_column :spells, :power, :integer
      connection.add_column :spells_h, :double_power, :virtual, type: :integer, as: 'power * 2', stored: true
      generated = postgres ? 'generated always as (power * 2) stored' : 'as (power * 2) stored'
      connection.execute "alter table spells add column double_power integer #{generated}"
      connection.create_temporal_triggers :spells, 'id'
      connection.execute "insert into spells (name, power) values ('Lumos', 2)"
      connection.execute 'update spells set power = 3'

      expect(double_powers(:spells)).to eq([4, 6])
    end
  end
end
