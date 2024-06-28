# frozen_string_literal: true

class Bird < ActiveRecord::Base
  include TemporalTables::HistoryHook
  has_one :nest, inverse_of: :bird
end
