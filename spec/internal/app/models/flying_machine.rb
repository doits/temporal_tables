# frozen_string_literal: true

class FlyingMachine < ActiveRecord::Base
  include TemporalTables::HistoryHook
  belongs_to :person
end
