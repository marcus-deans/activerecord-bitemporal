# ActiveRecord::Bitemporal - Usage Guide

## Overview

`activerecord-bitemporal` is a Rails library that enables **Bitemporal Data Modeling** for ActiveRecord models. This allows you to track both:

- **Valid Time**: When facts were/are/will be true in the real world
- **Transaction Time**: When the database learned about those facts

### What Problem Does This Solve?

In traditional databases, when you update a record, you lose the previous state. Bitemporal modeling preserves the complete history of:

1. **What the data was** (historical states)
2. **When changes were made** (audit trail)
3. **What we believed at any point in time** (knowledge timeline)

### How It Works

When you create a record:

```ruby
position = Position.create(hourly_rate_cents: 100)
```

The following record is created:

| id  | bitemporal_id | hourly_rate_cents | valid_from | valid_to   | transaction_from | transaction_to |
| --- | ------------- | ----------------- | ---------- | ---------- | ---------------- | -------------- |
| 1   | 1             | 100               | 2024-01-10 | 9999-12-31 | 2024-01-10       | 9999-12-31     |

When you update the record:

```ruby
position.update(hourly_rate_cents: 200)
```

Instead of overwriting, the gem creates historical records:

| id  | bitemporal_id | hourly_rate_cents | valid_from | valid_to   | transaction_from | transaction_to |
| --- | ------------- | ----------------- | ---------- | ---------- | ---------------- | -------------- |
| 1   | 1             | 100               | 2024-01-10 | 9999-12-31 | 2024-01-10       | 2024-01-15     |
| 2   | 1             | 100               | 2024-01-10 | 2024-01-15 | 2024-01-15       | 9999-12-31     |
| 3   | 1             | 200               | 2024-01-15 | 9999-12-31 | 2024-01-15       | 9999-12-31     |

You can now query "what was the rate on Jan 12?" or "what did we think the rate was on Jan 12, as of Jan 14?"

---

## Setup

### Database Schema Requirements

Your table must include these columns:

```ruby
create_table :positions do |t|
  # Your regular columns
  t.integer :hourly_rate_cents
  t.string :name

  # Required bitemporal columns
  t.string :bitemporal_id  # Or uuid/integer matching your primary key type
  t.datetime :valid_from
  t.datetime :valid_to
  t.datetime :transaction_from
  t.datetime :transaction_to

  t.timestamps
end
```

**Column Definitions:**

| Column             | Type         | Purpose                                                          |
| ------------------ | ------------ | ---------------------------------------------------------------- |
| `bitemporal_id`    | Same as `id` | Shared identifier across all versions of the same logical record |
| `valid_from`       | `datetime`   | Start of the period when this data is/was true in reality        |
| `valid_to`         | `datetime`   | End of the period when this data is/was true in reality          |
| `transaction_from` | `datetime`   | When this record was created in the database                     |
| `transaction_to`   | `datetime`   | When this record was superseded/deleted                          |

### Model Configuration

Include the `ActiveRecord::Bitemporal` module in your model:

```ruby
class Position < ApplicationRecord
  include ActiveRecord::Bitemporal
end
```

That's it! Your model now tracks complete history.

---

## Creating Records

### Default Behavior

When you create a record without specifying time ranges:

```ruby
position = Position.create(
  job_id: 1,
  hourly_rate_cents: 1500
)
```

The gem automatically sets:

- `valid_from`: Current time
- `valid_to`: `9999-12-31` (represents "infinity")
- `transaction_from`: Current time
- `transaction_to`: `9999-12-31`
- `bitemporal_id`: Same as the record's `id`

### Creating Historical Records

You can create records for past periods:

```ruby
# Create a record that was valid starting 1 week ago
Position.create(
  job_id: 1,
  hourly_rate_cents: 1500,
  valid_from: 1.week.ago
)

# Create a record valid for a specific time range
Position.create(
  job_id: 1,
  hourly_rate_cents: 1500,
  valid_from: '2024-01-01',
  valid_to: '2024-03-31'
)
```

---

## Updating Records

### Standard Updates

When you update a record, the gem automatically creates historical versions:

