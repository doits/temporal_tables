# frozen_string_literal: true

require 'spec_helper'

describe 'PostgreSQL triggers' do # rubocop:disable RSpec/DescribeClass
  let(:connection) { ActiveRecord::Base.connection }

  before do
    skip 'PostgreSQL only' unless TemporalTables::DatabaseHelper.adapter_name == 'postgresql'
  end

  describe 'version timestamps' do
    it 'are UTC whatever time zone the session runs in' do
      ActiveRecord::Base.transaction do
        connection.execute "set local time zone 'Pacific/Kiritimati'" # UTC+14
        connection.execute "insert into covens (name) values ('Kiritimati')"
        connection.execute "update covens set name = 'Line Islands'"
        connection.execute 'delete from covens'
      end

      first, last = Coven.history.order(:eff_from, :name).to_a
      expect([first.eff_from, first.eff_to, last.eff_from, last.eff_to]).to all(be_within(1.minute).of(Time.current))
    end
  end

  # rubocop:disable Rails/SkipsModelValidations
  describe 'an update' do
    let!(:familiar) { Familiar.create!(name: 'Greebo') }

    def versions
      connection.select_rows('select name, updated_by from familiars_h order by eff_from, eff_to')
    end

    def touch_only_updates
      Current.user = 'Nanny Ogg'
      familiar.touch
      familiar.update_columns(updated_at: 1.day.from_now)
      connection.execute "update familiars set name = name, updated_by = 'Esme'"
    end

    it 'writes no version when it changes only updated_at, updated_by and lock_version' do
      expect { touch_only_updates }.not_to(change { versions })
    end

    it 'writes a version when it changes anything else' do
      familiar.touch
      Current.user = 'Nanny Ogg'
      familiar.update!(name: 'Greebo the Second')

      expect(versions).to eq([['Greebo', nil], ['Greebo the Second', 'Nanny Ogg']])
    end

    context 'when touch versions are not skipped' do
      around do |example|
        TemporalTables.skip_touch_versions = false
        connection.create_temporal_triggers :familiars, 'id'
        example.run
      ensure
        TemporalTables.skip_touch_versions = true
        connection.create_temporal_triggers :familiars, 'id'
      end

      it 'writes a version for each' do
        count = versions.size
        touch_only_updates
        expect(versions.size).to eq(count + 3)
      end
    end
  end
  # rubocop:enable Rails/SkipsModelValidations

  describe 'an update of columns whose equality is missing or loose' do
    before do
      connection.execute <<~SQL
        insert into potions (strength, label, recipe, origin, effects, updated_at)
        values (1.0, null, '{"newt": 1}', point(1, 2), '<effect>flight</effect>', now())
      SQL
    end

    def versions
      connection.select_value('select count(*) from potions_h')
    end

    it 'writes no version when it changes only updated_at' do
      expect do
        connection.execute <<~SQL
          update potions set updated_at = now() + interval '1 day',
            strength = strength, label = label, recipe = recipe, origin = origin, effects = effects
        SQL
      end.not_to(change { versions })
    end

    {
      'a numeric to another scale' => 'strength = 1.00',
      'a null to a value' => "label = 'Sleep'",
      'a value to null' => 'origin = null',
      'json to another spelling' => %(recipe = '{"newt":1}'),
      'a point' => 'origin = point(1, 3)',
      'xml' => "effects = '<effect>sleep</effect>'"
    }.each do |what, set|
      it "writes a version when it changes #{what}" do
        expect { connection.execute "update potions set #{set}" }.to change { versions }.by(1)
      end
    end
  end

  describe 'an update after columns changed their type' do
    it 'tells a touch from a change with the triggers created before' do
      connection.create_table(:cauldrons, temporal: true) do |t|
        t.integer :size
        t.integer :lock_version, null: false, default: 0
      end
      connection.execute 'insert into cauldrons (size) values (1)'
      connection.execute 'update cauldrons set size = 2'
      connection.change_column :cauldrons, :size, :bigint
      connection.change_column :cauldrons, :lock_version, :bigint
      connection.execute 'update cauldrons set lock_version = lock_version + 1'
      connection.execute 'update cauldrons set size = 3'

      expect(connection.select_values('select size from cauldrons_h order by history_id')).to eq([1, 2, 3])
    ensure
      connection.drop_table :cauldrons
    end
  end
end
