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

## Correcting Historical Data

The `correct` method allows you to fix historical data while **preserving the cascade of subsequent changes**. This is the key difference from `force_update`, which overwrites without preserving future changes.

### When to Use `correct`

Use `correct` when you discover an error in past data but want to keep all subsequent changes intact:

```ruby
# Example: Employee's department was recorded wrong for February
# Timeline has: HR (Jan) → Engineering (Mar) → Management (May)
# Reality was:  HR (Jan) → Temp Assignment (Feb-Mar) → Engineering (Mar) → Management (May)

employee.correct(
  valid_from: Date.new(2024, 2, 1),
  valid_to: Date.new(2024, 3, 1),
  department: "Temp Assignment"
)
# Result: HR (Jan-Feb) → Temp Assignment (Feb-Mar) → Engineering (Mar-May) → Management (May-∞)
# The March and May changes are PRESERVED
```

### Bounded Correction (with `valid_to`)

When you specify both `valid_from` and `valid_to`, the correction applies only to that period:

```ruby
# Before:
#   A              B              C
#   |--------------|--------------|----------->
#   Jan           Mar            May

employee.correct(valid_from: feb_1, valid_to: apr_1, name: "X")

# After:
#   A    X              B    C
#   |----|--------------|----|--->
#   Jan  Feb           Apr  May
```

**What happens:**
1. Record A is trimmed to end at Feb 1
2. The correction "X" is inserted for [Feb 1, Apr 1)
3. Record B is trimmed to start at Apr 1 (was Mar, now Apr)
4. Record C is **preserved unchanged** (CASCADE)

### Unbounded Correction (without `valid_to`)

When you omit `valid_to`, the correction extends only to the next change point, fully preserving all future changes:

```ruby
# Before:
#   A              B              C
#   |--------------|--------------|----------->
#   Jan           Mar            May

employee.correct(valid_from: feb_1, name: "X")  # No valid_to!

# After:
#   A    X         B              C
#   |----|---------|--------------|----------->
#   Jan  Feb      Mar            May
```

**What happens:**
1. Record A is trimmed to end at Feb 1
2. The correction "X" is inserted for [Feb 1, Mar 1) — ends at the next change point
3. Records B and C are **fully preserved** (no trimming)

This is the safest option when you only need to correct a specific error without affecting the entire future timeline.

### Comparison: `update` vs `force_update` vs `correct` vs `shift_genesis` vs `terminate`

| Method | Purpose | Preserves Future Changes | Changes Attributes | Undo Method |
|--------|---------|--------------------------|-------------------|-------------|
| `update` | Record a change happening now | N/A (operates at current time) | Yes | — |
| `force_update` | Fix data error, overwrite timeline | ❌ No | Yes | — |
| `correct` | Fix historical error | ✅ Yes (CASCADE) | Yes | — |
| `shift_genesis` | Change when entity's timeline begins | ✅ Yes (untouched) | No (purely temporal) | `cancel_shift_genesis` |
| `terminate` | End entity's timeline at a specific date | ✅ Yes (before termination point) | No (purely temporal) | `cancel_termination` |

### Example: Correcting a Salary Error

```ruby
# Scenario: Employee's salary was recorded as $50k in January,
# but it should have been $55k. They got a raise to $60k in March.

# Current timeline:
#   $50k (Jan-Mar) → $60k (Mar-∞)

# With force_update - LOSES the March raise:
employee.force_update { |e| e.update!(salary: 55_000) }
# Result: $55k (Jan-∞)  ← March raise is GONE!

# With correct - PRESERVES the March raise:
employee.correct(valid_from: jan_1, salary: 55_000)
# Result: $55k (Jan-Mar) → $60k (Mar-∞)  ← March raise preserved!
```

### Error Handling

The `correct` method validates inputs and raises errors for invalid operations:

```ruby
# valid_from must be within the timeline
employee.correct(valid_from: Date.new(1900, 1, 1), name: "X")
# => ArgumentError: valid_from must be within the record's valid period

# valid_to must be after valid_from
employee.correct(valid_from: mar_1, valid_to: jan_1, name: "X")
# => ArgumentError: valid_to must be after valid_from
```

### Transaction Safety

All corrections are wrapped in a database transaction. If any part of the correction fails, the entire operation is rolled back:

```ruby
begin
  employee.correct(valid_from: feb_1, name: "X")
rescue ActiveRecord::RecordInvalid
  # Database is unchanged - no partial corrections
end
```

---

## Shifting the Timeline Start

The `shift_genesis` method changes *when* an entity's timeline begins, without changing *what* its attributes are. This is a purely temporal operation.

### When to Use `shift_genesis`

Use `shift_genesis` when you need to change an entity's start date but the data itself is correct:

```ruby
# Scenario: An employee was created with a start date of March 1,
# but they actually started on January 1.

# correct() won't work here — there's no record before March to correct:
employee.correct(valid_from: jan_1, name: "Alice")
# => ActiveRecord::RecordNotFound (no record exists at jan_1)

# shift_genesis solves this:
employee.shift_genesis(new_valid_from: jan_1)
# Timeline extended: Alice now starts from January 1
```

