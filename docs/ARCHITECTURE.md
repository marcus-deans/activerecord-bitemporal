# ActiveRecord::Bitemporal - Architecture Guide

This document covers the internal architecture and implementation details of the gem. For usage instructions, see [README.md](./README.md).

## Table of Contents

1. [Core Architecture](#core-architecture)
2. [Database Schema](#database-schema)
3. [Update Mechanism](#update-mechanism)
4. [Correction Mechanism](#correction-mechanism)
5. [Uniqueness Validation](#uniqueness-validation)
6. [ID Swapping Mechanism](#id-swapping-mechanism)
7. [Query Scoping](#query-scoping)
8. [Performance Considerations](#performance-considerations)
9. [Limitations](#limitations)

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
| `bitemporal_build_cascade_correction_records` | Line 567 | Builds new timeline for corrections |
| `scope_relation` | Line 724 | Uniqueness validation scoping |

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
2. LOCK all records for the entity (prevent concurrent modifications)
3. FIND containing record at valid_from
4. FIND all affected records (from valid_from to valid_to or next change point)
5. BUILD new timeline:
   a. Trim the containing record to end at valid_from
   b. Insert correction record for [valid_from, effective_valid_to)
   c. Trim/preserve subsequent records as needed
   d. Preserve future changes beyond the correction window (CASCADE)
6. CLOSE old records (set transaction_to = now)
7. INSERT new timeline records
8. VALIDATE no overlapping valid times
9. COMMIT TRANSACTION
```

### Critical Ordering

The key insight is that validation must happen AFTER closing old records:

```ruby
# CORRECT ORDER:
1. Lock all records for entity
2. Find affected records
3. Build new timeline
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

**Unbounded** (no `valid_to`): Correction extends to the next change point, fully preserving all future changes.

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

When correcting with only some attributes, non-corrected attributes are inherited from the **containing record at valid_from**, not from `self` (which may be a different time period).

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

Updates use `FOR UPDATE` locks:

```ruby
self.class.where(bitemporal_id: self.id).lock!.pluck(:id) if self.id
```

**Impact**:

- Serializes updates to same logical entity
- Prevents race conditions
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
    Record 3: C, VT[May,∞),   TT[T1,T2]

  New (current):
    Record 4: A, VT[Jan,Feb), TT[T2,∞)   ← Trimmed
    Record 5: X, VT[Feb,Apr), TT[T2,∞)   ← CORRECTION
    Record 6: B, VT[Apr,May), TT[T2,∞)   ← Trimmed
    Record 7: C, VT[May,∞),   TT[T2,∞)   ← PRESERVED (cascade)
```

---

For usage instructions, see [README.md](./README.md).

For comprehensive bitemporal theory, see [BITEMPORAL_CONCEPTS.md](./BITEMPORAL_CONCEPTS.md).
