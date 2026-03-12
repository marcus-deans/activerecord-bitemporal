# Gem Feature: Timeline Termination for `activerecord-bitemporal`

## The Problem

Bitemporal entities have timelines that, by default, extend to `DEFAULT_VALID_TO` (the "forever"
sentinel). There's no way to say "this entity's timeline ends at a specific date." The gem provides
`shift_genesis` to control when a timeline *begins*, but nothing to control when it *ends*.

In practice, users need to schedule the end of a mapping — for example, "this compensation mapping
should stop being used after March 31." Currently, the app has no way to express this without
destroying the entity entirely, which loses the historical record.

### What Termination Means

A terminated entity:

- Still exists in the golden path (current-knowledge records)
- Still participates in `valid_at(date_before_termination)` queries
- Returns nothing for `valid_at(date_after_termination)`
- Has a finite `valid_to` on its last golden-path segment (not `DEFAULT_VALID_TO`)

A terminated entity is **not destroyed**. It retains full audit trail and history.

---

## Terminate vs Destroy

This is a critical distinction:

| Aspect | `destroy` (existing) | `terminate` (new) |
|--------|---------------------|-------------------|
| **Dimension** | Transaction time | Valid time |
| **What it does** | Closes the record in the current transaction | Truncates the timeline at a point in valid time |
| **Entity visibility** | Entity disappears from default scope | Entity remains visible before termination date |
| **Audit trail** | Superseded records accessible via transaction time | Terminated segment remains in golden path |
| **Reversibility** | Requires re-creation | `cancel_termination` restores open-ended timeline |
| **Use case** | "This record was entered incorrectly" | "This entity stops being valid on date X" |

Think of it this way:
- `shift_genesis` controls the **left edge** of the timeline
- `terminate` controls the **right edge** of the timeline
- `correct` changes **what happened** within the timeline
- `destroy` removes the entity from **current knowledge**

---

## Public API

### `terminate(termination_time:)`

Set a finite end date for this entity's timeline.

```ruby
record.terminate(termination_time: Date.new(2026, 4, 1).beginning_of_day)
# => true
```

**Parameters:**
- `termination_time` — `Time`, `Date`, or `String`. Converted via `.in_time_zone` if available.

**Returns:** `true` if successful.

**Raises:**
- `ActiveRecord::RecordNotFound` if no current-knowledge records exist for this `bitemporal_id`
- `ArgumentError` if `termination_time <= first segment's valid_from`
- `ArgumentError` if `termination_time > last segment's valid_to`

**No-op:** If the entity is already terminated at exactly `termination_time`, returns `true`
without database changes (same pattern as `shift_genesis` when `new_valid_from` equals the
current genesis).

### `cancel_termination`

Restore a terminated entity's timeline to open-ended.

```ruby
record.cancel_termination
# => true
```

**Parameters:** None.

**Returns:** `true` if successful.

**Raises:**
- `ActiveRecord::RecordNotFound` if no current-knowledge records exist

**No-op:** If the entity is not terminated (last segment already has `DEFAULT_VALID_TO`),
returns `true` without database changes.

### `terminated?`

Whether this entity's timeline has a finite end.

```ruby
record.terminated?
# => true/false
```

**Returns:** `Boolean`. `true` if the last golden-path segment's `valid_to < DEFAULT_VALID_TO`.

**Note:** This queries the database for the actual last segment. The instance in hand (`self`)
may not be the last segment (e.g., the caller might hold a historical version).

---

## Behavioral Requirements

### `terminate` — Single-Segment Entity

Starting timeline:
```
Segment A: CE=Medical, valid_from=Jan 1, valid_to=∞
```

After `terminate(termination_time: Apr 1)`:
```
Segment A: CE=Medical, valid_from=Jan 1, valid_to=∞       ← closed (transaction_to = now)
Segment B: CE=Medical, valid_from=Jan 1, valid_to=Apr 1   ← NEW (truncated copy)
```

Result: One segment with the same business attributes, but `valid_to` = April 1 instead of ∞.

### `terminate` — Multi-Segment Entity (Mid-Segment)

Starting timeline (two segments from a previous correction):
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1
Segment B: CE=401k,     valid_from=Mar 1,  valid_to=∞
```

After `terminate(termination_time: Apr 1)`:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1   ← UNTOUCHED
Segment B: CE=401k,     valid_from=Mar 1,  valid_to=∞       ← closed
Segment C: CE=401k,     valid_from=Mar 1,  valid_to=Apr 1   ← NEW (truncated)
```

Segments entirely before `termination_time` are untouched. Only the segment containing or
after `termination_time` is affected.

### `terminate` — Multi-Segment Entity (Removes Future Segments)

