# frozen_string_literal: true

class Spellbook < ActiveRecord::Base
  include TemporalTables::Whodunnit
end
