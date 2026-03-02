# `shift_genesis` — Conceptual Design & Implementation Plan

Design and implementation plan for adding `shift_genesis(new_valid_from:)` to the `activerecord-bitemporal` gem (`marcus-deans/activerecord-bitemporal`).

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

Every operation either works *within* the timeline's boundaries (update, correct) or at its trailing edge (destroy). There is no operation that modifies the **leading edge** — the point at which the entity began to exist.

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

This is an intentional safety check, not an oversight. `correct()` and `shift_genesis` answer fundamentally different questions:

| | `correct()` | `shift_genesis()` |
|---|---|---|
| **Question** | *"What should the value have been at time T?"* | *"When should this entity's existence have started?"* |
| **Precondition** | T must fall within the existing timeline | Entity must exist (have current-knowledge records) |
| **Changes** | Attribute values within the timeline | The temporal boundary of existence itself |
| **Invariant** | Timeline boundaries stay fixed | Attributes stay fixed |

They are orthogonal operations. `correct()` operates **within** the timeline; `shift_genesis` operates **on** the timeline's boundary.

### Conceptual validity

This is a textbook bitemporal operation. In Snodgrass's bitemporal theory, a genesis shift represents a correction to our knowledge about *when an entity existed*, not *what its attributes were*:

- **Backward shift**: *"We now know (transaction time = now) that this entity was valid starting at an earlier date (valid time = earlier) than we originally recorded."*
- **Forward shift**: *"We now know (transaction time = now) that this entity was not valid as early as we originally recorded."*

In both cases, the transaction-time audit trail preserves the original understanding. No information is lost from the database — only the "current knowledge" view changes.

---

## 2. Theoretical foundation

### 2.1 Classification in Snodgrass's taxonomy

Snodgrass (and later Date/Darwen/Lorentzos) classify temporal operations along two axes — *what changes* (values vs. temporal boundaries) and *scope* (current vs. retroactive). Mapping the gem's operations:

| Operation | Value change? | Temporal change? | Retroactive? |
|-----------|:---:|:---:|:---:|
| `update` | Yes | Yes (splits at now) | No |
| `valid_at { update }` | Yes | Yes (splits at past point) | Yes |
| `force_update` | Yes | No (preserves boundaries) | No |
| `correct` | Yes | Partially (shifts boundaries of affected period) | Yes |
| **`shift_genesis`** | **No** | **Yes (shifts existence boundary)** | **Yes** |

`shift_genesis` occupies a unique cell: it is the only operation that is **purely temporal** with **no value change**. This further validates it as a distinct operation, not a variant of `correct()`.

### 2.2 Entity lifecycle boundaries

In bitemporal theory, an entity has a **lifecycle** defined by its valid-time extent:

```
        genesis                                    terminus
           |                                          |
           v                                          v
    -------[========================================]-------
           ^                                        ^
      min(valid_from)                          max(valid_to)
      across current-knowledge records         across current-knowledge records
```

The lifecycle has two boundaries:
- **Genesis**: When the entity began to exist — `min(valid_from)` across current-knowledge records
- **Terminus**: When the entity ceases to exist — `max(valid_to)` across current-knowledge records (infinity if ongoing)

`correct()` operates **within** the lifecycle. It modifies values or internal segment boundaries, but cannot change the genesis or terminus. `shift_genesis` operates **on** the genesis boundary itself.

There is a natural theoretical companion — `shift_terminus` — that would handle the other end:

| Boundary operation | Meaning |
|---|---|
| `shift_genesis` backward | "Entity existed earlier than we thought" |
| `shift_genesis` forward | "Entity didn't exist as early as we thought" |
| `shift_terminus` backward (hypothetical) | "Entity ended earlier than we thought" |
| `shift_terminus` forward (hypothetical) | "Entity lasted longer than we thought" |

This plan addresses only genesis. Terminus shifting is a separate concern (`destroy` partially covers the "end earlier" case).

### 2.3 SQL:2011 relationship

SQL:2011 defines `UPDATE FOR PORTION OF` and `DELETE FOR PORTION OF` as operations on **single records** that split them at period boundaries. These are **local operations** — they don't cascade.

`shift_genesis` cannot be expressed as a single `FOR PORTION OF` operation:
- **Backward shift** = expanding a period's start. `FOR PORTION OF` can only **narrow** a period, not expand it.
- **Forward shift** = removing a temporal portion across potentially multiple records. `FOR PORTION OF` operates on one record at a time.

