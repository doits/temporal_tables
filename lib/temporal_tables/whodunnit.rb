# frozen_string_literal: true

module TemporalTables
  module Whodunnit
    def self.included(base)
      base.class_eval do
        include InstanceMethods

        after_commit :amend_updated_by_for_history
      end
    end

    module InstanceMethods
      def amend_updated_by_for_history
        return unless TemporalTables.updated_by_proc &&
                      respond_to?(:updated_by) &&
                      previous_changes.present? && # only if something was saved to DB
                      history&.table_exists?

        history.klass.where(id:, eff_to: TemporalTables::END_OF_TIME)
          .update_all(updated_by: TemporalTables.updated_by_proc.call(self))
      end
    end
  end
end
