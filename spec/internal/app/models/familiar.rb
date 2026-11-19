# frozen_string_literal: true

class Familiar < ActiveRecord::Base
  include TemporalTables::HistoryHook
  include TemporalTables::Whodunnit

  # There is no Hat, so the history class cannot be built.
  has_many :hats, dependent: nil
end
