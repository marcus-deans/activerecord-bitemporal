# Gem Fix: Coalesce Adjacent Identical Segments in `activerecord-bitemporal`

## The Problem

The `correct()` method in `activerecord-bitemporal` can produce timelines with adjacent segments
that have identical business attributes — a "cosmetic seam." This happens because `correct()`
only operates on segments from `valid_from` onward and never examines whether the newly created
segment is identical to the preceding one.

### Concrete Example (Cancel Future Change)

Starting timeline:

```
Segment A: Bonus,  valid_from=Feb 12, valid_to=Mar 11
Segment B: PW CF,  valid_from=Mar 11, valid_to=∞
```

Cancel calls `correct(valid_from: Mar 11, valid_to: ∞, CE: Bonus)`:

```
Segment A: Bonus,  valid_from=Feb 12, valid_to=Mar 11  ← untouched (not in affected_records)
Segment B: PW CF,  valid_from=Mar 11, valid_to=∞       ← closed (transaction_to = now)
Segment C: Bonus,  valid_from=Mar 11, valid_to=∞       ← NEW (identical to A)
```

Result: A and C have identical business attributes but are split at Mar 11. This seam causes
downstream queries (like `future_versions`) to incorrectly report C as a "scheduled change."

### Why It Happens Mechanically

In `_correct_record`:

1. `find_affected_records_for_correction(valid_from)` uses `WHERE valid_to > valid_from` — so
   Segment A (whose `valid_to` equals `valid_from`, not greater) is excluded
2. `bitemporal_build_cascade_correction_records` builds the correction segment from the
   containing record (Segment B), applies the new attributes, but has no visibility into
   Segment A
3. The new segment is inserted, the old one closed — resulting in the seam

The same issue can occur with `shift_genesis()` (e.g., a forward shift that trims a segment
to match its successor).

## Where the Fix Belongs

**In the gem**, not the app. This is a data model integrity issue — the gem should guarantee
that its timeline operations produce minimal, non-redundant timelines. The app shouldn't need
to work around cosmetic seams in every query.

## Conceptual Requirements

After any timeline-mutating operation (`correct()`, `shift_genesis()`), the gem should ensure:

> **No two adjacent segments in the current-knowledge timeline should have identical business
> attributes.** If they do, they must be merged into a single contiguous segment.

"Adjacent" means `segment_1.valid_to == segment_2.valid_from` (contiguous, no gap).

"Business attributes" means all columns **except** temporal/infrastructure columns:
`id`, `bitemporal_id`, `valid_from`, `valid_to`, `transaction_from`, `transaction_to`,
`created_at`, `updated_at`, `deleted_at`. The gem already has `valid_from_key` and
`valid_to_key` accessors for configurable column names.

"Merged" means: extend the earlier segment's `valid_to` to the later segment's `valid_to`,
then close the later segment (set its `transaction_to` to `current_time`). This preserves the
audit trail — the closed segment is still visible in transaction-time queries.

## Implementation Guidance

### Placement

The coalesce step should run inside the existing transaction in `_correct_record` (and
`_shift_genesis_record`), **after** the new timeline records are inserted and **before** the
post-hoc validation (`validate_cascade_correction_timeline!`). This mirrors how validation
already works — it loads the full current-knowledge timeline and checks invariants.

### Key Methods to Understand

| Method                                        | Location            | Purpose                                       |
| --------------------------------------------- | ------------------- | --------------------------------------------- |
| `_correct_record`                             | `bitemporal.rb:502` | Main correction logic                         |
| `_shift_genesis_record`                       | `bitemporal.rb:565` | Genesis shifting logic                        |
| `find_all_current_knowledge_segments`         | `bitemporal.rb:633` | Loads all live segments ordered by valid_from |
| `validate_cascade_correction_timeline!`       | `bitemporal.rb:714` | Post-hoc overlap check                        |
| `bitemporal_build_cascade_correction_records` | `bitemporal.rb:733` | Builds the new timeline                       |
| `update_transaction_to`                       | Used throughout     | Closes a segment                              |

### Merging Mechanics

When merging segment pair (earlier, later):

- **Earlier segment**: `update_columns(valid_to_key => later[valid_to_key])` — extend its range
- **Later segment**: `update_transaction_to(current_time)` — close it, preserving audit trail
- Must handle chains: if A=B=C are all identical, merge A+B first, then the extended A with C

### Self-Pointer Update

After coalescing, `_correct_record` step 7 updates `self` to point at the "current" record.
Currently it reads from the in-memory `new_timeline` array, but a coalesced-away record may
still be in that array. Step 7 should instead use `find_all_current_knowledge_segments` (a DB
query) to get the post-coalesce state. Note that `_shift_genesis_record` already does this
(its step 10 reads from `find_all_current_knowledge_segments`), so this is a consistency fix.

### What NOT to Do

- Don't prevent the seam from being created in the first place (in
  `bitemporal_build_cascade_correction_records`). That method doesn't have access to pre-existing
  segments outside its `affected_records` window. Coalescing post-hoc is simpler and more robust.
- Don't make coalescing optional or configurable. It should always happen — redundant segments
  are never desirable.
- Don't modify the before/correction/after segment construction logic. The existing logic is
  correct for producing valid timelines; coalescing is a separate cleanup step.

## Test Cases

### For `correct()`

1. **Identical correction** — correct a segment with the same attributes it already has →
   should coalesce into one segment (no seam)
2. **Cancel pattern** — two-segment timeline, correct the future segment with current values →
   should produce one segment spanning the full range
3. **Different attributes** — correct with genuinely different values → should NOT coalesce
   (segments are legitimately different)
4. **Bounded correction in the middle** — correct with `valid_to` set, where the correction
   matches the following segment → should coalesce the correction with the after-segment
5. **Chain coalescing** — three identical adjacent segments → should merge all into one

### For `shift_genesis()`

6. **Forward shift producing seam** — shift genesis forward past a segment boundary where the
   next segment has the same attributes → should coalesce

### Existing specs

All existing `cascade_correction_spec.rb` and `shift_genesis_spec.rb` tests must continue to
pass. The coalescing should be transparent to operations that don't produce seams.

## Gem Location

Fork: `marcus-deans/activerecord-bitemporal` (commit `d76bb5d`)
Main file: `lib/activerecord-bitemporal/bitemporal.rb`
Specs: `spec/activerecord-bitemporal/cascade_correction_spec.rb`, `shift_genesis_spec.rb`
