# frozen_string_literal: true

module TemporalTables
  module ConnectionAdapters
    module PostgreSQLAdapter
      def drop_temporal_triggers(table_name)
        execute "drop trigger #{table_name}_ai on #{table_name}"
        execute "drop trigger #{table_name}_au on #{table_name}"
        execute "drop trigger #{table_name}_ad on #{table_name}"

        # remove functions that where created, too
        execute "drop function #{table_name}_ai()"
        execute "drop function #{table_name}_au()"
        execute "drop function #{table_name}_ad()"

        drop_updated_by_triggers table_name
      end

      def create_temporal_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        column_names = columns(table_name).reject { |col| col.try(:virtual?) }.map(&:name).sort

        execute %{
          create or replace function #{table_name}_ai() returns trigger as $#{table_name}_ai$
            declare
              cur_time timestamp without time zone;
            begin
              cur_time := localtimestamp;

              insert into #{temporal_name(table_name)} (#{column_list(column_names)}, eff_from)
              values (#{column_names.collect { |c| "new.#{c}" }.join(', ')}, cur_time);

              return null;
            end
          $#{table_name}_ai$ language plpgsql;

          drop trigger if exists #{table_name}_ai on #{table_name};
          create trigger #{table_name}_ai after insert on #{table_name}
          for each row execute procedure #{table_name}_ai();
        }

        execute %{
          create or replace function #{table_name}_au() returns trigger as $#{table_name}_au$
            declare
              cur_time timestamp without time zone;
            begin
              cur_time := localtimestamp;

              update #{temporal_name(table_name)} set eff_to = cur_time
              where #{primary_key} = new.#{primary_key}
                and eff_to = '#{TemporalTables::END_OF_TIME}';

              insert into #{temporal_name(table_name)} (#{column_list(column_names)}, eff_from)
              values (#{column_names.collect { |c| "new.#{c}" }.join(', ')}, cur_time);

              return null;
            end
          $#{table_name}_au$ language plpgsql;

          drop trigger if exists #{table_name}_au on #{table_name};
          create trigger #{table_name}_au after update on #{table_name}
          for each row execute procedure #{table_name}_au();
        }

        execute %{
          create or replace function #{table_name}_ad() returns trigger as $#{table_name}_ad$
            declare
              cur_time timestamp without time zone;
            begin
              cur_time := localtimestamp;

              update #{temporal_name(table_name)} set eff_to = cur_time
              where #{primary_key} = old.#{primary_key}
                and eff_to = '#{TemporalTables::END_OF_TIME}';

              return null;
            end
          $#{table_name}_ad$ language plpgsql;

          drop trigger if exists #{table_name}_ad on #{table_name};
          create trigger #{table_name}_ad after delete on #{table_name}
          for each row execute procedure #{table_name}_ad();
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
      def create_updated_by_triggers(table_name, primary_key) # rubocop:disable Metrics/MethodLength
        execute %{
          create or replace function #{table_name}_bu_mark() returns trigger as $#{table_name}_bu_mark$
            begin
              perform set_config('temporal_tables.updated_by_set', new.#{primary_key}::text, true);
              return new;
            end
          $#{table_name}_bu_mark$ language plpgsql;

          drop trigger if exists #{table_name}_bu_mark on #{table_name};
          create trigger #{table_name}_bu_mark before update of updated_by on #{table_name}
          for each row execute procedure #{table_name}_bu_mark();

          create or replace function #{table_name}_bu_reset() returns trigger as $#{table_name}_bu_reset$
            begin
              if current_setting('temporal_tables.updated_by_set', true) is distinct from new.#{primary_key}::text then
                new.updated_by := null;
              end if;
              perform set_config('temporal_tables.updated_by_set', '', true);
              return new;
            end
          $#{table_name}_bu_reset$ language plpgsql;

          drop trigger if exists #{table_name}_bu_reset on #{table_name};
          create trigger #{table_name}_bu_reset before update on #{table_name}
          for each row execute procedure #{table_name}_bu_reset();
        }
      end

      def drop_updated_by_triggers(table_name)
        %w[bu_mark bu_reset].each do |name|
          execute "drop trigger if exists #{table_name}_#{name} on #{table_name}"
          execute "drop function if exists #{table_name}_#{name}()"
        end
      end

      def column_list(column_names)
        column_names.map { |c| "\"#{c}\"" }.join(', ')
      end
    end
  end
end
