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

      def create_temporal_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        column_names = columns(table_name).reject { |col| col.try(:virtual?) }.map(&:name).sort
        table = quote_table_name(table_name)
        history = quote_table_name(temporal_name(table_name))
        key = quote_column_name(primary_key)
        new_values = column_names.map { |c| "new.#{quote_column_name(c)}" }.join(', ')
        # a touch bumps lock_version too, any other update changes something else
        touch_columns = column_names & %w[updated_at updated_by lock_version]
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
            begin
              #{skip_touch}
              cur_time := now() at time zone 'utc';

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

      # An UPDATE that does not set updated_by itself - update_columns,
      # update_all, a counter cache, raw SQL - stores nil rather than keeping
      # the previous writer's. Only an "update of" trigger sees which columns a
      # statement sets, so it marks the row for the one firing after it, in
      # name order.
      def create_updated_by_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
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
