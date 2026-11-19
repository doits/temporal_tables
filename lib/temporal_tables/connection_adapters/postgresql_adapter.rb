# frozen_string_literal: true

module TemporalTables
  module ConnectionAdapters
    module PostgreSQLAdapter # rubocop:disable Metrics/ModuleLength
      def drop_temporal_triggers(table_name)
        %w[ai au ad].each do |name|
          execute "drop trigger #{temporal_trigger(table_name, name)} on #{quote_table_name(table_name)}"
          execute "drop function #{temporal_function(table_name, name)}()"
        end

        drop_updated_by_triggers table_name
      end

      # a touch bumps lock_version too, any other update changes something else
      TOUCH_COLUMNS = %w[updated_at updated_by lock_version].freeze

      def create_temporal_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        table = quote_table_name(table_name)
        history = quote_table_name(temporal_name(table_name))
        key = quote_column_name(primary_key)
        # A generated column's history copy is a plain one taking its value; one
        # that add_column once made generated in the history table, too, is left out.
        generated_in_history = columns(temporal_name(table_name)).select { |c| c.try(:virtual?) }.map(&:name)
        generated_columns = columns(table_name).select { |c| c.try(:virtual?) }.map(&:name)
        live_columns = columns(table_name).reject { |c| generated_in_history.include?(c.name) }.sort_by(&:name)
        column_names = live_columns.map(&:name)
        new_values = live_columns.map do |c|
          # new carries no value of a virtual (not stored) column, the row in the table does
          if c.try(:virtual?) && !c.try(:virtual_stored?)
            "(select #{quote_column_name(c.name)} from #{table} where #{key} = new.#{key})"
          else
            "new.#{quote_column_name(c.name)}"
          end
        end.join(', ')
        touch_columns = column_names & TOUCH_COLUMNS
        # *= compares binary images: it needs no equality operator (json, point
        # and xml have none) and tells 1.0 from 1.00. Whole rows, unlike single
        # fields, keep the cached plan valid when a column changes its type.
        skip_touch = <<~SQL if TemporalTables.skip_touch_versions
          new_row := new;
          old_row := old;
          #{touch_columns.map { |c| "new_row.#{c} := null; old_row.#{c} := null;" }.join("\n")}
          if new_row *= old_row then
            return null;
          end if;
        SQL

        coalesce = coalesce_versions_sql(table_name, column_names, generated_columns, key, new_values)

        execute %{
          create or replace function #{temporal_function(table_name, 'ai')}() returns trigger as $function$
            declare
              cur_time timestamp without time zone;
            begin
              cur_time := now() at time zone 'utc';

              insert into #{history} (#{column_list(column_names)}, eff_from)
              values (#{new_values}, cur_time);

              return null;
            end
          $function$ language plpgsql;

          drop trigger if exists #{temporal_trigger(table_name, 'ai')} on #{table};
          create trigger #{temporal_trigger(table_name, 'ai')} after insert on #{table}
          for each row execute procedure #{temporal_function(table_name, 'ai')}();
        }

        execute %{
          create or replace function #{temporal_function(table_name, 'au')}() returns trigger as $function$
            declare
              cur_time timestamp without time zone;
              new_row record;
              old_row record;
              open_version record;
              previous_version record;
              open_row record;
              previous_row record;
            begin
              #{skip_touch}
              cur_time := now() at time zone 'utc';
              #{coalesce}
              update #{history} set eff_to = cur_time
              where #{key} = new.#{key}
                and eff_to = '#{TemporalTables::END_OF_TIME}';

              insert into #{history} (#{column_list(column_names)}, eff_from)
              values (#{new_values}, cur_time);

              return null;
            end
          $function$ language plpgsql;

          drop trigger if exists #{temporal_trigger(table_name, 'au')} on #{table};
          create trigger #{temporal_trigger(table_name, 'au')} after update on #{table}
          for each row execute procedure #{temporal_function(table_name, 'au')}();
        }

        execute %{
          create or replace function #{temporal_function(table_name, 'ad')}() returns trigger as $function$
            declare
              cur_time timestamp without time zone;
            begin
              cur_time := now() at time zone 'utc';

              update #{history} set eff_to = cur_time
              where #{key} = old.#{key}
                and eff_to = '#{TemporalTables::END_OF_TIME}';

              return null;
            end
          $function$ language plpgsql;

          drop trigger if exists #{temporal_trigger(table_name, 'ad')} on #{table};
          create trigger #{temporal_trigger(table_name, 'ad')} after delete on #{table}
          for each row execute procedure #{temporal_function(table_name, 'ad')}();
        }

        if TemporalTables.add_updated_by_field && column_names.include?('updated_by')
          create_updated_by_triggers table_name, primary_key
        else
          drop_updated_by_triggers table_name
        end
      end

      # An update that changes one coalesced column alone goes into the open
      # version when the same writer's change of that column alone made it within
      # the window: the version moves to the update and the one before it ends
      # there. Versions of an insert or of other columns are never overwritten.
      def coalesce_versions_sql(table_name, column_names, generated_columns, key, new_values) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        window = TemporalTables.coalesce_versions_within
        return unless window

        seconds = Integer(window)
        raise ArgumentError, "coalesce_versions_within must be positive: #{window.inspect}" unless seconds.positive?

        # Every table's triggers are created anew in old migrations too, against
        # the schema of their time, so an entry that does not match is skipped.
        coalesced = Array(TemporalTables.coalesce_columns).filter_map do |entry|
          table_of_entry, _, column = entry.to_s.rpartition('.')
          column if ['', table_name.to_s].include?(table_of_entry) && column_names.include?(column)
        end
        return if coalesced.empty?

        history = quote_table_name(temporal_name(table_name))
        open_version = "#{key} = new.#{key} and eff_to = '#{TemporalTables::END_OF_TIME}'"
        # A zero-length version of two updates in one transaction ends there, too.
        previous_version = "#{key} = new.#{key} and eff_to = open_version.eff_from and eff_from < open_version.eff_from"
        ignored = (column_names & TOUCH_COLUMNS) | generated_columns
        history_only = columns(temporal_name(table_name)).map(&:name) - column_names
        # the phase's first edit, kept where the history table has the column
        edited_from = history_only.include?('eff_edited_from')
        nulls = ->(rows, names) { rows.product(names).map { |r, c| "#{r}.#{quote_column_name(c)} := null;" }.join(' ') }

        coalesced.uniq.map { |column| <<~SQL }.join
          new_row := new;
          old_row := old;
          #{nulls.call(%w[new_row old_row], ignored)}
          if not new_row *= old_row then
            #{nulls.call(%w[new_row old_row], [column])}
            if new_row *= old_row then
              select * into open_version from #{history}
              where #{open_version} and eff_from > cur_time - interval '#{seconds} seconds'
                #{'and updated_by is not distinct from new.updated_by' if column_names.include?('updated_by')};
              if found then
                select * into previous_version from #{history}
                where #{previous_version} order by eff_from desc limit 1;
                if found then
                  open_row := open_version;
                  previous_row := previous_version;
                  #{nulls.call(%w[open_row previous_row], ignored | history_only)}
                  if not open_row *= previous_row then
                    #{nulls.call(%w[open_row previous_row], [column])}
                    if open_row *= previous_row then
                      update #{history} set eff_to = cur_time where #{previous_version};
                      update #{history}
                      set (#{column_list(column_names)}, eff_from) = (#{new_values}, cur_time)
                        #{', eff_edited_from = coalesce(eff_edited_from, eff_from)' if edited_from}
                      where #{open_version};
                      return null;
                    end if;
                  end if;
                end if;
              end if;
            end if;
          end if;
        SQL
      end

      # An UPDATE that does not set updated_by itself - update_columns,
      # update_all, a counter cache, raw SQL - stores nil rather than keeping
      # the previous writer's. Only an "update of" trigger sees which columns a
      # statement sets, so it marks the row for the one firing after it, in
      # name order.
      def create_updated_by_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength
        table = quote_table_name(table_name)
        key = quote_column_name(primary_key)

        execute %{
          create or replace function #{temporal_function(table_name, 'bu_mark')}() returns trigger as $function$
            begin
              perform set_config('temporal_tables.updated_by_set', new.#{key}::text, true);
              return new;
            end
          $function$ language plpgsql;

          drop trigger if exists #{temporal_trigger(table_name, 'bu_mark')} on #{table};
          create trigger #{temporal_trigger(table_name, 'bu_mark')} before update of updated_by on #{table}
          for each row execute procedure #{temporal_function(table_name, 'bu_mark')}();

          create or replace function #{temporal_function(table_name, 'bu_reset')}() returns trigger as $function$
            begin
              if current_setting('temporal_tables.updated_by_set', true) is distinct from new.#{key}::text then
                new.updated_by := null;
              end if;
              perform set_config('temporal_tables.updated_by_set', '', true);
              return new;
            end
          $function$ language plpgsql;

          drop trigger if exists #{temporal_trigger(table_name, 'bu_reset')} on #{table};
          create trigger #{temporal_trigger(table_name, 'bu_reset')} before update on #{table}
          for each row execute procedure #{temporal_function(table_name, 'bu_reset')}();
        }
      end

      def drop_updated_by_triggers(table_name)
        %w[bu_mark bu_reset].each do |name|
          execute "drop trigger if exists #{temporal_trigger(table_name, name)} on #{quote_table_name(table_name)}"
          execute "drop function if exists #{temporal_function(table_name, name)}()"
        end
      end

      def column_list(column_names)
        column_names.map { |c| quote_column_name(c) }.join(', ')
      end

      # A trigger lives in its table's schema, so its name carries none.
      def temporal_trigger(table_name, suffix)
        name = ActiveRecord::ConnectionAdapters::PostgreSQL::Utils.extract_schema_qualified_name(table_name.to_s)
        quote_column_name("#{name.identifier}_#{suffix}")
      end

      def temporal_function(table_name, suffix)
        quote_table_name("#{table_name}_#{suffix}")
      end
    end
  end
end