This is the same gap that `correct()` fills — the gem provides **entity-level** cascade semantics that the SQL standard doesn't. `shift_genesis` is another entity-level operation built from the same primitives (lock, close, insert).

### 2.4 Backward vs. forward asymmetry

Backward and forward shifts are **not symmetric** in their consequences:

| | Backward shift | Forward shift |
|---|---|---|
| **Information effect** | Additive — entity existed longer | Subtractive — entity existed less |
| **Current knowledge** | Everything preserved + extended | Segments can be erased |
| **Change points** | All preserved | Some may be lost |
| **Reversibility** | Trivially reversible (shift forward again) | Reversible only via audit trail |
| **Risk profile** | Low | Higher |

This asymmetry is inherent to the semantics, not an implementation artifact. The backward case adds existence; the forward case removes it.

### 2.5 Forward shift and "retroactive non-existence"

The forward shift case deserves special theoretical attention. When you shift genesis forward, you're asserting **retroactive non-existence**: *"the entity did not exist during the removed period."*

```
Before:  [Mar 1, Apr 1) = {dept: Engineering}
         [Apr 1, Jun 1) = {dept: Marketing}    ← dept transfer at Apr 1
         [Jun 1, ∞)     = {dept: Management}   ← promotion at Jun 1

Shift genesis to May 1:
         [May 1, Jun 1) = {dept: Marketing}
         [Jun 1, ∞)     = {dept: Management}
```

Three things are erased from **current knowledge**:
1. The entity's existence during [Mar 1, Apr 1) in Engineering
2. The entity's existence during [Apr 1, May 1) in Marketing
3. The **fact that a department transfer occurred at Apr 1**

All three are **preserved in the audit trail** via transaction time — `transaction_at(before_shift).valid_at(Mar 15)` still returns the original data. Nothing is permanently lost.

This is semantically correct: if the entity truly didn't exist before May 1, then the Apr 1 transfer is meaningless — there was no entity to transfer. But it may not be what users *intend*. A user might think "change the start date" without realizing they're also erasing the record of a department transfer. This is why the gem should faithfully execute the temporal operation while the **consumer layer** is responsible for warning users about lost change points.