```ruby
position = Position.create(hourly_rate_cents: 100)
# DB: one record with rate=100, valid_from=now, valid_to=∞

position.update(hourly_rate_cents: 200)
# DB: three records:
#   1. Original (rate=100) with transaction_to=now (superseded)
#   2. Historical (rate=100) from original valid_from to now
#   3. Current (rate=200) from now to ∞
```

**What happens during update:**

1. The current record's `transaction_to` is set to the update time
2. A new "before" record is created (old values, valid until update time)
3. A new "after" record is created (new values, valid from update time)

All three records share the same `bitemporal_id`.

### Time-Based Updates (`valid_at`)

You can update a record as of a specific point in time:

```ruby
position = Position.create(
  hourly_rate_cents: 100,
  valid_from: 1.week.ago
)

# Update the rate as of 3 days ago
position.valid_at(3.days.ago) do |p|
  p.update!(hourly_rate_cents: 200)
end
```

This creates:

- A record with rate=100 from 1 week ago to 3 days ago
- A record with rate=200 from 3 days ago to infinity

**Important:** This only works when updating within the current valid period. You cannot create overlapping validity periods (see Constraints section).

### Force Update (Overwrite Without History)

`force_update` is for **correcting data** rather than **recording temporal changes**.

#### Conceptual Difference

- **Regular update**: "The rate _changed_ on day X" → Splits the timeline at day X
- **Force update**: "We _recorded it wrong_ - the rate was always Y" → Replaces without splitting

#### Usage

```ruby
position.force_update do |p|
  p.update(hourly_rate_cents: 300)
end
```

**What happens:**

- Sets the old record's `transaction_to` to now (marks as superseded)
- Creates a new record with the updated values
- Does NOT create the "before" historical record
- Preserves the original `valid_from` and `valid_to` (same validity period)

**Result:**

```ruby
# Before force_update:
# Record 1: rate=200, valid_from=1w ago, valid_to=∞, transaction_from=T1, transaction_to=∞

# After force_update:
# Record 1: rate=200, valid_from=1w ago, valid_to=∞, transaction_from=T1, transaction_to=now
# Record 2: rate=300, valid_from=1w ago, valid_to=∞, transaction_from=now, transaction_to=∞
```

#### When to Use

| Scenario         | Use                   | Example                                            |
| ---------------- | --------------------- | -------------------------------------------------- |
| Data correction  | `force_update`        | "We entered $15/hr but it should have been $18/hr" |
| Temporal change  | regular `update`      | "Rate increased from $15/hr to $18/hr on March 1"  |
| Backdated change | `valid_at { update }` | "Rate actually changed on Feb 15, not March 1"     |

#### Important Limitations

⚠️ **force_update ignores valid_at context:**

```ruby
# This does NOT work as you might expect:
position.valid_at(3.days.ago) do |p|
  p.force_update { |p2| p2.update!(rate: 300) }
end
# The valid_at(3.days.ago) is IGNORED!
# Updates using the record's own valid_from, not 3.days.ago
```

⚠️ **Warning:** `update_columns` bypasses bitemporal tracking entirely and directly modifies the record.

---

## Deleting Records

Deletion works similarly to updates - it creates historical records:

```ruby
position = Position.create(hourly_rate_cents: 100)
position.update(hourly_rate_cents: 200)
position.destroy
```

After destroy:

- The current record's `transaction_to` is set to the deletion time
- A new record is created showing the state up to deletion time

The record is "logically deleted" but remains in the database for historical queries.

To permanently delete (use sparingly):

```ruby
position.destroy(force_delete: true)
```

---

## Uniqueness Constraints

**Critical Rule:** Records with the same `bitemporal_id` **cannot have overlapping valid time ranges** within overlapping transaction time ranges.

### Valid Examples

```ruby
# Different time periods - OK
Position.create(name: "Worker", valid_from: '2024-01-01', valid_to: '2024-02-01')
Position.create(name: "Worker", valid_from: '2024-03-01', valid_to: '2024-04-01')

# Touching boundaries - OK
Position.create(name: "Worker", valid_from: '2024-01-01', valid_to: '2024-02-01')
Position.create(name: "Worker", valid_from: '2024-02-01', valid_to: '2024-03-01')
```

### Invalid Examples