Starting timeline (current + scheduled future change):
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=May 1
Segment B: CE=401k,     valid_from=May 1,  valid_to=∞
```

After `terminate(termination_time: Mar 1)`:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=May 1   ← closed
Segment B: CE=401k,     valid_from=May 1,  valid_to=∞       ← closed
Segment C: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1   ← NEW (truncated)
```

All segments at or after `termination_time` are closed. The segment containing `termination_time`
gets a truncated replacement. Future scheduled changes are effectively removed.

### `terminate` — At Exact Segment Boundary

Starting timeline:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1
Segment B: CE=401k,     valid_from=Mar 1,  valid_to=∞
```

After `terminate(termination_time: Mar 1)`:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1   ← UNTOUCHED
Segment B: CE=401k,     valid_from=Mar 1,  valid_to=∞       ← closed (no replacement)
```

When `termination_time` exactly equals a segment's `valid_from`, that segment is closed entirely
(no truncated copy needed, since it would have zero duration). The preceding segment's `valid_to`
already equals `termination_time`, so the timeline naturally ends there.

### `cancel_termination`

Starting timeline (terminated entity):
```
Segment A: CE=Medical, valid_from=Jan 1, valid_to=Apr 1
```

After `cancel_termination`:
```
Segment A: CE=Medical, valid_from=Jan 1, valid_to=Apr 1   ← closed
Segment B: CE=Medical, valid_from=Jan 1, valid_to=∞       ← NEW (extended)
```

The last segment's `valid_to` is restored to `DEFAULT_VALID_TO`. The entity's timeline is
open-ended again.

---

## Edge Cases

### Termination Boundaries

| Scenario | Expected Outcome |
|----------|-----------------|
| `termination_time == first segment's valid_from` | `ArgumentError` — can't terminate before the entity existed; use `destroy` instead |
| `termination_time < first segment's valid_from` | `ArgumentError` — same reason |
| `termination_time > last segment's valid_to` | `ArgumentError` — termination point is beyond the timeline |
| `termination_time == last segment's valid_to` | No-op — already terminated at this time (or already open-ended at ∞) |

### Re-Termination

| Scenario | Expected Outcome |
|----------|-----------------|
| Terminate at Apr 1, then terminate at Mar 1 | Second terminate succeeds: timeline truncated to Mar 1 |
| Terminate at Mar 1, then terminate at Apr 1 | Second terminate succeeds: timeline extended to Apr 1 |
| Terminate, cancel_termination, terminate again | All succeed (round-trip) |

Re-termination at a different date is a valid operation. The entity's timeline adjusts to the new
termination point. Old segments are closed in transaction time (audit trail preserved).

### Entity State

| Scenario | Expected Outcome |
|----------|-----------------|
| Entity has no current-knowledge records (fully destroyed) | `RecordNotFound` |
| Entity with a single segment | Terminate truncates it |
| Entity with 10+ segments from many corrections | Only segments at/after termination are affected |
| `cancel_termination` on a non-terminated entity | No-op, returns `true` |
| `terminated?` when `self` is a historical segment, not the last one | Queries DB for actual last segment — returns correct result regardless of which segment `self` points to |

### Coalescing Interaction

After termination, `coalesce_adjacent_segments!` should still run. Example where it matters:

