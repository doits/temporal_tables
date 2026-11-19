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

    it 'writes no version when it changes only updated_at and updated_by' do
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
end