```ruby
# Overlapping periods - FAILS
Position.create(name: "Worker", valid_from: '2024-01-01', valid_to: '2024-03-01')
Position.create(name: "Worker", valid_from: '2024-02-01', valid_to: '2024-04-01')
# Error: "Bitemporal has already been taken"
```

---

## Querying Records

### Default Query Behavior

The gem automatically filters queries to show only "current" records:

```ruby
position = Position.create(hourly_rate_cents: 100)
position.update(hourly_rate_cents: 200)

Position.count
# => 1 (only shows the current record)

Position.all
# => [#<Position hourly_rate_cents: 200>]
```

Behind the scenes, queries include:

```sql
WHERE valid_from <= NOW()
  AND valid_to > NOW()
  AND transaction_from <= NOW()
  AND transaction_to > NOW()
```

⚠️ **Note:** This is NOT implemented via `default_scope`, so `.unscoped` will NOT remove these filters.

### Overriding Default Filters

Use these scopes to access historical data:

| Scope                          | Effect                               |
| ------------------------------ | ------------------------------------ |
| `.ignore_valid_datetime`       | Remove valid time filtering          |
| `.ignore_transaction_datetime` | Include logically deleted records    |
| `.ignore_bitemporal_datetime`  | Show ALL records (no time filtering) |

Examples:

```ruby
# See all versions of a record
Position.ignore_valid_datetime
  .where(bitemporal_id: position.bitemporal_id)
  .order(:valid_from)

# See deleted records
Position.ignore_transaction_datetime.where(...)

# See everything
Position.ignore_bitemporal_datetime.count
```

### Time-Based Querying

#### Using `valid_at`

Query records as they were valid at a specific time:

```ruby
# Get all positions valid on Jan 15, 2024
Position.valid_at('2024-01-15').all

# Chain with other scopes
Position.valid_at('2024-01-15').where(job_id: 1)
```

#### Using `find_at_time`

Find a specific record at a specific time:

```ruby
# Returns the position with this ID as it was on Jan 15
position = Position.find_at_time('2024-01-15', position_id)

# Returns nil if not found
Position.find_at_time('2024-01-15', position_id)

# Raises error if not found
Position.find_at_time!('2024-01-15', position_id)
```

---

## Understanding IDs

The gem has special ID handling that can be confusing:

### Three ID Values

| Method           | Returns                   | Purpose                         |
| ---------------- | ------------------------- | ------------------------------- |
| `#id`            | `bitemporal_id` value     | For finding records across time |
| `#bitemporal_id` | Shared ID across versions | Groups historical versions      |
| `#swapped_id`    | Database `id`             | The actual primary key          |

### Example

```ruby
position = Position.create(hourly_rate_cents: 100)
position.update(hourly_rate_cents: 200)

current = Position.first
past = Position.find_at_time(1.day.ago, current.id)

current.id           # => 1 (actually bitemporal_id)
current.bitemporal_id # => 1
current.swapped_id    # => 3 (actual DB id)

past.id              # => 1 (same bitemporal_id)
past.bitemporal_id   # => 1 (same)
past.swapped_id      # => 2 (different DB id)
```

### Why This Matters

```ruby
# WRONG - won't work
Position.find_by(id: position.id)

# CORRECT - use bitemporal_id
Position.find_by(bitemporal_id: position.bitemporal_id)

# OR just use find (it's patched to work)
Position.find(position.id)
```

### Pluck vs Map

```ruby
# Returns actual DB ids
Position.ignore_valid_datetime.pluck(:id)
# => [1, 2, 3]

# Returns bitemporal_ids
Position.ignore_valid_datetime.map(&:id)
# => [1, 1, 1]

# Returns bitemporal_ids
Position.ignore_valid_datetime.ids
# => [1, 1, 1]
```

---

## Practical Examples

### Example 1: Tracking Rate Changes

```ruby
# Jan 1: Create position
position = Position.create(
  job_id: 1,
  hourly_rate_cents: 1500,
  valid_from: '2024-01-01'
)

# Jan 15: Rate increased
position.update(hourly_rate_cents: 1800)

# Feb 1: Another increase
position.update(hourly_rate_cents: 2000)

# Query: What was the rate on Jan 20?
past_position = Position.find_at_time('2024-01-20', position.id)
past_position.hourly_rate_cents
# => 1800

# Query: What's the current rate?
Position.find(position.id).hourly_rate_cents
# => 2000

# See all rate changes
Position.ignore_valid_datetime
  .where(bitemporal_id: position.bitemporal_id)
  .order(:valid_from)
  .pluck(:valid_from, :hourly_rate_cents)
# => [["2024-01-01", 1500], ["2024-01-15", 1800], ["2024-02-01", 2000]]
```

