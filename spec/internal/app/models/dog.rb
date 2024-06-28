# frozen_string_literal: true

class Dog < ActiveRecord::Base
  include TemporalTables::HistoryHook
  self.primary_key = :dog_id
end
