# frozen_string_literal: true

class CatLife < ActiveRecord::Base
  include TemporalTables::HistoryHook
  belongs_to :cat
end
