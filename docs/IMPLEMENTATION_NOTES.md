# ActiveRecord::Bitemporal - Implementation & Architecture Guide

## Table of Contents

1. [Bitemporal Theory Primer](#bitemporal-theory-primer)
2. [Core Architecture](#core-architecture)
3. [Database Schema Deep Dive](#database-schema-deep-dive)
4. [Update Mechanism](#update-mechanism)
5. [Uniqueness Validation](#uniqueness-validation)
6. [ID Swapping Mechanism](#id-swapping-mechanism)
7. [Query Scoping](#query-scoping)
8. [Supported Operations](#supported-operations)
9. [Unsupported Operations](#unsupported-operations)
10. [Edge Cases & Workarounds](#edge-cases--workarounds)
11. [Performance Considerations](#performance-considerations)
12. [Decision Guide](#decision-guide)

---

## Bitemporal Theory Primer

### The Two Time Dimensions

Bitemporal databases track two independent, orthogonal time dimensions:

#### 1. Valid Time (VT)

- **Definition**: When a fact is/was/will be true in the real world
- **Columns**: `valid_from`, `valid_to`
- **Example**: "Employee worked at rate $50/hr from Jan 1 to Mar 31"

#### 2. Transaction Time (TT)

- **Definition**: When the database knew about that fact
- **Columns**: `transaction_from`, `transaction_to`
- **Example**: "We recorded this information on Feb 15"

### The Power of Two Dimensions

This enables queries like:

- **Current state**: "What is true now?" → `VT=now AND TT=now`
- **Historical state**: "What was true on Jan 15?" → `VT=Jan-15 AND TT=now`
- **Knowledge timeline**: "What did we think was true on Jan 15, as of Feb 1?" → `VT=Jan-15 AND TT=Feb-1`

### Bitemporal Invariant

**Core Rule**: At any given transaction time, valid time periods must NOT overlap.

```
Valid at TT=T1:
  Record A: VT[Jan-1, Jan-15)  ✓
  Record B: VT[Jan-15, Feb-1)  ✓
  Record C: VT[Jan-10, Jan-20) ✗ INVALID - overlaps with A and B
```

---

## Core Architecture

The gem consists of several key modules:

### Module Structure

```
ActiveRecord::Bitemporal
├── Persistence         # Create, update, delete logic
├── Uniqueness         # Validation to prevent overlaps
├── Relation           # Query scoping and filtering
├── Callbacks          # Lifecycle hooks
└── Optionable         # Temporal context management
```

### Key Files

| File             | Purpose                     | Location      |
| ---------------- | --------------------------- | ------------- |
| `bitemporal.rb`  | Main module, all components | Line 1-607    |
| `persistence.rb` | Embedded in bitemporal.rb   | Lines 189-531 |
| `uniqueness.rb`  | Embedded in bitemporal.rb   | Lines 533-604 |
| `relation.rb`    | Embedded in bitemporal.rb   | Lines 126-186 |

---

## Database Schema Deep Dive

### Required Columns

```ruby
create_table :positions do |t|
  # Application columns
  t.integer :hourly_rate_cents
  t.references :job

  # Bitemporal columns (REQUIRED)
  t.string :bitemporal_id      # Logical ID (same type as primary key)
  t.datetime :valid_from        # Valid time start
  t.datetime :valid_to          # Valid time end
  t.datetime :transaction_from  # Transaction time start
  t.datetime :transaction_to    # Transaction time end
end

# Recommended indexes
add_index :positions, :bitemporal_id
add_index :positions, [:bitemporal_id, :valid_from, :valid_to]
add_index :positions, [:bitemporal_id, :transaction_from, :transaction_to]
```

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

---

## Update Mechanism

### The `bitemporal_build_update_records` Method

**Location**: `bitemporal.rb:460-530`

This is the core of the gem's update logic. It determines which records to create/modify.

#### Three Scenarios

**Scenario 1: Updating Current Record (force_update=false)**

```ruby
position.update(hourly_rate_cents: 200)
```

**Steps**:

1. Find `current_valid_record` at target datetime
2. Create `before_instance` (old values, ends at update time)
3. Create `after_instance` (new values, starts at update time)
4. Close `current_valid_record.transaction_to = now`

**Result**:

```ruby
# Before:
# ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, ∞)

# After:
# ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, now]      # Closed
# ID=2: rate=100, VT[Jan-1, now], TT[now, ∞)        # Before
# ID=3: rate=200, VT[now, ∞), TT[now, ∞)            # After
```

**Scenario 2: Updating Current Record (force_update=true)**

```ruby
position.force_update { |p| p.update(hourly_rate_cents: 200) }
```

**Steps**:

1. Set `target_datetime = record.valid_from` (line 463) ← **Ignores valid_at context!**
2. Find `current_valid_record` at that time
3. Set `before_instance = nil` (skip detailed history, line 484)
4. Create `after_instance` (new values, **same valid period**)
5. Close `current_valid_record.transaction_to = now`

**Result**:

```ruby
# Before:
# ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, ∞)

# After:
# ID=1: rate=100, VT[Jan-1, ∞), TT[Jan-1, now]      # Closed
# ID=2: rate=200, VT[Jan-1, ∞), TT[now, ∞)          # New (skipped before_instance)
```

**Key Insight - Ignores valid_at:**

```ruby
# Line 463 from bitemporal.rb:
target_datetime = attribute_changed?(valid_from_key) ?
  attribute_was(valid_from_key) :
  self[valid_from_key] if force_update
```

This means `force_update` **always** uses the record's own `valid_from`, ignoring any `valid_at` context:

```ruby
# This does NOT work as expected:
position.valid_at(3.days.ago) do |p|
  p.force_update { |p2| p2.update!(rate: 300) }
end
# The valid_at is IGNORED - uses position.valid_from instead!
```

**Use Cases**:

- **Data Correction**: "We entered the wrong rate" → Use `force_update`
- **Temporal Change**: "Rate changed on day X" → Use regular `update`
- **Cannot combine**: `valid_at + force_update` doesn't make semantic sense (you can't backdate a correction)

**Scenario 3: Updating Non-Existent Record (Gap Filling)**

```ruby
# Position exists: VT[Jan-1, Jan-15), no record at Jan-20
position.valid_at('Jan-20') { |p| p.update(rate: 200) }
```

**Steps**:

1. No `current_valid_record` found
2. Find `nearest_instance` (next future record)
3. Set `before_instance = nil`
4. Create `after_instance` with VT[update-time, nearest.valid_from)

**Result**:

```ruby
# Before:
# ID=1: rate=100, VT[Jan-1, Jan-15), TT[Jan-1, ∞)
# ID=2: rate=150, VT[Feb-1, ∞), TT[Jan-1, ∞)

# After update at Jan-20:
# ID=1: rate=100, VT[Jan-1, Jan-15), TT[Jan-1, ∞)
# ID=2: rate=150, VT[Feb-1, ∞), TT[Jan-1, ∞)
# ID=3: rate=200, VT[Jan-20, Feb-1), TT[now, ∞)    # Fills gap
```

### Critical Code Section

```ruby
# bitemporal.rb:460-530
def bitemporal_build_update_records(valid_datetime:, current_time: Time.current, force_update: false)
  target_datetime = valid_datetime || current_time
  target_datetime = attribute_was(valid_from_key) if force_update

  current_valid_record = self.class.find_at_time(target_datetime, self.id)&.tap { |record|
    record.id = record.swapped_id
    record.clear_changes_information
  }

  before_instance = current_valid_record.dup
  after_instance = build_new_instance

  if current_valid_record.present? && force_update
    current_valid_record.assign_transaction_to(current_time)
    before_instance = nil  # ← Key difference
    after_instance.transaction_from = current_time

  elsif current_valid_record.present?
    current_valid_record.assign_transaction_to(current_time)

    before_instance[valid_to_key] = target_datetime  # ← Splits here
    before_instance.transaction_from = current_time

    after_instance[valid_from_key] = target_datetime  # ← Starts here
    after_instance[valid_to_key] = current_valid_record[valid_to_key]
    after_instance.transaction_from = current_time
  else
    # Gap filling logic...
  end

  [current_valid_record, before_instance, after_instance]
end
```

---

## Uniqueness Validation

### The `scope_relation` Method

**Location**: `bitemporal.rb:539-603`

This validation prevents overlapping valid periods within overlapping transaction periods.

### Validation Logic

```ruby
# Pseudo-code
def scope_relation(record, relation)
  target_datetime = record.valid_datetime || Time.current
  valid_from = record.valid_from || target_datetime
  valid_to = record.valid_to

  # Check for overlapping valid time
  valid_at_scope = finder_class.unscoped.ignore_valid_datetime
    .valid_from_lt(valid_to)      # Starts before our end
    .valid_to_gt(valid_from)      # Ends after our start
    .where.not(id: record.swapped_id)

  # Check for overlapping transaction time
  transaction_from = Time.current
  transaction_to = DEFAULT_TRANSACTION_TO
  transaction_at_scope = finder_class.unscoped
    .transaction_to_gt(transaction_from)
    .transaction_from_lt(transaction_to)

  relation.merge(valid_at_scope).merge(transaction_at_scope)
end
```

### Why Validation Fails for Cascading Updates

**Problem**: When you try to update at a time earlier than existing records:

```ruby
# Step 1: Create
position = Position.create(valid_from: 1.week.ago)
# ID=1: VT[1w-ago, ∞), TT[now, ∞)

# Step 2: Update at 3 days ago
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }
# ID=1: VT[1w-ago, ∞), TT[now, T1]           # Closed
# ID=2: VT[1w-ago, 3d-ago), TT[T1, ∞)        # Before
# ID=3: VT[3d-ago, ∞), TT[T1, ∞)             # After

# Step 3: Try to update at 5 days ago
position.valid_at(5.days.ago) { |p| p.update!(rate: 300) }
# ❌ FAILS!
```

**Why it fails**:

1. Update logic finds Record #2 (valid at 5 days ago)
2. Creates new records: VT[1w, 5d), VT[5d, 3d-ago)
3. Validation runs BEFORE Record #3's TT is closed
4. New record VT[5d, 3d) overlaps with Record #3 VT[3d, ∞)
5. Both have TT overlapping (both end at ∞ during validation)
6. Error: "Bitemporal has already been taken"

**The Missing Step**: The gem doesn't cascade-close future records' transaction times before validating.

### Proper Bitemporal Validation

The CORRECT validation should be:

```
For all records R1, R2 with same bitemporal_id:
  IF R1.transaction_time overlaps R2.transaction_time THEN
    R1.valid_time must NOT overlap R2.valid_time
```

But the gem validates BEFORE closing old transaction times, causing false positives.

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
  # ... load records ...
  records.each do |record|
    # Swap: id ← bitemporal_id, swapped_id ← id
    @_swapped_id = record.id
    record.id = record.bitemporal_id
  end
end

# On find:
def find(*ids)
  all.spawn.yield_self { |obj|
    def obj.primary_key
      "bitemporal_id"  # ← Use bitemporal_id for finding
    end
    obj.method(:find).super_method.call(*ids)
  }
end
```

### The Confusion

This creates asymmetry:

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
Position.find(x)                          # Uses bitemporal_id ✓
Position.find_by(id: x)                   # Fails! ✗
Position.find_by(bitemporal_id: x)        # Works ✓
Position.where(id: x)                     # Fails! ✗
Position.where(bitemporal_id: x)          # Works ✓
```

**Rule of Thumb**: Always use `bitemporal_id` in WHERE clauses, never `id`.

---

## Query Scoping

### Default Scope Implementation

The gem does NOT use Rails' `default_scope`. Instead, it hooks into query building:

```ruby
# bitemporal.rb:151-155
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

# Only valid time filtering
.ignore_transaction_datetime

# Only transaction time filtering
.ignore_valid_datetime

# Full filtering (default)
Position.all
```

### How `valid_at` Works

```ruby
# bitemporal.rb:59-64
def valid_at(datetime, &block)
  with_bitemporal_option(
    ignore_valid_datetime: false,
    valid_datetime: datetime,
    &block
  )
end
```

This sets a thread-local context that affects all queries in the block:

```ruby
Position.valid_at('2024-01-15') do
  Position.all  # ← Uses '2024-01-15' instead of Time.current
end
```

---

## Supported Operations

### ✅ Fully Supported

#### 1. Creating Records (Current or Past)

```ruby
Position.create(rate: 100)
Position.create(rate: 100, valid_from: 1.week.ago)
Position.create(rate: 100, valid_from: '2024-01-01', valid_to: '2024-03-31')
```

#### 2. Simple Updates

```ruby
position.update(rate: 200)
position.save
```

#### 3. Point-in-Time Updates

```ruby
# Split current record at a specific time
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }
```

**Constraint**: Can only split the CURRENT valid record

#### 4. Force Updates

```ruby
# Overwrite without detailed history
position.force_update { |p| p.update(rate: 200) }
```

#### 5. Logical Deletion

```ruby
position.destroy
# Sets transaction_to = now, creates final historical record
```

#### 6. Physical Deletion

```ruby
position.destroy(force_delete: true)
# Actually removes from DB
```

#### 7. Time-Based Queries

```ruby
Position.valid_at('2024-01-15').where(job_id: 1)
Position.find_at_time('2024-01-15', position_id)
Position.ignore_valid_datetime.where(bitemporal_id: x)
```

---

## Unsupported Operations

### ❌ Not Supported

#### 1. Cascading Historical Corrections

**What You Want**:

```ruby
position = Position.create(valid_from: 1.week.ago)
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }

# Realize you need to change from 5 days ago instead
position.valid_at(5.days.ago) { |p| p.update!(rate: 300) }
# ❌ Error: "Bitemporal has already been taken"
```

**Why It Fails**:

- Gem doesn't close future records' transaction times before validation
- Creates overlapping valid periods within same transaction time
- See [Uniqueness Validation](#uniqueness-validation) for details

**Workaround**: Manually close all affected records first (loses history)

#### 2. Overlapping Valid Periods

**What You Want**:

```ruby
# "Position was both part-time and full-time simultaneously"
Position.create(
  name: "Part-time Developer",
  valid_from: '2024-01-01',
  valid_to: '2024-06-30'
)
Position.create(
  name: "Full-time Consultant",
  valid_from: '2024-03-01',  # ← Overlaps!
  valid_to: '2024-12-31'
)
# ❌ Error: "Bitemporal has already been taken"
```

**Why It Fails**: Bitemporal theory prohibits ambiguity - only one state per time point

**Workaround**: Use different `bitemporal_id` values (different logical entities)

#### 3. Rewriting Transaction History

**What You Want**:

```ruby
# "We recorded data at T1, but actually we knew it at T0"
position.transaction_at(1.week.ago) do |p|
  p.update(rate: 200)
end
# ❌ Doesn't work as expected
```

**Why It Fails**: `transaction_at` sets the context for queries, not for writes

**Workaround**: Manually set `transaction_from` with `update_columns` (dangerous)

#### 4. Bulk Historical Rewrites

**What You Want**:

```ruby
# "Actually, the rate was always $300"
Position.ignore_valid_datetime
  .where(bitemporal_id: id)
  .update_all(hourly_rate_cents: 300)
```

**Why It Fails**:

- `update_all` bypasses bitemporal logic
- Need to invalidate old records and create new ones

**Workaround**: Loop through records with `force_update`

---

## Edge Cases & Workarounds

### Edge Case 1: Updating Deleted Records

**Problem**:

```ruby
position.destroy
position.update(rate: 300)  # ❌ Can't find record
```

**Workaround**:

```ruby
Position.ignore_transaction_datetime
  .find_by(bitemporal_id: position.bitemporal_id)
  .force_update { |p| p.update(transaction_to: DEFAULT_TO, rate: 300) }
```

### Edge Case 2: Querying Across Schema Changes

**Problem**: If you add a column after some records exist, old versions won't have values

**Workaround**: Handle nil values gracefully

```ruby
Position.ignore_valid_datetime
  .where(bitemporal_id: id)
  .pluck(:new_column)
  .compact  # Remove nils
```

### Edge Case 3: Finding Record at Non-Existent Time

**Problem**:

```ruby
# Record exists VT[Jan-1, Jan-15), no record at Jan-20
Position.find_at_time('Jan-20', id)  # => nil
```

**Expected**: Different semantics:

- **Last Known State**: Find the most recent record before Jan-20
- **Strict**: Return nil if no exact match

**Current Behavior**: Returns nil (strict)

**Workaround for "Last Known State"**:

```ruby
Position.ignore_valid_datetime
  .where(bitemporal_id: id)
  .where('valid_from <= ?', target_date)
  .order(valid_from: :desc)
  .first
```

### Edge Case 4: Correcting Split History

**Problem**: You split at day 3, but meant to split at day 5

**Current Records**:

```
ID=1: VT[day-1, day-3), TT[T1, ∞)
ID=2: VT[day-3, ∞), TT[T1, ∞)
```

**Want**:

```
ID=?: VT[day-1, day-5), TT[T2, ∞)
ID=?: VT[day-5, ∞), TT[T2, ∞)
```

**Workaround** (destroys history):

```ruby
ActiveRecord::Base.transaction do
  # Close all current records
  Position.ignore_valid_datetime
    .where(bitemporal_id: id)
    .where(transaction_to: DEFAULT_TO)
    .each { |r| r.update_columns(transaction_to: Time.current) }

  # Create correct history
  Position.create(
    bitemporal_id: id,
    valid_from: day_1,
    valid_to: day_5,
    transaction_from: Time.current,
    # ... other attributes ...
  )
  Position.create(
    bitemporal_id: id,
    valid_from: day_5,
    valid_to: DEFAULT_TO,
    transaction_from: Time.current,
    # ... other attributes ...
  )
end
```

---

## Performance Considerations

### Query Complexity

Every query includes 4 time comparisons:

```sql
WHERE valid_from <= ? AND valid_to > ?
  AND transaction_from <= ? AND transaction_to > ?
```

**Impact**:

- Indexes are critical
- Queries are slower than simple models
- EXPLAIN plans show index scans

**Mitigation**:

```sql
CREATE INDEX idx_bitemporal_valid
  ON positions (bitemporal_id, valid_from, valid_to);

CREATE INDEX idx_bitemporal_transaction
  ON positions (bitemporal_id, transaction_from, transaction_to);
```

### Locking Strategy

Updates use `FOR UPDATE` locks:

```ruby
# bitemporal.rb:323
self.class.where(bitemporal_id: self.id).lock!.pluck(:id) if self.id
```

**Impact**:

- Serializes updates to same logical entity
- Can cause contention under high concurrency
- Prevents race conditions

**Mitigation**: Minimize update frequency, batch when possible

### Storage Overhead

Every update creates 2-3 new records:

```ruby
# 1 update = 3 records
before_state      # Historical record (before split)
after_state       # Current record (after split)
closed_state      # Original with closed transaction_to
```

**Impact**:

- Table grows rapidly
- Historical queries scan many rows

**Mitigation**:

- Archive old transaction-time records periodically
- Partition table by transaction_to

### Transaction Overhead

All updates are wrapped in nested transactions:

```ruby
# bitemporal.rb:322, 329, 339
ActiveRecord::Base.transaction(requires_new: true) do
  # ... update logic ...
end
```

**Impact**:

- Increased transaction log writes
- Longer transaction durations

**Mitigation**: Avoid frequent small updates, batch when possible

---

## Decision Guide

### When to Use ActiveRecord::Bitemporal

✅ **Good Fit**:

- Regulatory compliance requiring full audit trails
- Financial systems with temporal reporting requirements
- Systems needing "time-travel" queries
- Applications where correcting past data is common
- Data with legal validity periods

✅ **Example Use Cases**:

- Employee compensation history (rates change, corrections happen)
- Contract lifecycle (start/end dates, amendments)
- Insurance policies (coverage periods, retroactive changes)
- Tax rate tables (effective dates, historical corrections)

### When NOT to Use

❌ **Poor Fit**:

- Simple audit logs (use PaperTrail, Audited)
- Append-only event sourcing (use custom event log)
- High-throughput transactional systems (performance overhead)
- Systems requiring overlapping validity (use different modeling)
- Frequent cascading historical corrections (not supported)

❌ **Anti-Patterns**:

- Using for "undo" functionality (too complex)
- Tracking real-time events (use event stream)
- Versioning documents (use dedicated versioning gem)

### Decision Tree

```
Do you need to query "what was true at time X?"
├─ NO → Use regular ActiveRecord with PaperTrail
└─ YES
   └─ Do you need to correct past data retroactively?
      ├─ NO → Consider simple effective_date pattern
      └─ YES
         └─ Do you need cascading corrections (updating past affects future)?
            ├─ YES → Don't use this gem (or implement custom logic)
            └─ NO
               └─ Can you afford 2-3x storage and 20-40% query overhead?
                  ├─ NO → Reconsider requirements
                  └─ YES → ✅ Use ActiveRecord::Bitemporal
```

### Alternatives to Consider

| Requirement               | Alternative                                       |
| ------------------------- | ------------------------------------------------- |
| Simple audit trail        | PaperTrail, Audited                               |
| Version control           | Vestal Versions, paper_trail-association_tracking |
| Event sourcing            | EventStore, Rails Event Store                     |
| Simple time-based queries | `effective_date` column + scopes                  |
| Complex temporal logic    | Custom implementation with temporal gems          |

---

## Visual Diagrams

### Update Operation Timeline

```
Time →
T0          T1          T2
│           │           │
│   Create  │   Update  │
│           │           │

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

### Cascading Update (Unsupported)

```
Desired Behavior (NOT SUPPORTED):

Step 1: Create
    Record 1: VT[0, ∞), TT[T0, ∞)

Step 2: Update at time 3
    Record 1: VT[0, ∞), TT[T0, T1]      (closed)
    Record 2: VT[0, 3), TT[T1, ∞)
    Record 3: VT[3, ∞), TT[T1, ∞)

Step 3: Update at time 5 (earlier than 3) ← FAILS
    Wants:
    Record 1: VT[0, ∞), TT[T0, T1]      (unchanged)
    Record 2: VT[0, 3), TT[T1, T2]      (should close)
    Record 3: VT[3, ∞), TT[T1, T2]      (should close)
    Record 4: VT[0, 5), TT[T2, ∞)       (new)
    Record 5: VT[5, ∞), TT[T2, ∞)       (new)

    But validation fails because Record 3 not closed yet!
```

---

## Summary

### Key Takeaways

1. **Two Time Dimensions**: Valid time (reality) vs Transaction time (knowledge)

2. **Update Creates 3 Records**: Closed original, before-state, after-state

3. **Uniqueness**: No overlapping valid times within overlapping transaction times

4. **ID Swapping**: `id` returns `bitemporal_id`, use `bitemporal_id` in WHERE clauses

5. **Cascading Updates**: NOT supported - validation runs before closing future records

6. **Performance**: 2-3x storage, 20-40% query overhead, careful indexing required

7. **Best For**: Compliance, auditing, temporal reporting with occasional corrections

8. **Not For**: Frequent cascading corrections, high-throughput, overlapping periods

### Quick Reference: What Works

```ruby
# ✅ Works
Position.create(rate: 100)
Position.create(rate: 100, valid_from: 1.week.ago)
position.update(rate: 200)
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }
position.force_update { |p| p.update(rate: 200) }
Position.valid_at('2024-01-15').where(job_id: 1)
Position.find_at_time('2024-01-15', id)

# ❌ Doesn't Work
position.valid_at(3.days.ago) { |p| p.update!(rate: 200) }
position.valid_at(5.days.ago) { |p| p.update!(rate: 300) }  # Cascading correction

Position.create(valid_from: 'Jan-1', valid_to: 'Jun-30')
Position.create(valid_from: 'Mar-1', valid_to: 'Dec-31')   # Overlap

Position.find_by(id: position.id)       # Use bitemporal_id
Position.where(id: position.id)          # Use bitemporal_id
```

---

For usage instructions, see [README.md](./README.md)

For the gem source, see [activerecord-bitemporal on GitHub](https://github.com/kufu/activerecord-bitemporal)
