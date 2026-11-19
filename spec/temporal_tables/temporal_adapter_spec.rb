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
  end
end