Starting timeline:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1
Segment B: CE=Medical,  valid_from=Mar 1,  valid_to=Jun 1
Segment C: CE=401k,     valid_from=Jun 1,  valid_to=∞
```

After `terminate(termination_time: Jun 1)`:
```
Segment A: CE=Medical,  valid_from=Jan 1,  valid_to=Mar 1   ← UNTOUCHED
Segment B: CE=Medical,  valid_from=Mar 1,  valid_to=Jun 1   ← UNTOUCHED
Segment C: CE=401k,     valid_from=Jun 1,  valid_to=∞       ← closed (no replacement)
```

After coalescing: Segments A and B have identical business attributes and are adjacent →
they merge into one segment `CE=Medical, valid_from=Jan 1, valid_to=Jun 1`.

### Self-Pointer After Termination

After `terminate`, `self` should point to:
- The currently-valid segment (if `termination_time > Time.current`)
- The last segment (if `termination_time <= Time.current`, meaning the entity is already terminated)

After `cancel_termination`, `self` should point to the currently-valid segment (or the last
segment if none is currently valid).

---

## Invariants

After any `terminate` or `cancel_termination` operation, these must hold:

1. **No overlaps** — no two golden-path segments for the same `bitemporal_id` have overlapping
   `valid_from..valid_to` ranges
2. **No gaps** — golden-path segments are contiguous (each segment's `valid_to` equals the next
   segment's `valid_from`)
3. **No redundant segments** — no two adjacent golden-path segments have identical business
   attributes (coalescing guarantee)
4. **Audit trail preserved** — closed segments remain in the database with `transaction_to = now`,
   queryable via transaction-time queries
5. **Atomic** — all changes happen in a single transaction with row locking
6. **Self-consistent** — after the operation, `self`'s attributes reflect a valid golden-path record

---

## Composition with Other Operations

### `terminate` + `correct`

| Sequence | Expected Outcome |
|----------|-----------------|
| Terminate at Apr 1, then `correct(valid_from: Feb 1, ...)` within remaining range | Works — correction applies within `[Feb 1, Apr 1)` |
| Terminate at Apr 1, then `correct(valid_from: May 1, ...)` beyond termination | `RecordNotFound` — no segment exists at May 1 |
| `correct(...)` then `terminate` | Both succeed — termination truncates regardless of prior corrections |

### `terminate` + `shift_genesis`

| Sequence | Expected Outcome |
|----------|-----------------|
| Terminate at Apr 1, then `shift_genesis(new_valid_from: Feb 1)` (backward) | Works — genesis moves earlier, termination unchanged |
| Terminate at Apr 1, then `shift_genesis(new_valid_from: May 1)` (forward, past termination) | `ArgumentError` from `shift_genesis` — would erase all segments |
| `shift_genesis(...)` then `terminate` | Both succeed independently |

### `terminate` + `cancel_termination` + `correct`

Full round-trip: terminate an entity, cancel the termination, then correct it. Each operation
works independently. The entity's timeline returns to its pre-termination state after
cancellation (minus any coalescing that occurred).

---

## Test Cases

### Category 1: Basic Termination

1. **Single segment, mid-segment** — terminate creates a truncated copy
2. **Multi-segment, mid-segment** — only the spanning segment is truncated; earlier ones untouched
3. **Multi-segment, removes future segments** — segments entirely after termination are closed
4. **At exact segment boundary** — segment starting at boundary is closed, no truncated copy
5. **Three segments, terminate in second** — first untouched, second truncated, third closed

### Category 2: Guards and Errors

6. **No current-knowledge records** — raises `RecordNotFound`
7. **termination_time <= first valid_from** — raises `ArgumentError`
8. **termination_time > last valid_to** — raises `ArgumentError`
9. **Already terminated at same time** — no-op, returns `true`

### Category 3: Re-Termination

10. **Re-terminate earlier** — timeline shrinks to new termination point
11. **Re-terminate later** — timeline extends to new termination point (but still terminated)
12. **Re-terminate at same point** — no-op

### Category 4: Cancel Termination

13. **Cancel basic termination** — last segment extended to `DEFAULT_VALID_TO`
14. **Cancel on non-terminated entity** — no-op, returns `true`
15. **Terminate → cancel → terminate again** — full round-trip succeeds

### Category 5: Audit Trail

16. **After termination, old segments remain with `transaction_to = now`**
17. **After cancel, the terminated segment has `transaction_to = now`**

### Category 6: Coalescing

18. **Termination removes a segment that was the only difference between two adjacent segments** —
    remaining segments get coalesced
19. **Termination at boundary where preceding and following segments have same attrs** —
    coalescing merges the result

### Category 7: Composition

20. **Correct within range after termination** — works
21. **Correct beyond termination** — raises `RecordNotFound`
22. **Terminate after correction** — termination respects correction segments
23. **shift_genesis backward after termination** — works
24. **shift_genesis forward past termination** — raises `ArgumentError`

### Category 8: Self-Update

25. **self attributes match the currently-valid segment after termination**
26. **self attributes match the currently-valid segment after cancel_termination**
27. **When termination_time is in the past, self points to the last (terminated) segment**

### Category 9: Concurrency

28. **Two threads terminate same entity simultaneously** — serialized by row locking, both succeed

### Category 10: `terminated?` Predicate

29. **Non-terminated entity** — returns `false`
30. **After termination** — returns `true`
31. **After cancel_termination** — returns `false`
32. **When self is not the last segment** — still returns correct result (queries DB)

---

## Gem Location

Fork: `marcus-deans/activerecord-bitemporal`
Main file: `lib/activerecord-bitemporal/bitemporal.rb`

**Public methods** go in the `PersistenceOptionable` module (alongside `correct`, `shift_genesis`,
`correcting?`).

**Specs** go in a new file: `spec/activerecord-bitemporal/terminate_spec.rb`
(following the structure of `shift_genesis_spec.rb`).

All existing specs (`cascade_correction_spec.rb`, `shift_genesis_spec.rb`, etc.) must continue
to pass. Termination should be transparent to operations that don't interact with the timeline's
right edge.
