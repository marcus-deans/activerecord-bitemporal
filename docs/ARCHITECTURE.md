# ActiveRecord::Bitemporal - Architecture Guide

This document covers the internal architecture and implementation details of the gem. For usage instructions, see [README.md](./README.md).

## Table of Contents

1. [Core Architecture](#core-architecture)
2. [Database Schema](#database-schema)
3. [Update Mechanism](#update-mechanism)
4. [Correction Mechanism](#correction-mechanism)
5. [Termination Mechanism](#termination-mechanism)
6. [Time Arguments](#time-arguments)
7. [Timeline After an Operation](#timeline-after-an-operation)
8. [Self After an Operation](#self-after-an-operation)
9. [Uniqueness Validation](#uniqueness-validation)
10. [ID Swapping Mechanism](#id-swapping-mechanism)
11. [Query Scoping](#query-scoping)
12. [Performance Considerations](#performance-considerations)
13. [Limitations](#limitations)

---

## Core Architecture

### Module Structure

```
ActiveRecord::Bitemporal
├── Persistence         # Create, update, delete, correct logic
├── Uniqueness          # Validation to prevent overlaps
├── Relation            # Query scoping and filtering
├── Callbacks           # Lifecycle hooks
└── Optionable          # Temporal context management
```

### Key Methods

| Method | Location | Purpose |
|--------|----------|---------|
| `correct` | Line 261 | Public API for cascade corrections |
| `_correct_record` | Line 456 | Main cascade correction implementation |
| `_update_row` | Line 349 | Regular update persistence |
| `bitemporal_build_update_records` | Line 641 | Builds before/after for updates |
| `build_correction_records` | `timeline_operations.rb` | Builds the patched timeline for corrections |
| `perform_timeline_operation` | `timeline_operations.rb` | Shared skeleton of the timeline operations: lock, fetch, normalize, write the difference, reload self |
| `scope_relation` | Line 724 | Uniqueness validation scoping |
| `terminate` | Line ~332 | Public API for timeline termination |
| `_terminate_record` | Line ~777 | Main termination implementation |
| `cancel_termination` | Line ~340 | Public API for termination reversal |
| `_cancel_termination_record` | Line ~852 | Main cancel implementation |
| `build_termination_records` | Line ~922 | Builds truncated timeline for termination |
| `find_pre_termination_state` | Line ~952 | Searches transaction history for pre-termination state |

### Bitemporal Invariant

**Core Rule**: At any given transaction time, valid time periods must NOT overlap.

```
Valid at TT=T1:
  Record A: VT[Jan-1, Jan-15)  ✓
  Record B: VT[Jan-15, Feb-1)  ✓
  Record C: VT[Jan-10, Jan-20) ✗ INVALID - overlaps with A and B
```

---

## Database Schema

### Column Semantics

#### `bitemporal_id`

- **Type**: Same as primary key (integer, uuid, etc.)
- **Purpose**: Groups all versions of the same logical entity
- **Set When**: On first creation (copied from `id`)
- **Changes**: Never (stays constant across all versions)

#### `valid_from` / `valid_to`

- **Type**: `datetime` or `date`
- **Range**: `[valid_from, valid_to)` - inclusive start, exclusive end
- **Infinity**: `9999-12-31` represents "no end date"
- **Meaning**: "This data was true in reality from valid_from to valid_to"

#### `transaction_from` / `transaction_to`

- **Type**: `datetime`
- **Range**: `[transaction_from, transaction_to)` - inclusive start, exclusive end
- **Infinity**: `9999-12-31` represents "current knowledge"
- **Meaning**: "The database knew about this from transaction_from to transaction_to"

### Default Values

```ruby
DEFAULT_VALID_FROM = Time.utc(1900, 1, 1)
DEFAULT_VALID_TO = Time.utc(9999, 12, 31)
DEFAULT_TRANSACTION_FROM = Time.utc(1900, 1, 1)
DEFAULT_TRANSACTION_TO = Time.utc(9999, 12, 31)
```

### Recommended Indexes

```ruby
add_index :positions, :bitemporal_id
add_index :positions, [:bitemporal_id, :valid_from, :valid_to]
add_index :positions, [:bitemporal_id, :transaction_from, :transaction_to]
```

---

## Update Mechanism

### The `bitemporal_build_update_records` Method

This is the core of the gem's update logic. It determines which records to create/modify.

#### Scenario 1: Standard Update (force_update=false)

```ruby
position.update(hourly_rate_cents: 200)
```

**Steps**:

1. Find `current_valid_record` at target datetime
2. Create `before_instance` (old values, ends at update time)
3. Create `after_instance` (new values, starts at update time)
4. Close `current_valid_record.transaction_to = now`

**Result**:

```
Before:
  ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, ∞)

After:
  ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, now]      # Closed
  ID=2: rate=100, VT[Jan-1, now], TT[now, ∞)        # Before
  ID=3: rate=200, VT[now, ∞), TT[now, ∞)            # After
```

#### Scenario 2: Force Update (force_update=true)

```ruby
position.force_update { |p| p.update(hourly_rate_cents: 200) }
```

**Key difference**: Sets `before_instance = nil` (skip detailed history), preserves original `valid_from`.

**Result**:

```
Before:
  ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, ∞)

After:
  ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, now]      # Closed
  ID=2: rate=200, VT[Jan-1, ∞), TT[now, ∞)          # New (same valid period)
```

**Important**: `force_update` ignores `valid_at` context - it always uses the record's own `valid_from`.

#### Scenario 3: Gap Filling

When updating at a time with no existing record, a new record fills the gap up to the next record's `valid_from`.

---

## Correction Mechanism

### Overview

The `#correct` method implements cascade correction - fixing historical data while preserving subsequent changes. This differs from `force_update` which overwrites without preserving future changes.

### Algorithm

```
1. BEGIN TRANSACTION
2. LOCK the timeline: advisory lock, then the row valid now, then every
   current-knowledge row (see Locking Strategy)
3. FETCH all current-knowledge segments, setting zero-length rows aside
4. FIND containing record at valid_from (none, e.g. inside a gap: RecordNotFound)
5. END the span at valid_to, or at the containing record's end when unbounded
   (past the timeline's end: ValidDatetimeRangeError)
6. BUILD the patch:
   a. Split every segment overlapping the span at the span's edges
   b. Assign the corrected attributes to each piece inside the span; each keeps its
      own values for the attributes not given
   c. Keep the rows of segments the patch wouldn't change
   d. Records outside the span are preserved (CASCADE), and gaps stay gaps
7. NORMALIZE the new timeline and diff it against the current rows (see Timeline
   After an Operation): equal neighbours are merged anywhere in the timeline,
   seams an upstream update! left included. Nothing to write: return true
8. CLOSE the rows the diff drops (set transaction_to = now)
9. INSERT the pieces it adds
10. VALIDATE no overlapping valid times
11. RELOAD self (see Self After an Operation)
12. COMMIT TRANSACTION
```

### Critical Ordering

The key insight is that validation must happen AFTER closing old records:

```ruby
# CORRECT ORDER:
1. Lock the timeline (advisory lock, row valid now, every current-knowledge row)
2. Find affected records
3. Build and normalize the new timeline
4. CLOSE old records FIRST (set transaction_to)
5. INSERT new records
6. Validate post-hoc

# WRONG ORDER (causes "already been taken" errors):
1. Find affected records
2. Build new timeline
3. Validate BEFORE closing old records  # ← FAILS!
4. Close old records
5. Insert new records
```

### Bounded vs Unbounded Corrections

**Bounded** (explicit `valid_to`): Correction applies to `[valid_from, valid_to)`, then timeline resumes.

```
Before: A             B             C
        |-------------|-------------|----------->
        Jan          Mar           May

correct(valid_from: Feb, valid_to: Apr, name: "X")

After:  A    X             B    C
        |----|--------------|----|----->
        Jan  Feb           Apr  May
```

Each segment in the span keeps its own values for the attributes not given: a patch, like SQL:2011's `UPDATE ... FOR PORTION OF`. Correcting `name` across a change of `emp_code` leaves that change where it was:

```
Before: A/E1          A/E2
        |-------------|-------------------------->
        Jan          Mar

correct(valid_from: Feb, valid_to: Apr, name: "X")

After:  A/E1 X/E1     X/E2 A/E2
        |----|--------|----|--------------------->
        Jan  Feb     Mar  Apr
```

**Unbounded** (no `valid_to`): Correction extends to the end of the segment containing `valid_from`, fully preserving all future changes. A seam of equal segments still counts as that end.

```
Before: A             B             C
        |-------------|-------------|----------->
        Jan          Mar           May

correct(valid_from: Feb, name: "X")

After:  A    X         B             C
        |----|---------|--------------|--->
        Jan  Feb      Mar            May
```

### Attribute Inheritance

When correcting with only some attributes, each corrected piece keeps the non-corrected attributes of **the segment it was cut from**, not those of `self` (which may be a different time period).

---

## Termination Mechanism

### Overview

The `#terminate` method sets a finite end date on an entity's valid-time timeline. Unlike `destroy` (which closes `transaction_to` to say "we no longer know about this"), `terminate` modifies `valid_to` to say "this entity stopped being valid at this date." The `#cancel_termination` method reverses a termination by recovering the pre-termination state from transaction history, and refuses when anything was recorded for the entity after the termination.

Both methods are whole-timeline operations — they fetch all current-knowledge segments for the entity and operate on them atomically, similar to `_correct_record` and `_shift_genesis_record`.

### Terminate Algorithm

```
1. BEGIN TRANSACTION
2. LOCK the timeline: advisory lock, then SELECT ... FOR UPDATE on the row valid now,
   then on every current-knowledge row (see Locking Strategy)
3. FETCH all current-knowledge segments (transaction_to = ∞), ordered by valid time,
   setting zero-length rows aside
4. GUARD: Raise RecordNotFound if no segments exist
5. GUARD: Raise ArgumentError if termination_time <= first segment's valid_from
6. GUARD: Raise ArgumentError if termination_time > last segment's valid_to
7. NO-OP: Replace nothing if last segment's valid_to already equals termination_time
8. BUILD new timeline:
   a. Segments entirely before termination_time → keep unchanged
   b. Segment spanning termination_time → truncate (set valid_to = termination_time)
   c. Segments entirely at/after termination_time → remove
9. NORMALIZE the new timeline and diff it against the current rows (see Timeline
   After an Operation). Nothing to write: return true
10. CLOSE the rows the diff drops (set transaction_to = now)
11. INSERT the pieces it adds
12. VALIDATE no overlapping valid times
13. RELOAD self (see Self After an Operation)
14. COMMIT TRANSACTION
```

### Cancel Termination Algorithm

```
1. BEGIN TRANSACTION
2. LOCK the timeline: advisory lock, then the row valid now, then every
   current-knowledge row (see Locking Strategy)
3. FETCH all current-knowledge segments, setting zero-length rows aside
4. GUARD: Raise RecordNotFound if no segments exist
5. NO-OP: Replace nothing if last segment's valid_to = ∞ (not terminated)
6. FIND pre-termination state:
   a. Collect all distinct transaction_to values as change points
   b. Walk backward through change points
   c. At each point, query the timeline that was current just before that change,
      leaving out its zero-length rows (a timeline of nothing else is skipped)
   d. Return the first timeline where the last segment's valid_to = ∞, with its
      change point (when the termination took effect)
   e. Raise PreTerminationStateNotFoundError if none has one
7. GUARD: Raise RecordedSinceTerminationError if any row of the entity, whatever
   its valid time, was inserted (transaction_from) or closed (transaction_to) after
   that change point. The termination's own rows carry the change point itself,
   so the bounds are strict.
8. REPLACE all current segments with copies of the pre-termination ones (dup)
   - Clear deleted_at to prevent transaction_to corruption during save
9. NORMALIZE the restored timeline and diff it against the current rows (see
   Timeline After an Operation): a restored segment with a current row's range and
   values keeps that row. Nothing to write: return true
10. CLOSE the rows the diff drops (set transaction_to = now)
11. INSERT the pieces it adds
12. VALIDATE no overlapping valid times
13. RELOAD self (see Self After an Operation)
14. COMMIT TRANSACTION
```

`cancel_shift_genesis` follows the same steps, walking back to the first timeline whose genesis differs from the current one, and raises `RecordedSinceGenesisShiftError` in step 7. Both refusals happen before any write, so the transaction writes nothing and `self` is not reloaded. Each subclasses its cancel's not-found error, so a `rescue` of that error catches it.

### Key Implementation Detail: `deleted_at` Corruption

When recreating records from historical state during cancel, `dup` copies the `deleted_at` attribute. During `_create_record`, `bitemporal_assign_initialize_value` checks `changes.key?("deleted_at")` and overwrites `transaction_to` with `deleted_at` if present. This would corrupt the newly created record's `transaction_to`. The fix: explicitly clear `deleted_at = nil` on each duped record before saving.

### Terminate vs Destroy — Time Dimensions

```
destroy: operates on TRANSACTION TIME
  Before: record with transaction_to = ∞
  After:  record with transaction_to = now (logically deleted)
          + new historical record with valid_to = now

terminate: operates on VALID TIME
  Before: A              B              C
          |--------------|--------------|----------->
          Jan           Mar            May            ∞

  terminate(termination_time: Apr)

  After:  A              B
          |--------------|------|
          Jan           Mar    Apr
          (C is removed, B is truncated)
```

### Cancel — Full History Recovery

```
State after terminate(termination_time: Feb):
  Current knowledge: A
                     |----|
                     Jan  Feb

cancel_termination → walks transaction history backward:
  Before termination, current knowledge was:
    A              B              C
    |--------------|--------------|----------->
    Jan           Mar            May            ∞

State after cancel:
  Current knowledge: A              B              C
                     |--------------|--------------|----------->
                     Jan           Mar            May            ∞
  (Full pre-termination timeline restored)
```

Restoring that timeline replaces the current one, so it would discard anything recorded after the termination. The cancel refuses instead:

```
t1: terminate(termination_time: Feb)    rows inserted/closed at t1
t2: correct(valid_from: Jan, ...)       rows inserted/closed at t2 > t1

cancel_termination → pre-termination timeline found at change point t1
                   → rows written at t2 > t1 → RecordedSinceTerminationError
```

---

## Time Arguments

`correct`, `shift_genesis` and `terminate` take their times once, on entry, as the valid-time column stores them (`cast_valid_time`), so every guard, comparison and new row uses the value a stored boundary has:

1. Read the value in `Time.zone`, as upstream's `valid_at` reads it: a String or Date as midnight there, a Time as the same instant there. `DEFAULT_VALID_TO` is kept as it is, as the attribute default stores it, since in a zone behind UTC its day there is the day before.
2. Take it the way a write and a read do: through the column's type, the connection and the type again. A date column keeps the day; a datetime column keeps its declared precision, and at most microseconds when it declares none.

Compared as given, such a time disagreed with the boundary it matched: a Date outside UTC is midnight in `Time.zone`, not the stored day, and `Time.current` can carry nanoseconds that a `datetime(6)` boundary written from it lost. Operations then cut zero-length rows, rewrote rows they left unchanged, or raised at the timeline's end. A `correct` span that is empty once cast (both ends on the same day of a date column) raises `ArgumentError`, as any empty span does.

Transaction times need no cast: an operation writes its one `Time.current` to every row it closes or inserts, and never compares it with a stored one.

---

## Timeline After an Operation

Every timeline operation (`correct`, `shift_genesis`, `terminate` and the two cancels) leaves the entity's current timeline with no seam (two adjacent segments with equal business attributes, as an upstream `update!` that sets the values the next segment already has leaves) and no zero-length row (`valid_from = valid_to`, as an upstream `destroy` at a segment's exact start leaves), whatever it found there. The shared skeleton, `perform_timeline_operation`, does this for all five:

1. FETCH every current-knowledge row once the locks are held, and set the zero-length rows aside. The operation's guards and builders see only segments that hold a time: a zero-length row is never the genesis, the last segment or part of a patch, and an entity whose only current rows are zero-length raises `RecordNotFound`.
2. BUILD (op-specific): the segments the operation replaces, and the pieces it adds. A no-op exit replaces nothing.
3. NORMALIZE the result (segments - replaced + pieces): drop zero-length pieces, order by valid time, and merge equal neighbours (only stored columns count, not virtual attributes). A stored segment is never extended in place: it's closed and replaced by the merged piece.
4. DIFF it against every current row, zero-length rows included:
   - A row the result keeps stays.
   - A new piece with the range and business attributes of a current row is dropped, and that row stays, so an unchanged version isn't recorded again. A cancel keeps the rows of the segments the operation it undoes didn't change.
   - Every other row is closed and every other piece inserted, closing first. Rows are closed with `update_columns` and inserted with `save_without_bitemporal_callbacks!(validate: false)`: see [Validations and Callbacks During an Operation](./README.md#validations-and-callbacks-during-an-operation) for what runs.
5. Nothing to close or insert: return `true` without validating or reloading `self`.

So a call that changes nothing writes nothing, and a call on a timeline with a seam or a zero-length row merges or closes it, even when it otherwise changes nothing. The cancels' history walks also leave zero-length rows out of each snapshot, and skip a snapshot of nothing else: there's no timeline in it to restore.

```
Before (an upstream update! at Mar set B, the next segment's values):
  A         B         B         C
  |---------|---------|---------|----------->
  Feb      Mar       May       Jul

terminate(termination_time: Aug)

After:
  A         B                   C
  |---------|-------------------|---------|
  Feb      Mar                 Jul       Aug

  A keeps its row. Both B rows and C are closed, and B [Mar, Jul) and
  C [Jul, Aug) inserted.
```

---

## Self After an Operation

Every timeline operation (`correct`, `shift_genesis`, `terminate` and the two cancels) ends inside its transaction by reloading `self`, the way `update!` and `reload` treat the record's own valid time:

1. Pick the version: the current-knowledge segment valid at `self.valid_datetime` (the time it was loaded at with `valid_at`/`find_at_time`), or at now when it has none. That time is first cast to the valid-time column's type, so a date column compares days the way the database does. When none is valid then (a timeline ended before it, a gap, or a timeline starting after it), take the latest segment starting before that time, else the first segment. Zero-length rows are never picked. The segments are read unscoped, so neither the model's default scope nor a caller's `scoping` or `transaction_at` can hide one.
2. Call the real `reload(unscoped: true)` inside `valid_at!` and `transaction_at!(now)`, with the record's own `ignore_*` options off. The valid time is that same time when the version covers it, else the version's `valid_from`. Forcing both pins the lookup to that version whatever the record or the caller's scopes say. Pinning at the record's own time when possible means a strict-loading record's associations, which `reload` preloads under the pin, load at the time `reload` would load them at.
3. Set `swapped_id_previously_was` to the row `self` pointed at before, as `update!` does.

Going through `reload` means every reload hook runs: Rails' dirty tracking and autosave flags, and any `reload` override on the model (such as one resetting memoized values). Unsaved changes on `self` are discarded, as `reload` discards them. A call with nothing to write (see Timeline After an Operation) writes nothing and leaves `self` alone. A frozen `self` raises `FrozenError` before anything is written, as `update!` does.

---

## Uniqueness Validation

### The `scope_relation` Method

This validation prevents overlapping valid periods within overlapping transaction periods.

### Validation Logic

```ruby
# Pseudo-code
def scope_relation(record, relation)
  valid_from = record.valid_from
  valid_to = record.valid_to

  # Check for overlapping valid time
  valid_at_scope = finder_class.unscoped.ignore_valid_datetime
    .valid_from_lt(valid_to)      # Starts before our end
    .valid_to_gt(valid_from)      # Ends after our start
    .where.not(id: record.swapped_id)

  # Check for overlapping transaction time
  transaction_at_scope = finder_class.unscoped
    .transaction_to_gt(Time.current)
    .transaction_from_lt(DEFAULT_TRANSACTION_TO)

  relation.merge(valid_at_scope).merge(transaction_at_scope)
end
```

### Why Standard Updates Can't Cascade

When using `valid_at { update }` on a time earlier than existing records:

1. Update logic finds the record at that time
2. Creates new records for the split
3. Validation runs BEFORE future records' TT is closed
4. New record overlaps with future record (both have TT ending at ∞)
5. Error: "Bitemporal has already been taken"

**Solution**: Use `#correct` which closes all affected records atomically before validation.

---

## ID Swapping Mechanism

### Why ID Swapping Exists

**Problem**: Users expect `Model.find(id)` to return the same logical entity across time, not different DB rows.

**Solution**: Swap the meaning of `id`:

- `record.id` returns `bitemporal_id` (logical entity)
- `record.swapped_id` returns actual DB `id`

### Implementation

```ruby
# When loading from DB:
def load
  records.each do |record|
    @_swapped_id = record.id
    record.id = record.bitemporal_id
  end
end

# On find:
def find(*ids)
  # Temporarily redefine primary_key to "bitemporal_id"
  # Then call super
end
```

### The Asymmetry

```ruby
# DB has columns: id (PK), bitemporal_id
# After loading:
record.id              # => bitemporal_id value
record.bitemporal_id   # => bitemporal_id value
record.swapped_id      # => actual id value

# Queries:
Position.pluck(:id)    # => actual ids (SQL query)
Position.map(&:id)     # => bitemporal_ids (Ruby objects)

# Finding:
Position.find(x)                     # Uses bitemporal_id ✓
Position.find_by(id: x)              # Fails! ✗
Position.find_by(bitemporal_id: x)   # Works ✓
Position.where(id: x)                # Fails! ✗
Position.where(bitemporal_id: x)     # Works ✓
```

**Rule**: Always use `bitemporal_id` in WHERE clauses, never `id`.

---

## Query Scoping

### Default Scope Implementation

The gem does NOT use Rails' `default_scope`. Instead, it hooks into query building:

```ruby
def build_arel(*)
  ActiveRecord::Bitemporal.with_bitemporal_option(**bitemporal_option) {
    super
  }
end
```

This injects time filters:

```sql
WHERE valid_from <= NOW()
  AND valid_to > NOW()
  AND transaction_from <= NOW()
  AND transaction_to > NOW()
```

### Scope Hierarchy

```ruby
# No time filtering
.ignore_bitemporal_datetime

# Only valid time filtering (include deleted)
.ignore_transaction_datetime

# Only transaction time filtering (all versions)
.ignore_valid_datetime

# Full filtering (default)
Position.all
```

### How `valid_at` Works

```ruby
def valid_at(datetime, &block)
  with_bitemporal_option(
    ignore_valid_datetime: false,
    valid_datetime: datetime,
    &block
  )
end
```

This sets a thread-local context that affects all queries in the block.

---

## Performance Considerations

### Query Complexity

Every query includes 4 time comparisons:

```sql
WHERE valid_from <= ? AND valid_to > ?
  AND transaction_from <= ? AND transaction_to > ?
```

**Impact**: Indexes are critical. Queries are slower than simple models.

### Locking Strategy

Upstream's `save` and `save!` lock the row valid now (through the default scope) before they write:

```ruby
self.class.where(bitemporal_id: self.id).lock!.pluck(:id) if self.id
```

They then close the row valid at the record's own time, which for a future-dated update is another row. `destroy` takes no lock first: it reads the version it keeps as history, then updates the row it closes.

The timeline operations (`lock_timeline!`, PostgreSQL only) take three locks, in this order, before they read the timeline:

1. **Advisory lock**: `pg_advisory_xact_lock(hashtext(<table_name>), hashtext(<bitemporal_id as text>))`, held until the transaction ends. The key is a public contract: a caller holding it in the same transaction and the operations wait for each other, and an operation called while holding it re-enters it. Unlike a row lock, it holds even when the entity has no row valid now.
2. **Row valid now**: upstream's statement above. Every upstream save locks that row before any other, so an operation holding it makes the save wait while holding nothing. Locking another row first could deadlock with a future-dated save that holds the row valid now and waits for that other row.
3. **Every current-knowledge row**: `FOR UPDATE` with `ignore_valid_datetime` and `transaction_to = ∞`, so an upstream write already in flight on any of them commits before the operation reads the timeline.

**Not covered**: a `save` on an entity with no row valid now locks no row first, and `destroy` reads before it locks. Either can read the timeline before an operation commits and write after it. Callers serialize such writes by holding the same advisory lock, taken before the transaction's first write to the entity.

**Impact**:

- Serializes writes to the same logical entity, within the limits above
- Can cause contention under high concurrency

### Storage Overhead

Every update creates 2-3 new records:

```
1 update = 3 records:
  - before_state (historical, before split)
  - after_state (current, after split)
  - closed_state (original with closed transaction_to)
```

**Mitigation**:

- Archive old transaction-time records periodically
- Partition table by transaction_to

### Transaction Overhead

All updates are wrapped in nested transactions:

```ruby
ActiveRecord::Base.transaction(requires_new: true) do
  # ... update logic ...
end
```

---

## Limitations

### Overlapping Valid Periods

Bitemporal theory prohibits ambiguity - only one state per time point per entity.

```ruby
# This fails:
Position.create(name: "Part-time", valid_from: 'Jan-1', valid_to: 'Jun-30')
Position.create(name: "Full-time", valid_from: 'Mar-1', valid_to: 'Dec-31')
# Error: "Bitemporal has already been taken"
```

**Workaround**: Use different `bitemporal_id` values (different logical entities).

### Rewriting Transaction History

`transaction_at` sets the context for queries, not for writes. You cannot insert records with `transaction_from` in the past.

### Bulk Historical Rewrites

`update_all` bypasses bitemporal logic entirely. Use individual record operations instead.

---

## Visual Diagrams

### Update Operation Timeline

```
Time →
T0          T1          T2
│           │           │
│   Create  │   Update  │

Transaction Time ↓
T0 ─┬─ Record A: VT[T0,∞) ──────────┐
    │                               ↓ (closed at T1)
T1 ─┼─ Record A: VT[T0,∞) TT[T0,T1] ─── (superseded)
    ├─ Record B: VT[T0,T1) TT[T1,∞) ─── (before state)
    └─ Record C: VT[T1,∞) TT[T1,∞)  ─── (after state)
```

### Query at Different Times

```
Current State (TT=now, VT=now):
    SELECT * WHERE TT.from≤now AND TT.to>now
               AND VT.from≤now AND VT.to>now
    Result: Record C

Historical State (TT=now, VT=T0.5):
    SELECT * WHERE TT.from≤now AND TT.to>now
               AND VT.from≤T0.5 AND VT.to>T0.5
    Result: Record B

Knowledge At Time (TT=T0.5, VT=T0.5):
    SELECT * WHERE TT.from≤T0.5 AND TT.to>T0.5
               AND VT.from≤T0.5 AND VT.to>T0.5
    Result: Record A
```

### Cascade Correction

```
Before correction:
    A             B             C
    |-------------|-------------|----------->
    Jan          Mar           May

correct(valid_from: Feb, valid_to: Apr, name: "X")

After correction:
    A    X             B    C
    |----|--------------|----|----->
    Jan  Feb           Apr  May

Transaction time records:
  Old (closed at correction time):
    Record 1: A, VT[Jan,Mar), TT[T1,T2]
    Record 2: B, VT[Mar,May), TT[T1,T2]

  Kept (current, not rewritten):
    Record 3: C, VT[May,∞),   TT[T1,∞)   ← PRESERVED (cascade)

  New (current):
    Record 4: A, VT[Jan,Feb), TT[T2,∞)   ← Trimmed
    Record 5: X, VT[Feb,Apr), TT[T2,∞)   ← CORRECTION
    Record 6: B, VT[Apr,May), TT[T2,∞)   ← Trimmed
```

---

For usage instructions, see [README.md](./README.md).

For comprehensive bitemporal theory, see [BITEMPORAL_CONCEPTS.md](./BITEMPORAL_CONCEPTS.md).
