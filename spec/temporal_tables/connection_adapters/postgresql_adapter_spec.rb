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

  describe 'an update of a coalesced column' do
    let!(:familiar) { Familiar.create!(name: 'Greebo') }

    around do |example|
      TemporalTables.coalesce_versions_within = 5.minutes
      TemporalTables.coalesce_columns = %w[name familiars.species]
      connection.create_temporal_triggers :familiars, 'id'
      connection.create_temporal_triggers :covens, 'id'
      example.run
    ensure
      TemporalTables.coalesce_versions_within = nil
      TemporalTables.coalesce_columns = []
      TemporalTables.skip_touch_versions = true
      connection.create_temporal_triggers :familiars, 'id'
      connection.create_temporal_triggers :covens, 'id'
    end

    def versions(*columns)
      connection.select_rows("select #{columns.join(', ')} from familiars_h order by eff_from, eff_to")
    end

    # as if every version so far had been written that much earlier
    def age_versions(by)
      connection.execute <<~SQL
        update familiars_h set eff_from = eff_from - interval '#{by.to_i} seconds',
          eff_to = case when eff_to = '#{TemporalTables::END_OF_TIME}' then eff_to
                        else eff_to - interval '#{by.to_i} seconds' end
      SQL
    end

    it 'overwrites the open version a change of the same column made, moving it to the last edit' do
      familiar.update!(name: 'G')
      first_edit = versions(:eff_from).last.first
      familiar.update!(name: 'Gr')
      familiar.update!(name: 'Greebo the Second')

      expect(versions(:name)).to eq([['Greebo'], ['Greebo the Second']])
      last_edit = versions(:eff_from).last.first
      expect(versions(:eff_to).first.first).to eq(last_edit)
      expect(last_edit).to be > first_edit
      expect(versions(:eff_edited_from)).to eq([[nil], [first_edit]])
    end

    it 'keeps the version an insert made' do
      familiar.update!(name: 'Greebo the Second')

      expect(versions(:name)).to eq([['Greebo'], ['Greebo the Second']])
    end

    it 'keeps each step of other columns and the version before it' do
      familiar.update!(name: 'Greebo the Second')
      familiar.update!(status: 'published')
      familiar.update!(name: 'Greebo the Third')
      familiar.update!(name: 'Greebo the Fourth')
      familiar.update!(status: 'cancelled')
      familiar.update!(status: 'deleted')

      expect(versions(:name, :status)).to eq(
        [['Greebo', nil], ['Greebo the Second', nil], ['Greebo the Second', 'published'],
         ['Greebo the Fourth', 'published'], ['Greebo the Fourth', 'cancelled'], ['Greebo the Fourth', 'deleted']]
      )
    end

    it 'keeps the version of another coalesced column, and one of two changed together' do
      familiar.update!(name: 'Greebo the Second')
      familiar.update!(species: 'cat')
      familiar.update!(species: 'tomcat')
      familiar.update!(name: 'Greebo the Third', species: 'vampire cat')

      expect(versions(:name, :species)).to eq(
        [['Greebo', nil], ['Greebo the Second', nil], ['Greebo the Second', 'tomcat'],
         ['Greebo the Third', 'vampire cat']]
      )
    end

    it 'keeps the version of another writer' do
      familiar.update!(name: 'Greebo the Second')
      familiar.update!(name: 'Greebo the Third')
      Current.user = 'Nanny Ogg'
      familiar.update!(name: 'Greebo the Fourth')

      expect(versions(:name, :updated_by)).to eq(
        [['Greebo', nil], ['Greebo the Third', nil], ['Greebo the Fourth', 'Nanny Ogg']]
      )
    end

    it 'keeps a version older than the window, whatever a touch did since' do
      familiar.update!(name: 'Greebo the Second')
      age_versions(6.minutes)
      familiar.touch
      familiar.update!(name: 'Greebo the Third')

      expect(versions(:name)).to eq([['Greebo'], ['Greebo the Second'], ['Greebo the Third']])
    end

    it 'writes no version for a touch' do
      familiar.update!(name: 'Greebo the Second')

      expect { familiar.touch }.not_to(change { versions(:name, :updated_at) })
    end

    it 'keeps the version of a touch and writes one for it when touch versions are not skipped' do
      TemporalTables.skip_touch_versions = false
      connection.create_temporal_triggers :familiars, 'id'
      familiar.update!(name: 'Greebo the Second')
      familiar.touch
      familiar.update!(name: 'Greebo the Third')

      expect(versions(:name)).to eq([['Greebo'], ['Greebo the Second'], ['Greebo the Second'], ['Greebo the Third']])
    end

    it 'keeps the zero-length version of two updates in one transaction' do
      ActiveRecord::Base.transaction do
        familiar.update!(status: 'published')
        familiar.update!(name: 'Greebo the Second')
      end
      familiar.update!(name: 'Greebo the Third')

      expect(versions(:name, :status)).to eq(
        [['Greebo', nil], ['Greebo', 'published'], ['Greebo the Second', 'published'],
         ['Greebo the Third', 'published']]
      )
    end

    it 'writes a version for each change without coalesce_versions_within' do
      TemporalTables.coalesce_versions_within = nil
      connection.create_temporal_triggers :familiars, 'id'
      familiar.update!(name: 'Greebo the Second')
      familiar.update!(name: 'Greebo the Third')

      expect(versions(:name)).to eq([['Greebo'], ['Greebo the Second'], ['Greebo the Third']])
    end

    it 'coalesces in a table without updated_at' do
      connection.execute "insert into covens (name) values ('Lancre')"
      connection.execute "update covens set name = 'Lancre Castle'"
      connection.execute "update covens set name = 'Lancre Town'"

      expect(Coven.history.order(:eff_from).pluck(:name)).to eq(['Lancre', 'Lancre Town'])
    end

    it 'skips an entry the table lacks and takes no list at all' do
      TemporalTables.coalesce_columns = %w[familiars.colour]
      expect { connection.create_temporal_triggers :familiars, 'id' }.not_to raise_error
      TemporalTables.coalesce_columns = nil
      expect { connection.create_temporal_triggers :familiars, 'id' }.not_to raise_error
    end

    it 'refuses a window that is no duration' do
      TemporalTables.coalesce_versions_within = '5 minutes'

      expect { connection.create_temporal_triggers :familiars, 'id' }.to raise_error(ArgumentError)
    end

    it 'coalesces in a table, key and column named by reserved words' do
      connection.create_table(:references, primary_key: :check, temporal: true) { |t| t.integer :order }
      TemporalTables.coalesce_columns = %w[references.order]
      connection.create_temporal_triggers :references, 'check'
      connection.execute 'insert into "references" ("order") values (1)'
      (2..4).each { |order| connection.execute %(update "references" set "order" = #{order}) }
      connection.execute 'delete from "references"'

      expect(connection.select_values('select "order" from references_h order by eff_from')).to eq([1, 4])
    ensure
      connection.drop_table :references, if_exists: true
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
