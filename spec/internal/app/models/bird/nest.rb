# frozen_string_literal: true

class Bird::Nest < ActiveRecord::Base
  self.table_name = 'nests'
  include TemporalTables::HistoryHook
  belongs_to :bird, inverse_of: :nest
end
