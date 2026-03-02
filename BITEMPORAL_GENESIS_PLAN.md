# `shift_genesis` — Gem Implementation Plan

Implementation plan for adding `shift_genesis(new_valid_from:)` to the `activerecord-bitemporal` gem (`marcus-deans/activerecord-bitemporal`).

---

## 1. Motivation

### The gap in the gem's API

The gem provides four timeline operations:

| Operation | Method | Meaning |
|-----------|--------|---------|
| Create | `save` / `create` | Start a new timeline |
| Update | `update` | Add a segment from now forward |
| Correct | `correct(valid_from:, ...)` | Modify values at any point *within* the timeline |
| Destroy | `destroy` | End the timeline |
| **Shift genesis** | **missing** | **Change when the timeline started** |

### Why `correct()` can't fill this gap

`correct()` requires a "containing record" at the target `valid_from` — a record whose `[valid_from, valid_to)` spans the requested date (`bitemporal.rb:468-477`). If no such record exists (because the date is before the timeline started), it raises `RecordNotFound`.

```ruby
# bitemporal.rb:468-477
containing_record = affected_records.find { |r|
  r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
}

if containing_record.nil?
  raise ActiveRecord::RecordNotFound.new(...)
end
```

This is an intentional safety check — `correct()` answers *"what should the value have been at time T?"* and T must fall within the existing timeline. Genesis shift answers a different question: *"when should the entity's existence have started?"*

### Conceptual validity

This is a textbook bitemporal operation. In Snodgrass's bitemporal theory, a genesis backdate represents: *"We now know (transaction time = now) that this entity was valid starting at an earlier date (valid time = earlier) than we originally recorded."* The transaction-time audit trail preserves the original understanding.

---

## 2. Method signature and behavior contract

### Signature

```ruby
# On any model that includes ActiveRecord::Bitemporal
record.shift_genesis(new_valid_from:)
```

### Behavior by direction

**Backward shift** (`new_valid_from < current genesis.valid_from`):
1. Lock all versions of this `bitemporal_id`
2. Find the genesis segment (earliest `valid_from` with `transaction_to = DEFAULT_TRANSACTION_TO`)
3. Close old genesis: `update_transaction_to(current_time)`
4. Create replacement: same `bitemporal_id`, same attributes, same `valid_to`, new `valid_from`
5. Validate timeline integrity via `validate_cascade_correction_timeline!`
6. Update `self` to point at the currently-valid record (same self-swap pattern as `correct()`)

**Forward shift** (`new_valid_from > current genesis.valid_from`):
1. Lock all versions of this `bitemporal_id`
2. Find all current-knowledge segments ordered by `valid_from`
3. Close segments entirely before `new_valid_from` (their `valid_to <= new_valid_from`)
4. If the segment spanning `new_valid_from` already has `valid_from == new_valid_from`: leave it untouched
5. Otherwise: close it and create a trimmed replacement with `valid_from = new_valid_from`
6. Leave segments entirely after `new_valid_from` untouched
7. Validate timeline integrity
8. Update `self` to point at the currently-valid record

**No-op** (`new_valid_from == current genesis.valid_from`):
Return `true` without changes.

### Return value

