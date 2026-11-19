# frozen_string_literal: true

module TemporalTables
  module ConnectionAdapters
    module AbstractMysqlAdapter
      def drop_temporal_triggers(table_name)
        %w[ai au ad].each do |name|
          execute "drop trigger #{temporal_trigger(table_name, name)}"
        end
      end

      def create_temporal_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        # A generated column's history copy is a plain one taking its value; one
        # that add_column once made generated in the history table, too, is left out.
        generated_in_history = columns(temporal_name(table_name)).select { |c| c.try(:virtual?) }.map(&:name)
        column_names = columns(table_name).map(&:name).sort - generated_in_history
        table = quote_table_name(table_name)
        history = quote_table_name(temporal_name(table_name))
        key = quote_column_name(primary_key)
        column_list = column_names.map { |c| quote_column_name(c) }.join(', ')
        new_values = column_names.map { |c| "new.#{quote_column_name(c)}" }.join(', ')

        execute "drop trigger if exists #{temporal_trigger(table_name, 'ai')}"
        execute %{
          create trigger #{temporal_trigger(table_name, 'ai')} after insert on #{table}
          for each row
          begin
            set @current_time = utc_timestamp(6);

            insert into #{history} (#{column_list}, eff_from)
            values (#{new_values}, @current_time);

          end
        }

        execute "drop trigger if exists #{temporal_trigger(table_name, 'au')}"
        execute %{
          create trigger #{temporal_trigger(table_name, 'au')} after update on #{table}
          for each row
          begin
            set @current_time = utc_timestamp(6);

            update #{history} set eff_to = @current_time
            where #{key} = new.#{key}
            and eff_to = '#{TemporalTables::END_OF_TIME}';

            insert into #{history} (#{column_list}, eff_from)
            values (#{new_values}, @current_time);

          end
        }

        execute "drop trigger if exists #{temporal_trigger(table_name, 'ad')}"
        execute %{
          create trigger #{temporal_trigger(table_name, 'ad')} after delete on #{table}
          for each row
          begin
            set @current_time = utc_timestamp(6);

            update #{history} set eff_to = @current_time
            where #{key} = old.#{key}
            and eff_to = '#{TemporalTables::END_OF_TIME}';

          end
        }
      end

      def temporal_trigger(table_name, suffix)
        quote_table_name("#{table_name}_#{suffix}")
      end
    end
  end
end