### Example 2: Correcting Past Data

```ruby
# Create position with rate starting last week
position = Position.create(
  hourly_rate_cents: 1500,
  valid_from: 1.week.ago
)

# Realize the rate should have changed 3 days ago
position.valid_at(3.days.ago) do |p|
  p.update!(hourly_rate_cents: 1800)
end

# Now you have:
# - Rate 1500 from 1 week ago to 3 days ago
# - Rate 1800 from 3 days ago to infinity
```

### Example 3: Viewing History Timeline

```ruby
position = Position.create(name: "Developer", valid_from: '2024-01-01')

# Make several updates
position.update(name: "Senior Developer")
position.update(name: "Lead Developer")

# See complete history
Position.ignore_valid_datetime
  .where(bitemporal_id: position.bitemporal_id)
  .order(:transaction_from)
  .each do |version|
    puts "#{version.transaction_from}: #{version.name} (valid: #{version.valid_from} - #{version.valid_to})"
  end
```

---

## Common Pitfalls

### 1. Trying to Create Overlapping Periods

```ruby
# This will fail:
position = Position.create(valid_from: 1.week.ago)
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }
position.valid_at(5.days.ago) { |p| p.update!(rate: 300) }
# Error: Bitemporal has already been taken
```

**Why:** The gem doesn't support cascading historical corrections (see IMPLEMENTATION.md for details).

### 2. Using `update_columns`

```ruby
# Bypasses bitemporal tracking!
position.update_columns(hourly_rate_cents: 1000)
```

**Result:** Record is directly modified, no history is created.

### 3. Searching by `id` Instead of `bitemporal_id`

```ruby
# Won't work as expected
Position.where(id: position.id)

# Use this instead
Position.where(bitemporal_id: position.bitemporal_id)
```

### 4. Combining `force_update` with `valid_at`

```ruby
# This doesn't work as expected:
position.valid_at(3.days.ago) do |p|
  p.force_update { |p2| p2.update!(rate: 300) }
end
# The valid_at context is IGNORED!
```

**Why:** `force_update` always uses the record's own `valid_from` time. The combination doesn't make semantic sense - you can't "backdate a correction."

**Solution:** Choose one:

- For corrections: Use `force_update` alone
- For backdated changes: Use `valid_at { update }` without force_update

---

## When to Use This Gem

### ✅ Good Use Cases

- Audit trails and compliance requirements
- Tracking historical states of data
- Correcting past data while preserving what you "used to believe"
- Time-traveling queries ("what did the database look like on date X?")

### ❌ Not Ideal For

- Simple append-only logs (use PaperTrail or Audited)
- Frequent historical corrections that cascade across time
- Performance-critical queries (bitemporal queries are complex)
- Models where overlapping validity periods are required

---

## Additional Resources

- [Official Repository](https://github.com/kufu/activerecord-bitemporal)
- [IMPLEMENTATION.md](./IMPLEMENTATION.md) - Deep dive into internal mechanics
- [Bitemporal Data Theory](https://en.wikipedia.org/wiki/Bitemporal_Modeling)

---

## Quick Reference

```ruby
# Creation
Position.create(rate: 100)                    # Current time
Position.create(rate: 100, valid_from: 1.week.ago)  # Historical

# Updates
position.update(rate: 200)                    # Standard update (temporal change)
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }  # Backdated change
position.force_update { |p| p.update(rate: 200) }  # Correction (not temporal)

# Queries
Position.all                                  # Current records only
Position.valid_at('2024-01-15').all          # Records valid on date
Position.find_at_time('2024-01-15', id)      # Specific record at time
Position.ignore_valid_datetime.all           # All versions
Position.ignore_transaction_datetime.all     # Include deleted

# IDs
position.id              # bitemporal_id (for finding)
position.bitemporal_id   # Shared across versions
position.swapped_id      # Actual database id
```