`true` on success. Raises on failure (matching `correct()`'s behavior):
- `ActiveRecord::RecordNotFound` if the entity is destroyed (no current-knowledge records)

### What the method does NOT do

- **Change attributes** — purely temporal. Use `correct()` for attribute changes afterward.
- **Enqueue jobs** — consumer's responsibility.
- **Validate business rules** — consumer's responsibility.

---

## 3. Internal mechanics

### Template: how `correct()` structures its internals

`correct()` at `bitemporal.rb:456-517` follows this pattern:

```ruby
def _correct_record(valid_from:, valid_to:, attributes:)
  current_time = Time.current

  ActiveRecord::Base.transaction(requires_new: true) do
    # 1. Lock
    self.class.where(bitemporal_id: bitemporal_id).lock!.pluck(:id)

    # 2. Find affected records
    affected_records = find_affected_records_for_correction(valid_from)

    # 3. Build new timeline (dup + assign + set time columns)
    records_to_close, new_timeline = bitemporal_build_cascade_correction_records(...)

    # 4. Close old records
    records_to_close.each { |r| r.update_transaction_to(current_time) }

    # 5. Insert new records
    new_timeline.each { |r| r.save_without_bitemporal_callbacks!(validate: false) }

    # 6. Validate
    validate_cascade_correction_timeline!

    # 7. Update self
    current_record = new_timeline.find { |r| ... } || new_timeline.last
    @_swapped_id = current_record.swapped_id
    self[valid_from_key] = current_record[valid_from_key]
    # ... etc
  end
end
```

`shift_genesis` follows the exact same structural pattern.

### Algorithm: backward shift

```ruby
def _shift_genesis_backward(new_valid_from, current_time)
  # Find genesis
  genesis = current_knowledge_segments.first  # ordered by valid_from

  # Close old genesis
  genesis.update_transaction_to(current_time)

  # Create replacement
  new_genesis = genesis.dup
  new_genesis.id = nil
  new_genesis[valid_from_key] = new_valid_from
  # valid_to stays the same — just extending the start
  new_genesis.transaction_from = current_time
  new_genesis.transaction_to = DEFAULT_TRANSACTION_TO
  new_genesis.save_without_bitemporal_callbacks!(validate: false)
end
```

### Algorithm: forward shift

```ruby
def _shift_genesis_forward(new_valid_from, current_time)
  segments = current_knowledge_segments  # ordered by valid_from

  segments.each do |segment|
    if segment[valid_to_key] <= new_valid_from
      # Entirely before new genesis — close it
      segment.update_transaction_to(current_time)

    elsif segment[valid_from_key] < new_valid_from
      # Spans the new genesis date — close and create trimmed replacement
      segment.update_transaction_to(current_time)

      trimmed = segment.dup
      trimmed.id = nil
      trimmed[valid_from_key] = new_valid_from
      trimmed.transaction_from = current_time
      trimmed.transaction_to = DEFAULT_TRANSACTION_TO
      trimmed.save_without_bitemporal_callbacks!(validate: false)

    elsif segment[valid_from_key] == new_valid_from
      # Starts exactly at new genesis — already correct, no change needed
      break

    else
      # Entirely after — stop processing
      break
    end
  end
end
```

### Helper: find current-knowledge segments

```ruby
def current_knowledge_segments
  self.class
    .where(bitemporal_id: bitemporal_id)
    .ignore_valid_datetime
    .where(transaction_to: DEFAULT_TRANSACTION_TO)
    .order(valid_from_key => :asc)
    .to_a
    .each { |record|
      record.id = record.swapped_id
      record.clear_changes_information
    }
end
```

This is identical to `find_affected_records_for_correction` (bitemporal.rb:519-531) but without the `valid_to > correction_valid_from` filter — we need ALL segments.

---

## 4. Edge cases

### Edge 1: Single-segment timeline
```
Before:  [Mar 1, ∞) = A
Shift to Jan 1:
After:   [Jan 1, ∞) = A
```
Backward shift. Close genesis, create replacement with earlier `valid_from`.

### Edge 2: Timeline with future changes
```
Before:  [Mar 1, Jun 1) = A     ← genesis
         [Jun 1, ∞) = B         ← future change
Shift to Jan 1:
After:   [Jan 1, Jun 1) = A     ← genesis extended
         [Jun 1, ∞) = B         ← untouched
```
Only genesis changes. `valid_to` stays at `Jun 1`.

### Edge 3: Timeline with past corrections
```
Before:  [Mar 1, Apr 15) = A    ← genesis (split by earlier correction)
         [Apr 15, ∞) = B        ← correction
Shift to Jan 1:
After:   [Jan 1, Apr 15) = A    ← genesis extended
         [Apr 15, ∞) = B        ← untouched
```

### Edge 4: Many stacked changes
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, Jun 1) = B, [Jun 1, Sep 1) = C, [Sep 1, ∞) = D
Shift to Jan 1:
After:   [Jan 1, Apr 1) = A     ← only this changes
         rest untouched
