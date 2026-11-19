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

Any subsequent schema changes to people will be reflected automatically in people_h.

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

History tables created by older versions of the gem lack the `history_id` primary key, may carry `NOT NULL` and defaults on their columns, and run older triggers. Per table, ideally one transaction each:
``` ruby
add_column :people_h, :history_id, :primary_key # rewrites people_h
connection.columns(:people_h).each do |column|
  next if %w[history_id eff_from eff_to].include?(column.name)

  change_column_null :people_h, column.name, true
  change_column_default :people_h, column.name, nil
end
create_temporal_triggers :people, 'id' # the live table's primary key
```

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

Add an `updated_by` column to all temporal tables to track who made any changes, which is quite useful for auditing.  Defaults to a :string field.  The block is called when records are saved to determine the value to place within the `updated_by` field.  `updated_by` fields are only auto-created if this is configured.
``` ruby
TemporalTables.add_updated_by_field(:integer) { User.current_user&.id }
```

The value is filled in by `TemporalTables::Whodunnit`, which has to be included in the models (or `ApplicationRecord`). On every model with an `updated_by` column and a history table it writes the block's result onto the row itself with every INSERT and UPDATE, `touch` included, so each history version carries whoever wrote it, `nil` where the block returns `nil`. A save that changes nothing writes nothing. `updated_by` therefore shows up in `saved_changes`. On PostgreSQL an UPDATE that does not set `updated_by` itself — `update_columns`, `update_all`, counter caches, raw SQL — stores `nil` instead of the previous writer: two `<table>_bu_mark` / `<table>_bu_reset` triggers clear it. Tables that exist already get them once `create_temporal_triggers` runs for them again (see Upgrading above). On MySQL such an UPDATE keeps the previous value. As a `touch` writes no version on PostgreSQL, the row may name a later writer than its current version does.

## Development

To add a new version of rails to the specs, create corresponding Gemfiles in the `gemfiles/` directory, and add references to them in `.github/workflows/test.yml`.

To run specs, run `rake matrix:install` and `rake matrix:spec`, or a single Gemfile with `BUNDLE_GEMFILE=gemfiles/Gemfile.8.1.pg bundle exec rspec`. PostgreSQL connects as `PGUSER` or the current user.

CI runs RuboCop with `gemfiles/Gemfile.7.1.pg`, whose rubocop-rspec is older than the newest Gemfiles': a cop renamed since (such as `RSpec/FilePath`) has to pass under both names, so prefer code that needs no disable comment.

The CI test job runs `bundle update`, so it tests the newest Ruby and gem releases each Gemfile allows; the lockfiles only pin local runs and RuboCop.

## Copyright
See [LICENSE](https://github.com/bkroeker/temporal_tables/blob/master/LICENSE.txt) for more details.
