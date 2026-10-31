# ActiveRecord::Bitemporal - Usage Guide

This fork of [kufu/activerecord-bitemporal](https://github.com/kufu/activerecord-bitemporal) adds operations that edit an entity's whole timeline: `correct`, `shift_genesis`, `terminate` and `reopen`, and the cancels `cancel_shift_genesis` and `cancel_termination`. This guide covers upstream's API and those additions. [CHANGELOG.md](./CHANGELOG.md) lists what the fork changed, and [ARCHITECTURE.md](./ARCHITECTURE.md) explains how the operations work.

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
- **Force update**: "We _recorded this version wrong_ - over its whole range the rate was Y" → Rewrites the version the record holds, over the same range, without splitting it. The entity's other versions keep their rows

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
- Changes only that one version. The record holds the version valid at the time it was loaded at, so on a record loaded now it's the current version, and to fix an earlier one you load it with `find_at_time` first

**Result:**

```ruby
# Before force_update:
# Record 1: rate=200, valid_from=1w ago, valid_to=∞, transaction_from=T1, transaction_to=∞

# After force_update:
# Record 1: rate=200, valid_from=1w ago, valid_to=∞, transaction_from=T1, transaction_to=now
# Record 2: rate=300, valid_from=1w ago, valid_to=∞, transaction_from=now, transaction_to=∞
```

#### When to Use

| Scenario                          | Use                   | Example                                                        |
| --------------------------------- | --------------------- | -------------------------------------------------------------- |
| Data correction of one version    | `force_update`        | "We entered $15/hr for this version but it should be $18/hr"   |
| Data correction over a time range | `correct`             | "The rate was $18/hr from Feb 1 to Mar 15, not $15/hr"         |
| Temporal change                   | regular `update`      | "Rate increased from $15/hr to $18/hr on March 1"              |
| Backdated change                  | `valid_at { update }` | "Rate actually changed on Feb 15, not March 1"                 |

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

The `correct` method allows you to fix historical data while **preserving the cascade of subsequent changes**. It takes the valid-time range to fix, whichever version the record holds. That's the key difference from `force_update`, which rewrites only the version the record holds, over that version's whole range: `correct` can fix part of a version, or a range across several.

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
2. Each segment's part in [Feb 1, Apr 1) gets name "X". The parts cut from A and B are now equal, so they're stored as one segment
3. Record B is trimmed to start at Apr 1 (was Mar, now Apr)
4. Record C is **preserved unchanged** (CASCADE)

Only the attributes you pass change. Each segment in the span keeps its own values for the rest, so a change of another attribute inside the span stays where it was (a patch, like SQL:2011's `UPDATE ... FOR PORTION OF`). A gap inside the span stays a gap. A segment that already has the given values isn't rewritten. Like every operation, a correction merges adjacent segments with equal values and closes zero-length rows anywhere in the timeline (see [The Timeline After an Operation](#the-timeline-after-an-operation)), so one that changes nothing writes only to do that. Passing a bitemporal column (`bitemporal_id`, `transaction_from`, ...), or an alias of one, raises `ArgumentError`.

### Unbounded Correction (without `valid_to`)

When you omit `valid_to`, the correction extends only to the end of the segment containing `valid_from`, fully preserving all future changes. That end counts even when the next segment holds the same values (a seam), since an app may show each future segment as a scheduled change:

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

### Comparison: `update` vs `force_update` vs `correct` vs `shift_genesis` vs `terminate` vs `reopen`

| Method | Purpose | Preserves Future Changes | Changes Attributes | Undo Method |
|--------|---------|--------------------------|-------------------|-------------|
| `update` | Record a change happening now | N/A (operates at current time) | Yes | — |
| `force_update` | Fix a data error in one version | ✅ Yes (only the version the record holds changes, over its whole range) | Yes | — |
| `correct` | Fix historical error | ✅ Yes (CASCADE) | Yes | — |
| `shift_genesis` | Change when entity's timeline begins | ✅ Yes (untouched) | No (purely temporal) | `cancel_shift_genesis` |
| `terminate` | End entity's timeline at a specific date | ✅ Yes (before termination point) | No (purely temporal) | `cancel_termination` |
| `reopen` | Lift a terminated timeline's end | ✅ Yes (only the last segment changes) | No (purely temporal) | `terminate` at the old end |

### Example: Correcting a Salary Error

```ruby
# Scenario: Employee's salary was recorded as $50k in January,
# but it should have been $55k. They got a raise to $60k in March.

# Current timeline:
#   $50k (Jan-Mar) → $60k (Mar-∞)

# With force_update on the current record - rewrites the March version instead:
employee = Employee.find(id)
employee.force_update { |e| e.update!(salary: 55_000) }
# Result: $50k (Jan-Mar) → $55k (Mar-∞)  ← the raise is overwritten, January is not fixed

# force_update fixes January only on a record holding the January version:
Employee.find_at_time(jan_1, id).force_update { |e| e.update!(salary: 55_000) }
# Result: $55k (Jan-Mar) → $60k (Mar-∞)

# With correct - takes the range to fix, whichever version the record holds:
employee.correct(valid_from: jan_1, salary: 55_000)
# Result: $55k (Jan-Mar) → $60k (Mar-∞)  ← March raise preserved!
```

### Error Handling

The `correct` method validates inputs and raises errors for invalid operations:

```ruby
# valid_from must fall in a segment of the timeline (not before it, after its end or in a gap)
employee.correct(valid_from: Date.new(1900, 1, 1), name: "X")
# => ActiveRecord::RecordNotFound: Couldn't find Employee with 'bitemporal_id'=1 at 1900-01-01 00:00:00 UTC

# valid_to must be after valid_from
employee.correct(valid_from: mar_1, valid_to: jan_1, name: "X")
# => ArgumentError: valid_to (2024-01-01 00:00:00 UTC) must be greater than valid_from (2024-03-01 00:00:00 UTC)
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

### The Timeline After an Operation

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` each leave the entity's current timeline with no seam (two adjacent segments with the same values) and no zero-length row (`valid_from` equal to `valid_to`), whatever they found there. An `update!` that sets the values the next segment already has leaves a seam, and a `destroy` at a segment's exact start leaves a zero-length row. The operation merges or closes them anywhere in the timeline, so on such a timeline it writes to do that even when it otherwise changes nothing: shifting to the current genesis, terminating at the current end, reopening a timeline that isn't terminated, or a cancel with nothing to cancel.

Segments whose range and values don't change keep their rows, so a cancel rewrites only the segments the operation it undoes changed. A zero-length row holds no version, so the operations look past it, and so do `terminated?` and `shifted_genesis?`: an entity whose only current rows are zero-length raises `ActiveRecord::RecordNotFound`, and reads as neither terminated nor shifted.

### The Record After an Operation

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` leave the record you called them on as `reload` would: on the current version valid at the time the record was loaded at (now, unless it was loaded with `valid_at`/`find_at_time`), with every attribute fresh and nothing left to save. The model's own `reload` overrides run too. When no version is valid at that time (a timeline ended in the past, or starting in the future), the record takes the latest version starting before it, else the first one.

```ruby
employee = Employee.find(id)           # name: "B"
employee.correct(valid_from: may_1, name: "X")
employee.name                          # => "X"
employee.changed?                      # => false
employee.update!(emp_code: "C2")       # builds on the correction
```

Like `reload`, an operation discards unsaved changes on the record. A call with nothing to write (it changes nothing, and finds no seam or zero-length row to fix) writes nothing and leaves the record as it was. A frozen record raises `FrozenError`, as `update!` does.

### Blocks and Scopes Around an Operation

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` always work on the entity's whole current timeline, as `update!` records at now. They read its rows unscoped, so a `transaction_at`, `valid_at` or `bitemporal_at` block around the call (with `!` or without), a `scoping` block, or the model's own `default_scope` hides none of them:

```ruby
ActiveRecord::Bitemporal.transaction_at(last_week) do
  # Patches the timeline as it is now, rows recorded since last week included
  employee.correct(valid_from: feb_1, name: "X")
end

Employee.where(archived_at: nil).scoping do
  # Ends the timeline at June 1, archived segments included
  employee.terminate(termination_time: jun_1)
end
```

The history a cancel walks back through, and `terminated?` and `shifted_genesis?`, are read the same way. The record you call the operation on is then reloaded onto the current timeline at its own valid time (see The Record After an Operation), which a `valid_at` block sets: inside `valid_at(feb_1)`, onto the version valid on February 1.

### Validations and Callbacks During an Operation

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` insert each new row with `save_without_bitemporal_callbacks!(validate: false)`, as upstream inserts the rows of an `update!` or `destroy`, and close each old row with `update_columns`.

#### Validations

The model's validations never run on the rows an operation writes, and neither do `before_validation` and `after_validation`. The only check is the operation's own: if the entity's current rows overlap once it has written its rows, it raises `ActiveRecord::RecordInvalid` and rolls back.

Validating the new values is the caller's job. Assign them to the record and validate it before you call `correct`:

```ruby
attributes = { salary: 55_000 }
employee.assign_attributes(attributes)
employee.validate!                     # raises ActiveRecord::RecordInvalid if they're invalid
employee.correct(valid_from: jan_1, **attributes)
```

The gem doesn't validate the rows itself because `correct` is a patch: each segment in the span keeps its own values for the attributes you don't pass. Validating every row would hold your correction to data you never touched, such as an older value that a validation added later rejects. `terminate`, `shift_genesis`, `reopen` and the cancels write only values already stored.

#### Callbacks

| When | What runs |
|------|-----------|
| A row is inserted | The model's save and create callbacks (`before_save`, `around_save`, `before_create`, `around_create`, `after_create`, `after_save`), once per row: a `correct` that writes three rows runs them three times |
| A row is closed | Nothing: `update_columns` runs no update or save callback |
| The operation as a whole | No validation, update or destroy callback, and none of upstream's `bitemporal_create`, `bitemporal_update` or `bitemporal_destroy` |
| On commit | `after_commit`, `after_create_commit` and `after_save_commit` once for the entity, however many rows the operation inserted. Never `after_update_commit` or `after_destroy_commit` |

The commit callbacks run once because upstream's `after_create` sets each inserted row's `id` to the entity's `bitemporal_id`. Every row the operation inserts then has the same class and `id`, and Rails runs commit callbacks on only one instance per class and `id` in a transaction (which one follows Rails' `run_commit_callbacks_on_first_saved_instances_in_transaction`). So an app can hang expensive work off `after_commit` without it running once per row.

- Every row an operation inserts is a create, so create callbacks such as `after_create` and `after_create_commit` run for a correction, a termination, a reopen or a cancel too, not only when the entity is first created.
- Callbacks run on the inserted rows, each a new copy of a version with its own valid range, not on the record you called the operation on.
- On an inserted row, `saved_change_to_<attribute>?` is true for every column that holds a value, not only for the attributes the operation changed, because the row is a fresh copy. A `correct` of `name` reports `salary` as changed too.
- A call that writes nothing (it changes nothing, and finds no seam or zero-length row to fix) runs no callback, `after_commit` included.
- An operation that only closes rows, such as a `terminate` at a segment's end or a `shift_genesis` forward to a segment's start, saves no row, so it runs no callback either, `after_commit` included.
- A callback that aborts a row's save aborts the whole operation: it raises and writes nothing. `throw :abort`, or an `ActiveRecord::Rollback` raised before the row is inserted, raises `ActiveRecord::RecordNotSaved`; any other exception is raised as it is. An `ActiveRecord::Rollback` raised after the insert, in `after_create` or `after_save`, doesn't abort the save: Rails swallows it and keeps the row, so the operation goes on.

### Times You Pass

`correct`, `shift_genesis` and `terminate` take the times you pass as the valid-time column stores them, read in `Time.zone` as `valid_at` reads them. For a date column that's the day, so `Date.new(2024, 3, 1)` or any time that day meets a March 1 boundary in every time zone. For a datetime column it's the time to the column's precision, so the same `Time.current` an `update!` was made at meets the boundary that update wrote. A `correct` whose two times fall on the same day of a date column raises `ArgumentError`.

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

Segments entirely before the new start are removed. A segment that spans the new start date is trimmed. Segments after the new start are untouched. A new start inside a gap trims nothing, so the timeline then starts where the segment after the gap starts.

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
# Shifting to the same date is a no-op (returns true, writing only to merge seams
# or close zero-length rows left in the timeline)
employee.shift_genesis(new_valid_from: current_genesis_date)

# Cannot erase the entire timeline (here one terminated at May 1)
employee.shift_genesis(new_valid_from: jul_1)
# => ArgumentError: shift_genesis would erase all segments: new_valid_from (2024-07-01 00:00:00 UTC) >= last segment valid_to (2024-05-01 00:00:00 UTC)

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

### Canceling a Genesis Shift

The `cancel_shift_genesis` method reverses a genesis shift by restoring, from transaction history, the complete timeline the entity had at its original genesis:

```ruby
# Original: Timeline starts in March
# After shift: Timeline starts in January
employee.shift_genesis(new_valid_from: jan_1)

# Cancel: Restores timeline to start in March again
employee.cancel_shift_genesis
```

**Important:** `cancel_shift_genesis` is an **undo** — it restores the most recent timeline that started at the original genesis, exactly as it stood just before the genesis moved off it, as `cancel_termination` restores the most recent timeline that wasn't terminated. It never discards anything: if anything was recorded for the entity after that shift (a `correct`, an upstream `update!`, a `terminate`, another `shift_genesis`, ...), it **refuses**. It raises `ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError`, writes nothing, and leaves the record as it was. That error is a subclass of `PreShiftGenesisStateNotFoundError`, so a `rescue` of that class catches it too:

```ruby
employee.shift_genesis(new_valid_from: jan_1)
employee.correct(valid_from: jan_1, valid_to: feb_1, name: "X")

employee.cancel_shift_genesis
# => ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError
#    (the correction would be discarded; nothing is written)
```

So a cancel undoes one shift. After two shifts it refuses, since the second was recorded after the first moved the genesis off the original:

```ruby
employee.shift_genesis(new_valid_from: feb_1)  # original genesis: January
employee.shift_genesis(new_valid_from: apr_1)

employee.cancel_shift_genesis
# => ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError
```

Cancel is a no-op if the entity's genesis is its original one: never shifted, shifted back to it, or already canceled (returns `true`, writing only to merge seams or close zero-length rows left in the timeline, see [The Timeline After an Operation](#the-timeline-after-an-operation)). A `shift_genesis` back to the original genesis is not an undo, though: segments a forward shift removed stay removed, and the first segment left is extended back instead.

### Checking Genesis Shift Status

The `shifted_genesis?` predicate checks whether the entity's current genesis differs from its original creation genesis:

```ruby
employee.shifted_genesis?
# => false (genesis matches original creation)

employee.shift_genesis(new_valid_from: jan_1)
employee.shifted_genesis?
# => true (genesis has been moved)

employee.cancel_shift_genesis
employee.shifted_genesis?
# => false (genesis restored to original)
```

This queries the full transaction history to find the original genesis — it's always accurate regardless of how many shifts have occurred.

An upstream `update!` at a valid time before the genesis inserts a row there, so it moves the genesis too, and `shifted_genesis?` is true. `cancel_shift_genesis` can't undo it, though, and writes nothing. The `update!` closes no row, so history holds no timeline that it ended at the original genesis. The cancel raises `PreShiftGenesisStateNotFoundError`; or, when an earlier write left an older timeline at the original genesis, it finds that one and raises the subclass `RecordedSinceGenesisShiftError`, because the `update!` was recorded after it. Move the genesis back with `shift_genesis` instead:

```ruby
employee.valid_at(dec_1) { |e| e.update!(name: "X") }  # before the January 1 genesis
employee.shifted_genesis?
# => true

employee.cancel_shift_genesis
# => ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError

employee.shift_genesis(new_valid_from: jan_1)
employee.shifted_genesis?
# => false
```

---

## Terminating a Timeline

The `terminate` method sets a finite end date on an entity's valid-time timeline, to say "this entity stopped being valid at this date": the version valid then ends there, and every version after it is removed. `destroy` works on valid time too, but on one version: it ends the version valid at the record's time (now, or the time the record was loaded at) there, and later versions stay current. On a timeline with a change after that time, it leaves a gap rather than an end (see [Deleting Records](#deleting-records)).

### When to Use `terminate`

Use `terminate` when an entity has a real-world end date, but you want to preserve the full history for auditing and time-travel queries:

```ruby
# Scenario: An employee's contract ends on March 1.
# Their timeline has: HR (Jan) → Engineering (Feb) → Management (Apr)
#
# destroy() on the record loaded at March 1 would end only Engineering,
# at March 1, and Management would still start in April.
#
# terminate() ends the timeline, keeping the history up to the end date:
employee.terminate(termination_time: Date.new(2024, 3, 1))
# Timeline is now: HR (Jan-Feb) → Engineering (Feb-Mar)
# Queries for dates before March still work as before.
```

### Terminate vs Destroy

| Aspect | `terminate` | `destroy` |
|--------|------------|-----------|
| **Time dimension** | Valid time (`valid_to`) | Valid time (`valid_to`), of one version |
| **Meaning** | "Entity stopped being valid at date X" | "This version stopped being valid at date X" |
| **Historical queries** | ✅ `find_at_time` still works for dates before termination | ✅ `find_at_time` still works for dates before the destroy, and for later versions |
| **Reversible?** | ✅ `cancel_termination` restores the full pre-termination timeline, as long as nothing was recorded for the entity after the termination (otherwise it refuses). `reopen` lifts the end whatever was recorded since, without the removed segments | Requires manual recreation, except for the end a destroy of the last segment leaves, which `reopen` lifts |
| **What changes** | Last segment's `valid_to` is set to termination date; segments after are removed | The version's row is closed (`transaction_to` set to now) and a copy ending at the destroy time inserted; later versions keep their rows |

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
4. All changes are wrapped in a transaction that holds the entity's timeline locks (see [Concurrency](#concurrency))

A termination point inside a gap truncates nothing: the segments after the gap are removed, so the timeline ends where the gap starts.

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

This recovers **all** segments that were removed during termination, including segments that were entirely past the termination point. The recovery uses the transaction history.

**Important:** `cancel_termination` is an **undo** — it restores the timeline exactly as it stood just before the termination. It never discards anything: if anything was recorded for the entity after the termination (a `correct` anywhere in the timeline, an upstream `update!`, a re-termination at an earlier point, ...), it **refuses**. It raises `ActiveRecord::Bitemporal::RecordedSinceTerminationError`, writes nothing, and leaves the record as it was. That error is a subclass of `PreTerminationStateNotFoundError`, so a `rescue` of that class catches it too:

```ruby
employee.terminate(termination_time: may_1)
employee.correct(valid_from: feb_1, valid_to: mar_1, name: "X")

employee.cancel_termination
# => ActiveRecord::Bitemporal::RecordedSinceTerminationError
#    (the correction would be discarded; nothing is written)
```

Cancel is a no-op if the entity is not currently terminated (returns `true`, writing only to merge seams or close zero-length rows left in the timeline, see [The Timeline After an Operation](#the-timeline-after-an-operation)).

A timeline that has ended since it was created, such as a record created with a finite `valid_to`, has no open-ended timeline in its history to restore. `cancel_termination` then raises `ActiveRecord::Bitemporal::PreTerminationStateNotFoundError` and writes nothing; `reopen` lifts such an end.

### Reopen

`reopen` lifts the end of a terminated timeline: the last segment continues, with the values it already has, to infinity. It's the end-side mirror of a backward `shift_genesis`, which extends the first segment's values earlier.

```ruby
# Before (terminated):
#   Alice           Bob
#   |---------------|------|
#   Jan            Mar    Apr

employee.reopen

# After (reopened):
#   Alice           Bob
#   |---------------|----------->
#   Jan            Mar            ∞
```

Only Bob's row is rewritten; Alice keeps hers. Carol, whom the termination removed, stays removed.

#### `cancel_termination` or `reopen`?

`cancel_termination` is an **undo**: it reads transaction history and puts the timeline back as it stood before the termination, segments past the end included, and it refuses once anything has been recorded since. `reopen` is an **edit**, like `terminate` and `correct`: it changes the current timeline in valid time, never reads history, and works whatever was recorded since.

| | `cancel_termination` | `reopen` |
|---|---|---|
| **What it does** | Restores the timeline from before the termination | Continues the last segment to infinity |
| **Segments the termination removed** | ✅ Brought back | Stay removed |
| **Something recorded after the termination** | Refuses (`RecordedSinceTerminationError`), writes nothing | ✅ Kept |
| **Reads transaction history** | Yes | No |

So a change scheduled past the end comes back with `cancel_termination`, not with `reopen`:

```ruby
# Alice (Jan) → Bob (Mar) → Carol (May), terminated at Apr
employee.cancel_termination
# Alice (Jan-Mar) → Bob (Mar-May) → Carol (May-∞)

# whereas reopen gives:
# Alice (Jan-Mar) → Bob (Mar-∞), and Carol stays removed
```

Once something has been recorded after the termination, only `reopen` lifts the end:

```ruby
employee.terminate(termination_time: may_1)
employee.correct(valid_from: feb_1, valid_to: mar_1, name: "X")

employee.cancel_termination
# => ActiveRecord::Bitemporal::RecordedSinceTerminationError

employee.reopen
# Result: A (Jan-Feb) → X (Feb-Mar) → B (Mar-∞), the correction kept
```

An end in the past is lifted like one in the future, and so is the end a `destroy` of the last segment leaves: the destroyed segment continues, as `cancel_termination` would restore it. A `destroy` at the last segment's exact start leaves only a zero-length row there, which holds no version, so `reopen` continues the segment before it and closes that row.

To move an end **later**, reopen and then terminate at the new end, in one transaction (see [Re-Termination](#re-termination)).

Reopen is a no-op if the entity is not currently terminated (returns `true`, writing only to merge seams or close zero-length rows left in the timeline). An entity with no current-knowledge records raises `ActiveRecord::RecordNotFound`.

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
# => ActiveRecord::Bitemporal::ValidDatetimeRangeError: correction valid_to (2024-07-01 00:00:00 UTC)
#    exceeds timeline end (2024-05-01 00:00:00 UTC). Reopen the timeline or cancel its termination first to extend it.
```

### Re-Termination

You can re-terminate at an **earlier** point without canceling first:

```ruby
# Currently terminated at May
employee.terminate(termination_time: mar_1)  # Further truncates to March
```

To re-terminate at a **later** point, reopen first, then terminate at the new end. Wrap both in a transaction to make the move atomic:

```ruby
Employee.transaction do
  employee.reopen
  employee.terminate(termination_time: jul_1)
end
```

`reopen` continues the current last segment, so the segments the termination removed stay removed, and it works whatever was recorded since. To bring those segments back, undo the termination with `cancel_termination` before terminating at the new end instead. That cancel refuses once anything has been recorded for the entity after the termination, including a re-termination at an earlier point.

After a move, `cancel_termination` undoes only the last `terminate`. It restores the reopened, open-ended timeline, not the earlier end, and not the segments the first termination removed.

### Error Handling

```ruby
# Termination time must be after the first segment's start
employee.terminate(termination_time: Date.new(1900, 1, 1))
# => ArgumentError: termination_time (1900-01-01 00:00:00 UTC) must be greater than first segment valid_from (2024-01-01 00:00:00 UTC)

# Cannot extend past current termination (reopen first, or cancel_termination)
employee.terminate(termination_time: jul_1)
# => ArgumentError: termination_time (2024-07-01 00:00:00 UTC) exceeds last segment valid_to (2024-05-01 00:00:00 UTC)

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

## Concurrency

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` lock the entity's timeline before they read it, and hold the locks until the surrounding transaction ends. They need PostgreSQL: the locks use its advisory lock functions.

An operation that raises inside that transaction rolls back to its own savepoint, which releases the locks it took. Locks taken earlier in the transaction, by you or by an operation that succeeded, stay held. To keep the entity locked across an error you rescue, take the advisory lock yourself first (see [Holding the Lock Yourself](#holding-the-lock-yourself)).

Each operation takes, in this order:

1. **An advisory lock on the entity**, with this key:

   ```sql
   SELECT pg_advisory_xact_lock(hashtext('<table_name>'), hashtext('<bitemporal_id as text>'))
   ```

   Two operations on the same entity wait for each other. Unlike a row lock, this holds even when the entity has no row valid now.
2. **The row valid now** (`FOR UPDATE`), by the same statement `save` and `save!` lock with outside any block, whatever block the operation is called in. They lock that row first and then close the row valid at the record's own time, which for a future-dated `update!` is another row. Taking the row valid now first means such an `update!` waits for the operation while holding nothing, so the two can't deadlock.
3. **Every current-knowledge row** of the entity (`FOR UPDATE`), whatever its valid time or the caller's scopes. An `update!` or `destroy` already writing any of them commits before the operation reads the timeline.

### Holding the Lock Yourself

The advisory lock's key is part of the public API. Code holding the same lock in its transaction and the operations wait for each other, and an operation called while you hold it re-enters it:

```ruby
Employee.transaction do
  Employee.connection.execute(Employee.sanitize_sql_array([
    "SELECT pg_advisory_xact_lock(hashtext(?), hashtext(?))",
    Employee.table_name, employee.bitemporal_id.to_s
  ]))

  record = Employee.find_at_time(jun_1, employee.id)
  record.valid_at(jun_1) { record.update!(name: "B") }
  employee.correct(valid_from: feb_1, name: "X")
end
```

Take it before the transaction's first write to the entity. A transaction that row-locks the entity with `update!` first and takes the advisory lock after (directly or through an operation) can deadlock with another holder; PostgreSQL then aborts one of the two.

### What the Locks Don't Cover

`save` and `destroy` don't take the advisory lock, and two kinds of write read the timeline before they lock a row an operation holds:

- `save`/`update!` on an entity with no row valid now (its timeline starts in the future or has ended): the lock on the row valid now covers no row.
- `destroy`: it reads the version it keeps as history before it locks the row it closes.

Such a write can read the timeline before an operation commits and write after it, on top of what it read. To serialize it with the operations, hold the advisory lock around it as above.

### Clocks on Different Hosts

Every write records its own host's clock as transaction time. An operation reads the time once it holds the locks, so on one host it's later than every write that committed before. A host whose clock runs ahead, though, records rows with a `transaction_from` later than another host's now, and closing such a row at that now would end it before it starts. So an operation that finds a current row recorded after its own time raises `ActiveRecord::Bitemporal::TransactionTimeSkewError` before it writes anything, naming the row and how many seconds ahead of the operation it was recorded:

```ruby
employee.terminate(termination_time: jun_1)
# => ActiveRecord::Bitemporal::TransactionTimeSkewError
#    (another host recorded a current row after this host's now)
```

The call succeeds once this host's clock has passed that row's time. Clock skew between hosts is otherwise out of scope, as it is for upstream's writes.

### Frozen Clocks

A clock frozen in tests (`freeze_time`, `Timecop.freeze`) gives every write the same transaction time. A row recorded and closed at one instant was never current knowledge, so writes made at one frozen instant leave a cancel nothing to restore: create a record and then terminate it under one `freeze_time`, and `cancel_termination` raises `ActiveRecord::Bitemporal::PreTerminationStateNotFoundError`. The same goes for a `shift_genesis` and `cancel_shift_genesis`, which raises `PreShiftGenesisStateNotFoundError`. Advance the clock between writes. Travelling it back to before a current row was recorded makes the next operation raise `TransactionTimeSkewError`, as on a host whose clock runs behind.

---

## Errors

`correct`, `shift_genesis`, `terminate`, `reopen`, `cancel_shift_genesis` and `cancel_termination` raise these errors. An operation that raises writes nothing: it rolls back to its own savepoint (see [Concurrency](#concurrency)), and the record you called it on isn't reloaded.

| Error | Raised by | When |
|-------|-----------|------|
| `ArgumentError` | `correct` | `valid_to` isn't after `valid_from`, or the attributes name a bitemporal column or an alias of one |
| | `terminate` | `termination_time` isn't after the first segment's `valid_from`, or is after the last segment's `valid_to` |
| | `shift_genesis` | `new_valid_from` is at or after the last segment's `valid_to`, so the shift would erase every segment |
| `ActiveRecord::RecordNotFound` | all six | The entity has no current-knowledge row that holds a time |
| | `correct` | No segment contains `valid_from`: it's before the timeline, at or after its end, or in a gap |
| `ActiveRecord::Bitemporal::ValidDatetimeRangeError` | `correct` | `valid_to` is after the timeline's end. Reopen the timeline or cancel its termination first |
| `ActiveRecord::Bitemporal::PreTerminationStateNotFoundError` | `cancel_termination` | Transaction history holds no open-ended timeline to restore: the entity was created with a finite `valid_to`, or its writes were made at one frozen instant (see [Frozen Clocks](#frozen-clocks)) |
| `ActiveRecord::Bitemporal::RecordedSinceTerminationError` | `cancel_termination` | Something was recorded for the entity after the termination. A subclass of `PreTerminationStateNotFoundError` |
| `ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError` | `cancel_shift_genesis` | Transaction history holds no timeline at the original genesis to restore, as after an upstream `update!` before the genesis, or writes made at one frozen instant |
| `ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError` | `cancel_shift_genesis` | Something was recorded for the entity after its genesis moved off the original one, a second shift included. A subclass of `PreShiftGenesisStateNotFoundError` |
| `ActiveRecord::Bitemporal::TransactionTimeSkewError` | all six | A current row was recorded after this host's now (see [Clocks on Different Hosts](#clocks-on-different-hosts)) |
| `ActiveRecord::RecordInvalid` | all six | The entity's current rows overlap once the operation has written its rows |
| `ActiveRecord::RecordNotSaved` | all six | A callback aborted the save of a row the operation inserts (see [Callbacks](#callbacks)) |
| `FrozenError` | all six | The record is frozen |

An exception a callback raises is raised as it is.

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

`destroy` ends only the version valid at the record's time: now, or the time the record was loaded at with `valid_at` or `find_at_time`. Versions that start after it stay current, so on a timeline with a change after that time it leaves a gap, not an end. To end the whole timeline, use `terminate` (see [Terminating a Timeline](#terminating-a-timeline)). Inside `force_update`, `destroy` closes the version's row without inserting a copy, so the version is gone over its whole range.

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

⚠️ **Note:** These filters are the model's `default_scope`, so `.unscoped` removes them, along with any default scope of your own.

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

**Why:** `force_update` always rewrites the version the record holds, at the record's own `valid_from`, over that version's whole range.

**Solution:** Choose one:

- To fix one version over its whole range: load that version (`find_at_time`) and use `force_update` alone
- To fix a valid-time range you choose: use `correct`
- For backdated changes: Use `valid_at { update }` without force_update

### 5. Starting a Timeline at `DEFAULT_VALID_FROM`

```ruby
default = ActiveRecord::Bitemporal::DEFAULT_VALID_FROM  # 1900-12-31

position = Position.create!(rate: 100, valid_from: default)
position.valid_from  # => now, not 1900-12-31
```

**Why:** upstream reads a row inserted with `valid_from` equal to `DEFAULT_VALID_FROM` as one whose start was never set, and gives it the `valid_at` time or now. Every operation inserts its rows through that same path, so the start moves to now on any write that inserts a row starting there:

- `correct(valid_from: default, ...)` on a timeline that starts at `DEFAULT_VALID_FROM` leaves one row from now on, and the history before now is gone. A bounded correction can write a row that ends before it starts.
- Upstream's own `update!` and `shift_genesis(new_valid_from: default)` do the same.

A row only starts there if something wrote it without upstream's insert, such as raw SQL, `insert_all` or `update_columns`.

**Solution:** never start a timeline at `DEFAULT_VALID_FROM`. To mean "since forever", start it a second later:

```ruby
Position.create!(rate: 100, valid_from: ActiveRecord::Bitemporal::DEFAULT_VALID_FROM + 1.second)
```

Before relying on the operations for rows written outside upstream's insert, check that no current row starts at `DEFAULT_VALID_FROM`.

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
- [CHANGELOG.md](./CHANGELOG.md) - What the fork changed
- [TESTING.md](./TESTING.md) - How the fork is tested
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
position.force_update { |p| p.update(rate: 200) }  # Rewrite the version the record holds (no split)
position.correct(valid_from: feb_1, name: "X")    # Retroactive correction (preserves cascade)
position.shift_genesis(new_valid_from: jan_1)      # Change when timeline begins
position.cancel_shift_genesis                      # Undo to the original genesis (refuses if anything was recorded since)
position.shifted_genesis?                          # Check if genesis differs from original
position.terminate(termination_time: mar_1)        # End timeline at specific date
position.cancel_termination                        # Undo termination (refuses if anything was recorded since)
position.reopen                                    # Lift the end: last segment continues to ∞ (keeps what was recorded since)
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