This is also distinct from a retroactive delete. A retroactive delete could create **gaps** (entity exists, then doesn't, then does again). A genesis shift by definition produces a **contiguous** timeline — it just starts later.

### 2.6 Attribute inheritance on backward shift

When shifting genesis backward, the new genesis record inherits all attribute values from the old genesis record. This is an implicit assertion: *"not only did the entity exist earlier, but it had the same attributes it had at the originally recorded start."*

```
Original: [Mar 1, ∞) rate=$20/hr
Shift to Jan 1: [Jan 1, ∞) rate=$20/hr  ← was it really $20 in January?
```

The design makes `shift_genesis` **purely temporal** — it only answers *when*, not *what*. If attributes differ in the new period, that's a two-step operation:

```ruby
record.shift_genesis(new_valid_from: jan_1)           # extend existence
record.correct(valid_from: jan_1, rate_cents: 1500)   # fix January rate
```

This two-step approach is theoretically cleaner than bundling attribute changes into the genesis shift. It separates the two concerns:
1. "When did the entity start existing?" → `shift_genesis`
2. "What were its attributes at that time?" → `correct`

This aligns with the principle of **orthogonal temporal operations** — each operation should change one concern at a time.

### 2.7 Composability with other operations

An important property: `shift_genesis` composes cleanly with all existing operations because it only touches the genesis boundary.

**`shift_genesis` then `correct()`**: Works naturally. The genesis extends the timeline, then `correct()` can operate within the newly extended range.

**`correct()` then `shift_genesis`**: Also works. Existing corrections are untouched by a backward shift (only genesis changes). For a forward shift, corrections in the truncated range are "lost" from current knowledge (preserved in transaction history).

**Multiple `shift_genesis` calls**: Each creates a new transaction-time entry. The final state reflects the last shift. Audit trail shows the progression.

**`shift_genesis` then `update`/`destroy`**: No interaction. These operate at the current moment, regardless of when the genesis was.

The operation is commutative with `correct()` for the backward case: `shift_genesis(jan_1) → correct(feb_1)` produces the same current-knowledge timeline as `correct(feb_1) → shift_genesis(jan_1)` (assuming the correction's `valid_from` falls within the extended range in both orderings). For the forward case, ordering matters — a forward shift can erase corrections in the truncated range.

---

## 3. Design decisions

### 3.1 Untouched segments remain physically as-is

**Decision**: Only close and replace records that actually change. Segments unaffected by the shift (those after genesis in backward shifts, those at or after `new_valid_from` in forward shifts) keep their original physical rows.

**Alternative considered**: Close and re-create ALL current-knowledge segments (matching `correct()`'s cascade pattern where all affected records get new `transaction_from`).

**Why `correct()` re-creates unchanged cascade records**: `correct()` uses `find_affected_records_for_correction(valid_from)` which fetches all records with `valid_to > correction_valid_from` — everything from the correction point onward. ALL of these are then closed (`records_to_close = affected_records.dup`) and re-created. Records fully after the correction's `valid_to` are re-created with identical attributes and validity periods — only `transaction_from` changes. This is a **side effect of `correct()`'s broad fetch pattern**, not a design principle. Notably, `correct()` itself leaves records entirely *before* the correction point untouched.

**Why "leave untouched" is correct for `shift_genesis`**: The underlying principle in `correct()` is: *close what you affect, leave what you don't.* For `shift_genesis`:
- Backward shift: only the genesis record's `valid_from` changes. Other segments' validity periods, attributes, and temporal meaning are all unchanged.
- Forward shift: only segments before `new_valid_from` are affected. Segments at or after the boundary are unchanged.

**Proof that transaction-time queries remain correct**:

```
Backward shift from Mar 1 to Jan 1, at time T3:

Physical state:
  Row 1: A, valid[Mar, Jun), tx[T1, T3]  ← closed genesis
  Row 2: B, valid[Jun, ∞),   tx[T2, ∞]  ← UNTOUCHED (tx_from = T2)
  Row 3: A, valid[Jan, Jun), tx[T3, ∞]  ← new genesis

Query: transaction_at(T2.5) — "what did we believe between T2 and T3?"
  Row 1: tx_from=T1 ≤ T2.5, tx_to=T3 > T2.5 ✓  → A valid[Mar, Jun)
  Row 2: tx_from=T2 ≤ T2.5, tx_to=∞ > T2.5  ✓  → B valid[Jun, ∞)
  Row 3: tx_from=T3 > T2.5                   ✗
  Result: A[Mar, Jun), B[Jun, ∞) — the pre-shift timeline ✅

Query: transaction_at(T3.5) — "what do we believe now?"
  Row 1: tx_to=T3 ≤ T3.5                    ✗
  Row 2: tx_from=T2 ≤ T3.5, tx_to=∞ > T3.5  ✓  → B valid[Jun, ∞)
  Row 3: tx_from=T3 ≤ T3.5, tx_to=∞ > T3.5  ✓  → A valid[Jan, Jun)
  Result: A[Jan, Jun), B[Jun, ∞) — the post-shift timeline ✅
```

Both queries return the correct timeline. Row 2 (untouched) appears in both views correctly because its `transaction_to` is still ∞ — the genesis shift doesn't change the fact that B was valid from Jun onward.

### 3.2 Forward shift must leave a non-empty timeline

**Decision**: If `new_valid_from >= last_segment.valid_to`, raise `ArgumentError` before any DB writes.

**Rationale**: Shifting genesis past all segments would erase the entity from current knowledge entirely — zero remaining records. This is semantically equivalent to "the entity never existed," which is destroy's territory, not genesis shift's. `shift_genesis` should maintain the entity's existence, just with a different start.

**Note**: When the last segment has `valid_to = ∞` (the common case for ongoing entities), this condition is impossible to satisfy, so infinite timelines can never be fully erased by forward shift. This constraint only applies to bounded timelines.

---

## 4. Method signature and behavior contract

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
- `ArgumentError` if the shift would erase all segments (`new_valid_from >= last_segment.valid_to`)

### What the method does NOT do

- **Change attributes** — purely temporal. Use `correct()` for attribute changes afterward.
- **Enqueue jobs** — consumer's responsibility.
- **Validate business rules** — consumer's responsibility.

---

## 5. Internal mechanics

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

## 6. Edge cases

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

### Edge 14: Forward shift would erase everything
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, Jun 1) = B
Shift to Jun 1:
```
All segments have `valid_to <= Jun 1`. No segment would survive.
Check: `new_valid_from (Jun 1) >= last_segment.valid_to (Jun 1)` → `ArgumentError`.
Evaluated before any DB writes — clean early return.

Note: when the last segment has `valid_to = ∞`, this is impossible to trigger. Only applies to bounded timelines.

### Edge 15: correct() then backward shift
```
Start:    [Mar 1, ∞) = {name: A}
correct(Apr 1, name: B):
          [Mar 1, Apr 1) = {name: A}, [Apr 1, ∞) = {name: B}
Shift to Jan 1:
          [Jan 1, Apr 1) = {name: A}    ← genesis extended
          [Apr 1, ∞) = {name: B}        ← untouched
```
The correction is preserved. Genesis just extends backward.

### Edge 16: Forward shift then correct outside new range
```
Start:    [Mar 1, Jun 1) = A, [Jun 1, ∞) = B
Shift to May 1: [May 1, Jun 1) = A, [Jun 1, ∞) = B
correct(valid_from: Apr 1, name: X):
→ RecordNotFound — Apr 1 is before the new genesis
```
Correct behavior — the timeline no longer extends to Apr 1.

### Edge 17: Forward shift to intermediate segment boundary
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, Jun 1) = B, [Jun 1, ∞) = C
Shift to Apr 1:
After:   [Apr 1, Jun 1) = B, [Jun 1, ∞) = C
```
A closed (entirely before). B starts exactly at Apr 1 → untouched, becomes new genesis. C also untouched.

### Edge 18: Forward shift to last segment boundary
```
Before:  [Mar 1, Apr 1) = A, [Apr 1, Jun 1) = B, [Jun 1, ∞) = C
Shift to Jun 1:
After:   [Jun 1, ∞) = C
```
A and B closed (entirely before). C starts exactly at Jun 1 → untouched, becomes genesis.

### Edge 19: Bounded timeline backward shift
```
Before:  [Mar 1, Jun 1) = A       ← ends at Jun 1, not infinity
Shift to Jan 1:
After:   [Jan 1, Jun 1) = A       ← valid_to preserved at Jun 1
```
Works identically to the unbounded case. `valid_to` is preserved regardless of whether it's finite or infinite.

### Edge case classification completeness

For forward shift, the four segment categories are exhaustive given the `valid_from < valid_to` invariant:

| Category | Condition | Action |
|----------|-----------|--------|
| Entirely before | `valid_to <= new_valid_from` | Close, no replacement |
| Spans boundary | `valid_from < new_valid_from < valid_to` | Close + trimmed replacement |
| Starts exactly | `valid_from == new_valid_from` | Untouched, stop |
| Entirely after | `valid_from > new_valid_from` | Untouched, stop |

These are mutually exclusive and exhaustive. No segment can fall outside these categories.

---

## 7. Forward shift mechanics — detailed

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

### The "lost" changes and retroactive non-existence

Forward shifts assert **retroactive non-existence**: the entity did not exist during the removed period. This has three categories of information loss from current knowledge:

1. **Entity existence** in the removed period — queries at those times now return nil
2. **Attribute values** that held during the removed period — no longer accessible via `valid_at`
3. **Change points** that fell within the removed period — the historical fact that a transition occurred is no longer represented in current knowledge

All three are **preserved in the audit trail** via transaction time:
- `transaction_at(before_shift).valid_at(Mar 15)` → returns the original data
- Nothing is permanently lost from the database

This is correct bitemporal behavior. The **consumer layer** (not the gem) should warn users about lost change points before proceeding. The gem should faithfully execute the temporal operation without gatekeeping.

**Distinction from retroactive delete**: A retroactive delete could create **gaps** in the timeline (entity exists, then doesn't, then does again). A genesis shift by definition produces a **contiguous** timeline starting at the new genesis — no gaps.

---

## 8. Physical row traces

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

## 9. Scope interaction proof

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

## 10. `.dup` mechanics

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

## 11. Test plan

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

**Category 3: No-op and errors (4 tests)**
1. Shift to current genesis date → returns true, no DB changes
2. Soft-deleted entity → raises RecordNotFound
3. Shift past all segments (bounded timeline) → raises ArgumentError
4. Attributes are NOT changed (shift is purely temporal)

**Category 4: Audit trail (2 tests)**
1. After backward shift: `transaction_at(before_shift).valid_at(pre_genesis_date)` returns nil
2. After backward shift: `transaction_at(before_shift).valid_at(post_genesis_date)` returns original

**Category 5: Timeline integrity (2 tests)**
1. After shift: no overlapping valid periods (validated by `validate_cascade_correction_timeline!`)
2. After shift: timeline is contiguous (no gaps between segments)

**Category 6: Concurrency (1 test)**
1. Concurrent shifts on same entity → one succeeds, other blocks then succeeds with updated state

**Category 7: Interaction with correct() (3 tests)**
1. Backdate then correct within extended range → works
2. Correct then backdate → genesis extends, correction untouched
3. Forward shift then correct outside new range → raises RecordNotFound

---

## 12. Relationship to domain layer

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
