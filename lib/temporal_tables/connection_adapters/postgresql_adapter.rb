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
        all_columns = columns(table_name)
        # A history column that is itself generated (older add_column made those)
        # computes its own value and is left out.
        generated_in_history = columns(temporal_name(table_name)).select { |c| c.try(:virtual?) }.map(&:name)
        column_names = all_columns.map(&:name).sort - generated_in_history
        new_values = column_names.map do |name|
          # new carries no value of a virtual (not stored) column, the row in the
          # table does; Rails cannot tell the two kinds apart reliably
          if all_columns.find { |c| c.name == name }.try(:virtual?)
            "(select #{quote_column_name(name)} from #{table} where #{key} = new.#{key})"
          else
            "new.#{quote_column_name(name)}"
          end
        end.join(', ')
        # Touch columns, and generated ones that follow other columns, make no
        # change alone, and coalescing does not count them.
        ignored = (column_names & TOUCH_COLUMNS) |
                  configured_columns(TemporalTables.touch_columns, table_name, column_names) |
                  all_columns.select { |c| c.try(:virtual?) }.map(&:name)
        ignored -= [primary_key.to_s]
        # *= compares binary images: it needs no equality operator (json, point
        # and xml have none) and tells 1.0 from 1.00. A column's type changes
        # through change_column, which creates the triggers anew.
        skip_touch = <<~SQL if TemporalTables.skip_touch_versions
          new_row := new;
          old_row := old;
          #{copy_columns(ignored)}
          if new_row *= old_row then
            -- a version begun in this transaction still takes the new values
            update #{history} set (#{column_list(column_names)}) = row(#{new_values})
            where #{key} = new.#{key}
              and eff_to = '#{TemporalTables::END_OF_TIME}' and eff_from = now() at time zone 'utc';
            return null;
          end if;
        SQL
        coalescing = coalesce_versions_sql(table_name, column_names, ignored, key, new_values)
        # a version begun in this transaction keeps its mark only for the same change
        same_mark = <<~SQL.squish if coalescing
          , eff_edited_column = case when eff_edited_column = edited_column then edited_column end,
            eff_edited_from = case when eff_edited_column = edited_column then eff_edited_from end
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
              edited_column text;
              changed_paths text[];
              open_from timestamp without time zone;
            begin
              #{skip_touch}
              cur_time := now() at time zone 'utc';
              #{coalescing&.fetch(:detect)}

              -- a version begun in this transaction would last no time, so it takes the update
              update #{history} set (#{column_list(column_names)}) = row(#{new_values})
                #{same_mark}
              where #{key} = new.#{key}
                and eff_to = '#{TemporalTables::END_OF_TIME}' and eff_from = cur_time;
              if found then
                return null;
              end if;
              #{coalescing&.fetch(:coalesce)}
              update #{history} set eff_to = cur_time
              where #{key} = new.#{key}
                and eff_to = '#{TemporalTables::END_OF_TIME}';

              insert into #{history} (#{column_list(column_names)}, eff_from#{', eff_edited_column' if coalescing})
              values (#{new_values}, cur_time#{', edited_column' if coalescing});

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

      # An update that changes one coalesced column alone - in a jsonb column one
      # leaf alone - marks its version with it in eff_edited_column. It
      # goes into the open version instead when that carries the same mark, has
      # the same writer and began within the window: the version moves to the
      # update and the one before it ends there.
      def coalesce_versions_sql(table_name, column_names, ignored, key, new_values) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        window = TemporalTables.coalesce_versions_within
        return unless window

        seconds = Integer(window)
        raise ArgumentError, "coalesce_versions_within must be positive: #{window.inspect}" unless seconds.positive?
        # history tables from before these columns coalesce nothing
        return unless (columns(temporal_name(table_name)).map(&:name) & %w[eff_edited_column eff_edited_from]).size == 2

        coalesced = configured_columns(TemporalTables.coalesce_columns, table_name, column_names) - ignored
        return if coalesced.empty?

        jsonb = columns(table_name).select { |c| c.sql_type == 'jsonb' && !c.array }.map(&:name)
        history = quote_table_name(temporal_name(table_name))
        open_version = "#{key} = new.#{key} and eff_to = '#{TemporalTables::END_OF_TIME}'"

        detect = coalesced.map do |column|
          mark = jsonb.include?(column) ? mark_changed_leaf_sql(column) : "edited_column := #{quote(column)};"
          <<~SQL
            new_row := new;
            old_row := old;
            #{copy_columns(ignored)}
            if not new_row *= old_row then
              #{copy_columns([column])}
              if new_row *= old_row then
                #{mark}
              end if;
            end if;
          SQL
        end.join

        coalesce = <<~SQL
          if edited_column is not null then
            select eff_from into open_from from #{history}
            where #{open_version} and eff_edited_column = edited_column
              and eff_from > cur_time - interval '#{seconds} seconds'
              #{'and updated_by is not distinct from new.updated_by' if column_names.include?('updated_by')};
            if found then
              update #{history} set eff_to = cur_time where #{key} = new.#{key} and eff_to = open_from;
              update #{history}
              set (#{column_list(column_names)}, eff_from) = (#{new_values}, cur_time),
                eff_edited_from = coalesce(eff_edited_from, eff_from)
              where #{open_version};
              return null;
            end if;
          end if;
        SQL

        { detect: detect, coalesce: coalesce }
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

      # Finds the paths of the changed leaves, descending where both values are
      # objects, so arrays, scalars and missing values are leaves.
      def mark_changed_leaf_sql(column) # rubocop:disable Metrics/MethodLength
        objects = "coalesce(jsonb_typeof(walk.a) = 'object' and jsonb_typeof(walk.b) = 'object', false)"
        # a dot in a key is escaped, so no key reads as a nested path
        escaped_key = "replace(replace(kv.k, chr(92), chr(92) || chr(92)), '.', chr(92) || '.')"
        # Each object is expanded once and only a changed one descended into:
        # walking key by key reads the whole document again for every key.
        <<~SQL
          changed_paths := (
            with recursive walk (path, a, b) as (
              select ''::text, old.#{quote_column_name(column)}, new.#{quote_column_name(column)}
              union all
              select walk.path || '.' || #{escaped_key}, kv.a, kv.b
              from walk, lateral (
                select coalesce(x.key, y.key), x.value, y.value
                from jsonb_each(case when #{objects} then walk.a end) x
                full join jsonb_each(case when #{objects} then walk.b end) y on x.key = y.key
              ) kv (k, a, b)
              where #{objects} and walk.a <> walk.b
            )
            select array_agg(path) from walk
            where not #{objects} and walk.a is distinct from walk.b
          );
          if cardinality(changed_paths) = 1 then
            edited_column := #{quote(column)} || changed_paths[1];
          end if;
        SQL
      end

      # Every table's triggers are created anew in old migrations too, against
      # the schema of their time, so an entry that does not match is skipped.
      def configured_columns(setting, table_name, column_names)
        Array(setting).filter_map do |entry|
          table_of_entry, _, column = entry.to_s.rpartition('.')
          column if ['', table_name.to_s].include?(table_of_entry) && column_names.include?(column)
        end.uniq
      end

      # A copied value, unlike null, satisfies a not-null domain.
      def copy_columns(column_names)
        column_names.map { |c| "new_row.#{quote_column_name(c)} := old_row.#{quote_column_name(c)};" }.join(' ')
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
