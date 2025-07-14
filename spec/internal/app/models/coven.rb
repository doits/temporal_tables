# frozen_string_literal: true

class Coven < ActiveRecord::Base
  include TemporalTables::HistoryHook
  has_many :people
end