### Backward Shift (Extending Earlier)

Move the start date earlier to extend the timeline into the past:

```ruby
# Before:
#   Alice           Bob
#   |---------------|----------->
#   Mar            May
#
employee.shift_genesis(new_valid_from: jan_1)
#
# After:
#   Alice                     Bob
#   |-------------------------|----------->
#   Jan                      May
```

Only the first segment's `valid_from` changes. All subsequent segments (Bob) remain untouched — their attributes, boundaries, and even their physical database rows are preserved.

### Forward Shift (Trimming Start)

Move the start date forward to remove early history:

```ruby
# Before:
#   Alice           Bob            Carol
#   |---------------|--------------|----------->
#   Jan            Mar            May
#
employee.shift_genesis(new_valid_from: apr_1)
#
# After:
#   Bob    Carol
#   |----- |----------->
#   Apr    May
```

Segments entirely before the new start are removed. A segment that spans the new start date is trimmed. Segments after the new start are untouched.

### Composing with `correct`

`shift_genesis` and `correct` work together naturally. A common pattern is to backdate first, then correct within the extended range:

```ruby
# Employee was created starting March, but actually started in January
# with a different role that changed in February.
employee.shift_genesis(new_valid_from: jan_1)
employee.correct(valid_from: jan_1, valid_to: feb_1, role: "Intern")
# Result: Intern (Jan-Feb) → Original role (Feb-Mar) → ...
```

### Error Handling

```ruby
# Shifting to the same date is a no-op (returns true, no DB changes)
employee.shift_genesis(new_valid_from: current_genesis_date)

# Cannot erase the entire timeline
employee.shift_genesis(new_valid_from: far_future_date)
# => ArgumentError: shift_genesis would erase all segments

# Entity must have current-knowledge records
employee.shift_genesis(new_valid_from: jan_1)
# => ActiveRecord::RecordNotFound (if entity has been fully deleted)
```

### Audit Trail

Like all bitemporal operations, `shift_genesis` preserves full transaction history. You can query what the timeline looked like before the shift using `transaction_at`:

```ruby
# After shifting genesis from March to January:
ActiveRecord::Bitemporal.transaction_at(before_shift_time) do
  ActiveRecord::Bitemporal.valid_at(feb_1) do
    Employee.find_at_time(feb_1, employee.id)
    # => nil (before the shift, no record existed in February)
  end
end

# Current knowledge now includes February:
Employee.find_at_time(feb_1, employee.id)
# => #<Employee name: "Alice">
```

---

## Terminating a Timeline

The `terminate` method sets a finite end date on an entity's valid-time timeline. Unlike `destroy` (which operates on **transaction time** to mark a record as "no longer current knowledge"), `terminate` operates on **valid time** to say "this entity stopped being valid at this date."

### When to Use `terminate`

Use `terminate` when an entity has a real-world end date, but you want to preserve the full history for auditing and time-travel queries:

```ruby
# Scenario: An employee's contract ends on March 1.
# Their timeline has: HR (Jan) → Engineering (Feb) → ...
#
# destroy() would mark the record as deleted in transaction time,
# losing the ability to query "what department were they in on Feb 15?"
#
# terminate() preserves the full history up to the end date:
employee.terminate(termination_time: Date.new(2024, 3, 1))
# Timeline is now: HR (Jan-Feb) → Engineering (Feb-Mar)
# Queries for dates before March still work perfectly.
```

### Terminate vs Destroy

| Aspect | `terminate` | `destroy` |
|--------|------------|-----------|
| **Time dimension** | Valid time (`valid_to`) | Transaction time (`transaction_to`) |
| **Meaning** | "Entity stopped being valid at date X" | "We no longer know about this entity" |
| **Historical queries** | ✅ `find_at_time` still works for dates before termination | ❌ Record is logically deleted |
| **Reversible?** | ✅ `cancel_termination` restores full pre-termination timeline | Requires manual recreation |
| **What changes** | Last segment's `valid_to` is set to termination date; segments after are removed | Record's `transaction_to` is set to deletion time |

### Basic Termination

```ruby
# Before:
#   Alice           Bob            Carol
#   |---------------|--------------|----------->
#   Jan            Mar            May            ∞

employee.terminate(termination_time: apr_1)

# After:
#   Alice           Bob
#   |---------------|------|
#   Jan            Mar    Apr
```

