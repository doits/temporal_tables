# frozen_string_literal: true

class Cat < ActiveRecord::Base
  include TemporalTables::HistoryHook
  has_many :lives, class_name: 'CatLife'
end
