[![Continuous Integration](https://github.com/bkroeker/temporal_tables/actions/workflows/test.yml/badge.svg)](https://github.com/bkroeker/temporal_tables/actions/workflows/test.yml)

# TemporalTables

Easily recall what your data looked like at any point in the past!  TemporalTables sets up and maintains history tables to track all temporal changes to to your data.

## Installation

Add this line to your application's Gemfile:
``` ruby
gem 'temporal_tables'
```

And then execute:
``` bash
$ bundle
```

Or install it yourself as:
``` bash
$ gem install temporal_tables
```

## Usage

### Schema

In your rails migration, specify that you want a table to have its history tracked:
``` ruby
create_table :people, temporal: true do |t|
  ...
end
```

This will create a history table called "people_h" which will maintain a history of all changes to any records in people with the use of triggers on any create/update/delete operation.

On PostgreSQL an update that changes nothing but `updated_at`, `updated_by` and `lock_version`, such as a `touch`, writes no new version (see `skip_touch_versions` below). Versions are stamped in UTC whatever time zone the database session runs in, so the gem requires `ActiveRecord.default_timezone = :utc` (the Rails default).

Any subsequent schema changes to people will be reflected automatically in people_h. A generated column (`t.virtual`) gets a plain column in people_h that keeps the value each version had; on PostgreSQL the triggers read it back from the row.

``` ruby
# Nothing extra required -- people_h will automatically get an "name" column too!
add_column :people, :name, :string
```

To track the history of a pre-existing table, just call `add_temporal_table`:
``` ruby
add_temporal_table :people
```

Every write to people also writes people_h, so a migration that locks or rewrites people_h blocks writes to people for as long.

### Upgrading existing history tables

History tables created by older versions of the gem lack the `history_id` primary key and the columns `coalesce_columns` needs, may carry `NOT NULL` and defaults on their columns, and run older triggers, which leave generated columns null. Per table, ideally one transaction each:
``` ruby
add_column :people_h, :history_id, :primary_key, if_not_exists: true # rewrites people_h
add_column :people_h, :eff_edited_from, :datetime, limit: 6, if_not_exists: true
add_column :people_h, :eff_edited_column, :string, if_not_exists: true
connection.columns(:people_h).each do |column|
  next if %w[history_id eff_from eff_to eff_edited_from eff_edited_column].include?(column.name) || column.virtual?

  change_column_null :people_h, column.name, true
  change_column_default :people_h, column.name, nil
end
create_temporal_triggers :people, 'id' # the live table's primary key
```

A history column that an older `add_column` created as a generated one, too, stays so and is left out by the triggers.

### Querying

For the below queries, we'll assume the following schema:
``` ruby
class Person < ActiveRecord::Base
  belongs_to :coven, optional: true
  has_many :warts

  def to_s
    parts = [name]
    parts << "from #{coven.name}" if coven
    parts.join ' '
  end
end

class Coven < ActiveRecord::Base
  has_many :members, class_name: "Person"

  def to_s
    name
  end
end

class Wart < ActiveRecord::Base
  belongs_to :person

  scope :very_hairy, -> { where(arel_table[:num_hairs].gteq(3)) }

  def to_s
    "wart on #{location} with #{pluralize num_hairs, 'hair'}"
  end
end
```

You can query the history tables by calling `history` on the class.
``` ruby
Person         #=> Person(id: :integer, name: :string)
Person.history #=> PersonHistory(history_id: :integer, id: :integer, name: :string, eff_from: :datetime, eff_to: :datetime)
```

The history table's primary key is `history_id`, but a history record stands for the original one: `id`, `find`, `ids` and a history relation used as a subquery (`Person.where(id: Person.history.at(time).where(...))`) go by the original id. A single version is `where(history_id: ...)`; `reload` returns any one version of the record, `update` and `destroy` hit all of them, and batches over all versions go by `history_id` (`find_each(cursor: :history_id)`).

You can easily get a history of all changes to a record.
``` ruby
Person.history.where(id: 1).map { |p| "#{p.eff_from}: #{p.to_s}" }
# => [
#  "1974-01-14: Emily",
#  "2003-11-03: Grunthilda from Delta Gamma Gamma"
# ]
```

A convenient `history` method is mixed into ActiveRecord classes.  The above could be rewritten as:
``` ruby
grunthilda = Person.find(1)
grunthilda.history.map { |p| "#{p.eff_from}: #{p.to_s}" }
```

You can query for records as they were at any point in the past by calling `at`.
``` ruby
Person.history.at(2.years.ago).where(id: 1).first.name #=> "Grunthilda"

# alternatively:
grunthilda = Person.find(1)
grunthilda.history.at(2.years.ago).first.name #=> "Grunthilda"
```

Associations work too.
``` ruby
grunthilda = Person.history.at(20.years.ago).find_by_name("Grunthilda")
grunthilda.warts.count            #=> 2

grunthilda = Person.history.at(1.year.ago).find_by_name("Grunthilda")
grunthilda.warts.count            #=> 13

grunthilda.warts.first.class.name #=> "WartHistory"
```

And scopes also!
``` ruby
grunthilda = Person.history.at(1.year.ago).find_by_name("Grunthilda")
grunthilda.warts.count            #=> 13
grunthilda.warts.very_hairy.count #=> 7
```

Instance methods are inherited.
``` ruby
grunthilda.to_s                   #=> "Grunthilda from Delta Gamma Gamma"
grunthilda.class.name             #=> "PersonHistory"
grunthilda.class.superclass.name  #=> "Person"
```

## Config
You can configure temporal_tables in an initializer.

Create temporal tables for all tables by default (default = false)
``` ruby
TemporalTables.create_by_default = true
```

Don't create temporal tables for these tables.  (default = %w{schema_migrations sessions ar_internal_metadata})
``` ruby
TemporalTables.skip_temporal_table_for :table_one, :table_two
```

Write no version for an update that changes nothing but `updated_at`, `updated_by` and `lock_version`, such as a `touch` (PostgreSQL only, default = true). The triggers read it when they are created, so existing tables follow a change once `create_temporal_triggers` runs for them again (see Upgrading above). To version every touch:
``` ruby
TemporalTables.skip_touch_versions = false
```

Coalesce the versions of quick successive edits of one column, such as a text saved on every keystroke, into one version per editing phase (PostgreSQL only, default = off). An update that changes one listed column alone names it in its version's `eff_edited_column`; in a `jsonb` column it must change one leaf alone, named by its path such as `translations.de.title` (the walk descends where both values are objects, so arrays, scalars and missing values are leaves; a dot in a key reads `\.`). `updated_at`, `updated_by`, `lock_version` and generated columns do not count, so a cache derived from a column is best a generated one. Such an update overwrites the open version instead of closing it when that version
- names the same column or path, so the version of an insert, of another column or path or of several at once stays,
- began within `coalesce_versions_within` of now, so the window slides with each edit,
- has the same `updated_by`, where the table has that column; a null one counts as one writer.

The overwritten version then starts at the update, and the one before it lasts until then: a phase is dated by its last edit, its `eff_edited_from` keeps when it began, and the states in between are lost. A closed version's `eff_to` may thus still move. History tables need both columns for it, see Upgrading above. A bare column name applies to every table that has it, `table.column` to that one table; an entry a table lacks is skipped. Like `skip_touch_versions`, the settings take effect once `create_temporal_triggers` runs for a table again.
``` ruby
TemporalTables.coalesce_versions_within = 5.minutes
TemporalTables.coalesce_columns = %w[translations tasks.title tasks.description]
```

On PostgreSQL, an update of a row whose open version began in the same transaction goes into that version, which would otherwise last no time.

Add an `updated_by` column to all temporal tables to track who made any changes, which is quite useful for auditing.  Defaults to a :string field.  The block is called when records are saved to determine the value to place within the `updated_by` field.  `updated_by` fields are only auto-created if this is configured.
``` ruby
TemporalTables.add_updated_by_field(:integer) { User.current_user&.id }
```

The value is filled in by `TemporalTables::Whodunnit`, which has to be included in the models (or `ApplicationRecord`). On every model with an `updated_by` column and a history table it writes the block's result onto the row itself with every INSERT and UPDATE, `touch` included, so each history version carries whoever wrote it, `nil` where the block returns `nil`. A save that changes nothing writes nothing. `updated_by` therefore shows up in `saved_changes`. On PostgreSQL an UPDATE that does not set `updated_by` itself — `update_columns`, `update_all`, counter caches, raw SQL — stores `nil` instead of the previous writer: two `<table>_bu_mark` / `<table>_bu_reset` triggers clear it. Tables that exist already get them once `create_temporal_triggers` runs for them again (see Upgrading above). On MySQL such an UPDATE keeps the previous value. As a `touch` writes no version on PostgreSQL, the row may name a later writer than its current version does.

## Development

To add a new version of rails to the specs, create corresponding Gemfiles in the `gemfiles/` directory, and add references to them in `.github/workflows/test.yml`.

To run specs, run `rake matrix:install` and `rake matrix:spec`, or a single Gemfile with `BUNDLE_GEMFILE=gemfiles/Gemfile.8.1.pg bundle exec rspec`. PostgreSQL connects as `PGUSER` or the current user.

Neither the Gemfiles' lockfiles nor a `.ruby-version` are committed: CI and local runs resolve the newest releases each Gemfile allows, and CI's matrix names Ruby minor versions, of which `ruby/setup-ruby` installs the newest patch release.

## Copyright
See [LICENSE](https://github.com/bkroeker/temporal_tables/blob/master/LICENSE.txt) for more details.
