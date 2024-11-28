# frozen_string_literal: true

class Broom < FlyingMachine
  include TemporalTables::HistoryHook
end
