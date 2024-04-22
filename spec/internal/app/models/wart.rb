# frozen_string_literal: true

class Wart < ActiveRecord::Base
  include TemporalTables::HistoryHook
  belongs_to :person

  scope :very_hairy, lambda {
    where(arel_table[:hairiness].gteq(3))
  }
end
