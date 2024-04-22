# frozen_string_literal: true

class HamsterWheel < ActiveRecord::Base
  include TemporalTables::HistoryHook
  belongs_to :hamster, foreign_key: :hamster_uuid, primary_key: :uuid, inverse_of: :hamster_wheel
end