```

### Edge 5: No-op
```
Shift to current genesis date → return true, no DB changes
```

### Edge 6: Forward shift within genesis
```
Before:  [Mar 1, Jun 1) = A, [Jun 1, ∞) = B
Shift to Apr 15:
After:   [Apr 15, Jun 1) = A    ← trimmed
         [Jun 1, ∞) = B         ← untouched
```

### Edge 7: Forward shift past first change point
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, ∞) = B
Shift to Apr 2:
After:   [Apr 2, ∞) = B         ← trimmed, becomes new genesis
```
Genesis A is closed (entirely before Apr 2). Segment B is trimmed (spans Apr 2).

### Edge 8: Forward shift to exact segment boundary
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, ∞) = B
Shift to Apr 1:
After:   [Apr 1, ∞) = B         ← physically unchanged, now the genesis
```
Genesis A is closed. Segment B already starts at Apr 1 — no trimming needed. B's physical row is untouched.

### Edge 9: Forward shift past multiple change points
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, Jun 1) = B, [Jun 1, ∞) = C
Shift to May 1:
After:   [May 1, Jun 1) = B     ← trimmed, new genesis
         [Jun 1, ∞) = C         ← untouched
```
Genesis A closed (entirely before May 1). Segment B trimmed (spans May 1). Segment C untouched.

### Edge 10: Sequential shifts
```
Start:   [Mar 1, ∞) = A
Shift to Feb 1: [Feb 1, ∞) = A     (audit: T1)
Shift to Jan 1: [Jan 1, ∞) = A     (audit: T2)
```
Each creates a new transaction-time entry. Audit trail shows progressive knowledge corrections.

### Edge 11: Soft-deleted entity
No current-knowledge records exist → raise `ActiveRecord::RecordNotFound`.

### Edge 12: Concurrent shifts
Row-level locking via `lock!` prevents data corruption. One transaction blocks until the other commits.

### Edge 13: Backdate followed by correct()
```
Start:    [Mar 1, ∞) = {name: A}
Backdate: [Jan 1, ∞) = {name: A}
Correct(Feb 1, name: B):
          [Jan 1, Feb 1) = {name: A}
          [Feb 1, ∞) = {name: B}
```
After backdate, `correct()` works within the extended range because the genesis now spans `[Jan 1, ∞)`.

---

## 5. Forward shift mechanics — detailed

### Segment classification

Every segment in the timeline falls into one of four categories relative to `new_valid_from`:

| Category | Condition | Action |
|----------|-----------|--------|
| Entirely before | `segment.valid_to <= new_valid_from` | Close (set `transaction_to = now`) |
| Spans the boundary | `segment.valid_from < new_valid_from < segment.valid_to` | Close and create trimmed replacement |
| Starts exactly at boundary | `segment.valid_from == new_valid_from` | No change needed |
| Entirely after | `segment.valid_from > new_valid_from` | No change needed |

### Example: forward shift past multiple segments

```
Current timeline:
  [Mar 1, Apr 1) = {ce: medical}      ← genesis
  [Apr 1, Jun 1) = {ce: dental}       ← change 1
  [Jun 1, ∞) = {ce: vision}           ← change 2

Shift to May 1:

Genesis [Mar 1, Apr 1):  valid_to = Apr 1 <= May 1  → entirely before → CLOSE
Change 1 [Apr 1, Jun 1): valid_from = Apr 1 < May 1, valid_to = Jun 1 > May 1 → SPANS → CLOSE + TRIM
Change 2 [Jun 1, ∞):     valid_from = Jun 1 > May 1 → entirely after → UNTOUCHED

Result:
  [May 1, Jun 1) = {ce: dental}       ← new genesis (trimmed from change 1)
  [Jun 1, ∞) = {ce: vision}           ← unchanged
```

### The "lost" changes