**What happens:**
1. Segments entirely before the termination point are **untouched** (Alice)
2. A segment spanning the termination point is **truncated** (Bob's `valid_to` set to Apr)
3. Segments entirely after the termination point are **removed** (Carol)
4. All changes are wrapped in a transaction with row-level locking

### Cancel Termination

`cancel_termination` fully reverses a termination by searching backward through transaction history to find the pre-termination state and restoring it:

```ruby
# Before (terminated):
#   Alice           Bob
#   |---------------|------|
#   Jan            Mar    Apr

employee.cancel_termination

# After (restored):
#   Alice           Bob            Carol
#   |---------------|--------------|----------->
#   Jan            Mar            May            ∞
```

This recovers **all** segments that were removed during termination, including segments that were entirely past the termination point. The recovery uses the transaction history — no data is ever lost.

**Important:** `cancel_termination` is a **full undo** — it restores the exact pre-termination state. Any operations performed *after* termination (such as corrections within the terminated range) are lost. If you need to preserve post-termination changes, consider rebuilding the timeline manually instead of using `cancel_termination`.

Cancel is a no-op if the entity is not currently terminated (returns `true`, no DB changes).

### Checking Termination Status

The `terminated?` predicate checks whether the entity's last segment has a finite `valid_to`:

```ruby
employee.terminated?
# => false (timeline extends to infinity)

employee.terminate(termination_time: mar_1)
employee.terminated?
# => true (timeline ends at March)

employee.cancel_termination
employee.terminated?
# => false (timeline restored to infinity)
```

This queries the current timeline regardless of which segment `self` points to — it always checks the **last** segment.

### Composing with Other Operations

Terminate composes naturally with `correct` and `shift_genesis`:

```ruby
# Correct within a terminated range — works normally:
employee.terminate(termination_time: may_1)
employee.correct(valid_from: feb_1, valid_to: mar_1, name: "X")
# Result: A (Jan-Feb) → X (Feb-Mar) → B (Mar-May)

# Unbounded correction — safe, inherits terminated boundary:
employee.terminate(termination_time: may_1)
employee.correct(valid_from: feb_1, name: "X")
# Result: Correction bounded by next change point, within terminated range

# Shift genesis backward — preserves termination date:
employee.terminate(termination_time: may_1)
employee.shift_genesis(new_valid_from: earlier_date)
# Result: Timeline starts earlier, still ends at May

# Correct beyond termination (valid_from) — raises error:
employee.terminate(termination_time: mar_1)
employee.correct(valid_from: may_1, name: "X")
# => ActiveRecord::RecordNotFound (no record exists at May)

# Bounded correction past termination (valid_to) — raises error:
employee.terminate(termination_time: may_1)
employee.correct(valid_from: feb_1, valid_to: jul_1, name: "X")
# => ActiveRecord::Bitemporal::ValidDatetimeRangeError
# (correction valid_to exceeds timeline end — cancel termination first)
```

### Re-Termination

You can re-terminate at an **earlier** point without canceling first:

```ruby
# Currently terminated at May
employee.terminate(termination_time: mar_1)  # Further truncates to March
```

To re-terminate at a **later** point, you must cancel first then re-terminate:

```ruby
employee.cancel_termination
employee.terminate(termination_time: jul_1)
```

### Error Handling

```ruby
# Termination time must be after the first segment's start
employee.terminate(termination_time: Date.new(1900, 1, 1))
# => ArgumentError: termination_time must be greater than first valid_from

# Cannot extend past current termination (use cancel_termination first)
employee.terminate(termination_time: later_date)
# => ArgumentError: termination_time exceeds last segment's valid_to

# Entity must have current-knowledge records
Employee.new(bitemporal_id: 99999).terminate(termination_time: mar_1)
# => ActiveRecord::RecordNotFound

# Already terminated at the same time — no-op (returns true)
employee.terminate(termination_time: mar_1)  # first time
employee.terminate(termination_time: mar_1)  # no-op, returns true
```

### Audit Trail

Like all bitemporal operations, termination preserves full transaction history:

```ruby
# After terminating at March:
ActiveRecord::Bitemporal.transaction_at(before_termination_time) do
  ActiveRecord::Bitemporal.valid_at(may_1) do
    Employee.find(employee.id)
    # => #<Employee name: "Carol"> (before termination, May was valid)
  end
end

# Current knowledge sees the terminated state:
Employee.find_at_time(may_1, employee.id)
# => nil (after termination, May is no longer valid)
```

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

**Why:** `valid_at { update }` can only split the current valid record, not cascade changes to future records.

**Solution:** Use `#correct` for retroactive corrections that need to preserve future changes:

```ruby
position.correct(valid_from: 5.days.ago, rate: 300)
```

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
- Performance-critical queries (bitemporal queries are complex)
- Models where overlapping validity periods are required

---

## Additional Resources

- [Official Repository](https://github.com/kufu/activerecord-bitemporal)
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Deep dive into internal mechanics
- [BITEMPORAL_CONCEPTS.md](./BITEMPORAL_CONCEPTS.md) - Comprehensive bitemporal theory
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
position.correct(valid_from: feb_1, name: "X")    # Retroactive correction (preserves cascade)
position.shift_genesis(new_valid_from: jan_1)      # Change when timeline begins
position.terminate(termination_time: mar_1)        # End timeline at specific date
position.cancel_termination                        # Reverse termination (full history recovery)
position.terminated?                               # Check if timeline has finite end

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
