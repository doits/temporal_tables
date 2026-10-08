# frozen_string_literal: true

module TemporalTables
  # Writes updated_by onto the row itself with every INSERT and UPDATE, so the
  # trigger copies it into each history version.
  module Whodunnit
    private

    def _create_record(*)
      _write_attribute('updated_by', TemporalTables.updated_by_proc.call(self)) if record_updated_by?

      super
    end

    # Reached only once all callbacks have run and a row is actually written,
    # touches included.
    def _update_row(attribute_names, attempted_action = 'update')
      return super unless record_updated_by?

      _write_attribute('updated_by', TemporalTables.updated_by_proc.call(self))
      # as optimistic locking does with its column, so dirty tracking takes it
      # for written rather than left pending
      @_touch_attr_names << 'updated_by' if attempted_action == 'touch'

      super(attribute_names | ['updated_by'], attempted_action)
    end

    def record_updated_by?
      TemporalTables.updated_by_proc && has_attribute?(:updated_by) && history.klass.table_exists?
    end
  end
end
