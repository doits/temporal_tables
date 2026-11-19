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
