# frozen_string_literal: true

require 'spec_helper'

describe TemporalTables::ConnectionAdapters::PostgreSQLAdapter do
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
end