Segments closed during a forward shift are preserved in the transaction-time audit trail:
- **Valid-time queries**: `batch_valid_as_of(time: Mar 15, ...)` → nil (entity doesn't exist at that time anymore)
- **Audit queries**: `transaction_at(before_shift).valid_at(Mar 15)` → returns the original genesis

This is correct bitemporal behavior. The consumer (domain layer) should warn users about lost change points before proceeding.

---

## 6. Physical row traces

### Backward shift — single segment

**Before:**
```
Row 1: swapped_id=uuid-001, bitemporal_id=100
       valid_from=Mar 1, valid_to=∞
       transaction_from=T0, transaction_to=∞
       name="A", ce=medical
```

**After shift to Jan 1 (at time T1):**
```
Row 1 (CLOSED):
       swapped_id=uuid-001, bitemporal_id=100
       valid_from=Mar 1, valid_to=∞
       transaction_from=T0, transaction_to=T1          ← closed

Row 2 (CURRENT):
       swapped_id=uuid-002, bitemporal_id=100
       valid_from=Jan 1, valid_to=∞                    ← earlier start
       transaction_from=T1, transaction_to=∞           ← current knowledge
       name="A", ce=medical                            ← same attributes
```

### Backward shift — multi-segment

**Before:**
```
Row 1: btid=100, valid_from=Mar 1, valid_to=Jun 1, tx_to=∞, name="A", ce=medical
Row 2: btid=100, valid_from=Jun 1, valid_to=∞,     tx_to=∞, name="A", ce=dental
```

**After shift to Jan 1 (at time T1):**
```
Row 1 (CLOSED): btid=100, valid_from=Mar 1, valid_to=Jun 1, tx_to=T1
Row 2 (CURRENT): btid=100, valid_from=Jun 1, valid_to=∞,    tx_to=∞   ← UNTOUCHED
Row 3 (CURRENT): btid=100, valid_from=Jan 1, valid_to=Jun 1, tx_from=T1, tx_to=∞  ← new genesis
```

### Forward shift — past change point

**Before:**
```
Row 1: btid=100, valid_from=Mar 1, valid_to=Apr 1, tx_to=∞, name="A"
Row 2: btid=100, valid_from=Apr 1, valid_to=∞,     tx_to=∞, name="B"
```

**After shift to Apr 2 (at time T1):**
```
Row 1 (CLOSED): btid=100, valid_from=Mar 1, valid_to=Apr 1, tx_to=T1   ← entirely before
Row 2 (CLOSED): btid=100, valid_from=Apr 1, valid_to=∞,     tx_to=T1   ← spans, closed
Row 3 (CURRENT): btid=100, valid_from=Apr 2, valid_to=∞, tx_from=T1, tx_to=∞, name="B"  ← trimmed
```

### Forward shift — exact boundary

**Before:**
```
Row 1: btid=100, valid_from=Mar 1, valid_to=Apr 1, tx_to=∞, name="A"
Row 2: btid=100, valid_from=Apr 1, valid_to=∞,     tx_to=∞, name="B"
```

**After shift to exactly Apr 1 (at time T1):**
```
Row 1 (CLOSED): btid=100, valid_from=Mar 1, valid_to=Apr 1, tx_to=T1   ← closed
Row 2 (CURRENT): btid=100, valid_from=Apr 1, valid_to=∞,    tx_to=∞    ← UNTOUCHED, now genesis
```

Row 2 is not closed/reopened because it already starts at the correct date.

---

## 7. Scope interaction proof

### The two default scopes

1. **Transaction scope**: `WHERE transaction_to = DEFAULT_TRANSACTION_TO` (∞)
2. **Valid-time scope**: `WHERE valid_from <= Time.current AND valid_to > Time.current`

### Query traces after backward shift (Jan 1 ← Mar 1)

Using the physical rows from section 6 (Row 1 closed, Row 2 current).

**`Model.find(100)` at Time.current = Feb 15:**
- `transaction_to = ∞`: Row 2 only
- `valid_from <= Feb 15 < valid_to`: Row 2 (`Jan 1 <= Feb 15 < ∞`) ✓
- **Returns Row 2** ✓

**`batch_valid_as_of(time: Feb 1, bitemporal_ids: [100])`:**
- `valid_at(Feb 1)`: `valid_from <= Feb 1 < valid_to`
- Row 2: `Jan 1 <= Feb 1 < ∞` ✓
- **Returns Row 2** ✓ (previously returned nil — Feb 1 was before the timeline)

**`batch_valid_as_of(time: Dec 15 2024, bitemporal_ids: [100])` (before new genesis):**
- Row 2: `Jan 1 2025 <= Dec 15 2024`? No
- **Returns nil** ✓ — entity didn't exist yet

**`future_versions(bitemporal_ids: [100])` at Time.current = Feb 15:**
- `ignore_valid_datetime` + `where(valid_from: Time.current..)`
- Row 2: `valid_from = Jan 1`, `Jan 1 >= Feb 15`? No
- **Returns empty** ✓ — backdate creates no future segments

**Audit: `Model.transaction_at(T0).valid_at(Feb 1).find_by(bitemporal_id: 100)`:**
- `transaction_at(T0)`: `tx_from <= T0 < tx_to` → Row 1 only (Row 2 has `tx_from = T1 > T0`)
- `valid_at(Feb 1)`: Row 1 has `valid_from = Mar 1`, `Mar 1 <= Feb 1`? No
- **Returns nil** ✓ — at T0, we didn't know the entity existed at Feb 1

**Audit: `Model.transaction_at(T0).valid_at(Apr 1).find_by(bitemporal_id: 100)`:**
- Row 1: `Mar 1 <= Apr 1 < ∞` ✓
- **Returns Row 1** ✓ — at T0, we thought the entity had value A at Apr 1

### Query traces after forward shift (Apr 2 ← Mar 1, past change point)

Using the physical rows from section 6 (Rows 1,2 closed, Row 3 current).

**`Model.find(100)` at Time.current = Apr 15:**
- `transaction_to = ∞`: Row 3 only
- `valid_from <= Apr 15 < valid_to`: `Apr 2 <= Apr 15 < ∞` ✓
- **Returns Row 3** ✓

**`batch_valid_as_of(time: Mar 15, bitemporal_ids: [100])`:**
- `transaction_to = ∞`: Row 3 only
- `valid_from <= Mar 15`: `Apr 2 <= Mar 15`? No
- **Returns nil** ✓ — entity no longer exists at Mar 15

**`batch_valid_as_of(time: Apr 5, bitemporal_ids: [100])`:**
- Row 3: `Apr 2 <= Apr 5 < ∞` ✓
- **Returns Row 3 (name="B")** ✓

### Association behavior

- FKs reference `bitemporal_id` (logical entity ID) → stable across physical row changes ✓
- `dom_id(record)` uses `.id` which returns `bitemporal_id` → Turbo Frame IDs stable ✓
- `includes(:compensation_element)` loads from the returned row → correct attributes ✓

---

## 8. `.dup` mechanics

### The gem's dup refinement

```ruby
# bitemporal.rb:315-323
refine ActiveRecord::Base do
  def dup(*)
    super.tap { |itself|
      itself.instance_exec do
        @_swapped_id_previously_was = nil
        @_swapped_id = nil
        @previously_force_updated = false
      end unless itself.frozen?
    }
  end
end
```

**What this does:**
- Clears internal swap tracking (`@_swapped_id`)
- Preserves ALL attributes including `bitemporal_id`
- Standard AR `dup` nils out the primary key column (`id`), but since the gem overrides `.id` → `bitemporal_id`, the physical `id` is nil (triggers INSERT on save) while `bitemporal_id` is preserved (same logical entity)

**This is the exact pattern `correct()` uses internally:**
```ruby
# bitemporal.rb:590-598
correction_record = containing_record.dup
correction_record.id = nil
correction_record.assign_attributes(attributes)
correction_record[valid_from_key] = valid_from
correction_record[valid_to_key] = valid_to
correction_record.transaction_from = current_time
correction_record.transaction_to = DEFAULT_TRANSACTION_TO
```

### `_create_record` override interaction

When `save_without_bitemporal_callbacks!(validate: false)` is called on a dup'd record:

1. `save!` is called with `ignore_bitemporal_callbacks: true` (skips `around_create` callbacks)
2. `_create_record` still runs (it's an override, not a callback):
   ```ruby
   def _create_record(attribute_names = self.attribute_names)
     bitemporal_assign_initialize_value(valid_datetime: self.valid_datetime)
     ActiveRecord::Bitemporal.valid_at!(self[valid_from_key]) { super() }
   end
   ```
3. `bitemporal_assign_initialize_value` (line 622-637):
   - Sets `valid_from = current_time` only if `valid_from == DEFAULT_VALID_FROM` — we've set it explicitly, **no override** ✓
   - Sets `transaction_from = current_time` only if `transaction_from == DEFAULT_TRANSACTION_FROM` — we've set it explicitly, **no override** ✓
4. `valid_at!(valid_from)` sets scope context for the INSERT — doesn't affect column values ✓
5. `super()` performs standard AR INSERT with our exact column values ✓

### `after_initialize` callback

The gem registers `after_initialize { self.bitemporal_id ||= SecureRandom.uuid }`. On `dup`, Rails triggers `after_initialize`. But since `bitemporal_id` is already set (copied from the original), `||=` doesn't overwrite it. ✓

---

## 9. Test plan

### Spec file

`spec/activerecord-bitemporal/shift_genesis_spec.rb` (or wherever the gem's specs live)

### Test categories

**Category 1: Backward shift (5 tests)**
1. Single segment → extends valid_from, preserves attributes
2. Multi-segment → only genesis changes, future segments untouched
3. Timeline with prior corrections → genesis extends, corrections untouched
4. Sequential backward shifts → each creates audit trail entry
5. Verify `self` instance is updated after shift (valid_from, swapped_id)

**Category 2: Forward shift (6 tests)**
1. Single segment → trims valid_from
2. Forward within genesis (not past first change) → genesis trimmed
3. Forward past one change point → genesis closed, spanning segment trimmed
4. Forward past multiple change points → multiple segments closed
5. Forward to exact segment boundary → covering segment untouched, earlier segments closed
6. Verify `self` instance is updated after shift

**Category 3: No-op and errors (3 tests)**
1. Shift to current genesis date → returns true, no DB changes
2. Soft-deleted entity → raises RecordNotFound
3. Attributes are NOT changed (shift is purely temporal)

**Category 4: Audit trail (2 tests)**
1. After backward shift: `transaction_at(before_shift).valid_at(pre_genesis_date)` returns nil
2. After backward shift: `transaction_at(before_shift).valid_at(post_genesis_date)` returns original

**Category 5: Timeline integrity (2 tests)**
1. After shift: no overlapping valid periods (validated by `validate_cascade_correction_timeline!`)
2. After shift: timeline is contiguous (no gaps between segments)

**Category 6: Concurrency (1 test)**
1. Concurrent shifts on same entity → one succeeds, other blocks then succeeds with updated state

**Category 7: Interaction with correct() (2 tests)**
1. Backdate then correct within extended range → works
2. Correct then backdate → genesis extends, correction untouched

---

## 10. Relationship to domain layer

### What the gem provides

A single method: `shift_genesis(new_valid_from:)` that handles the bitemporal mechanics. It:
- Locks, closes old rows, creates replacements
- Validates timeline integrity
- Updates `self` to point at the currently-valid record
- Returns `true` on success

### What the consumer (DSPTCH) wraps around it

A domain service (e.g., `Payrolls::ExternalMaps::ShiftGenesis`) that:
- Converts dates to times (`beginning_of_day`)
- Validates business rules:
  - For forward shifts: are there actuals/line items in the truncated range?
  - For forward shifts: how many change points are being removed? (for UX warning)
- Calls `external_map.shift_genesis(new_valid_from:)`
- Enqueues recalculation jobs (`SyncExternalMapTimeCardActualsJob`)
- Returns boolean with errors on the model for form re-rendering

This mirrors the existing pattern: the gem provides `correct()`, DSPTCH wraps it in `Payrolls::ExternalMaps::Correct` with pre-validation and job enqueueing.
