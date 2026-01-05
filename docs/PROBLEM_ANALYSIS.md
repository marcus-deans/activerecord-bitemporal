# Bitemporal Retroactive Corrections: Theoretical Analysis

## Executive Summary

This document analyzes the theoretical behavior of retroactive corrections in bitemporal data systems, focusing on a specific scenario involving cascading timeline updates. We distinguish between the theoretically correct approach and current implementation limitations in activerecord-bitemporal.

## Core Scenario: Cascading Retroactive Correction

### Initial State (October 1, 2024)

A record is created with value A, declared valid from January 1, 2024:

```
Record 1: value=A, VT[1/1/2024, ∞), TT[10/1/2024, ∞)
```

### Change 1 (October 4, 2024)

Declare that the value changed from A to B on March 1, 2024:

```
Record 1: value=A, VT[1/1/2024, ∞), TT[10/1/2024, 10/4/2024]     -- closed
Record 2: value=A, VT[1/1/2024, 3/1/2024), TT[10/4/2024, ∞)      -- historical
Record 3: value=B, VT[3/1/2024, ∞), TT[10/4/2024, ∞)             -- current
```

### Change 2 (October 6, 2024): The Retroactive Correction

Declare that the value ACTUALLY changed from A to C on February 1, 2024.

**Critical Question**: What happens to the March 1 change to B?

## Two Theoretical Interpretations

### Interpretation A: Complete Timeline Replacement

"Everything we knew from February 1 onward was wrong"

- The March 1 change to B is invalidated
- Results in: A until Feb 1, then C from Feb 1 to infinity

### Interpretation B: Cascade Correction (THEORETICALLY CORRECT)

"The value was C (not A) starting Feb 1, but the March 1 change still occurred"

- The March 1 change is preserved but now represents B changing from C (not from A)
- Results in: A until Feb 1, C from Feb 1 to Mar 1, B from Mar 1 onward

## Correct Bitemporal Representation (Cascade Correction)

After Change 2 with cascade correction:

```
# Historical records (immutable transaction time)
Record 1: value=A, VT[1/1/2024, ∞), TT[10/1/2024, 10/4/2024]        -- original
Record 2: value=A, VT[1/1/2024, 3/1/2024), TT[10/4/2024, 10/6/2024]  -- closed
Record 3: value=B, VT[3/1/2024, ∞), TT[10/4/2024, 10/6/2024]         -- closed

# New current timeline (cascade-corrected)
Record 4: value=A, VT[1/1/2024, 2/1/2024), TT[10/6/2024, ∞)          -- before Feb
Record 5: value=C, VT[2/1/2024, 3/1/2024), TT[10/6/2024, ∞)          -- CORRECTED
Record 6: value=B, VT[3/1/2024, ∞), TT[10/6/2024, ∞)                 -- PRESERVED
```

## Theoretical Ideal vs Implementation Reality

### What SQL:2011 Actually Provides

**UPDATE FOR PORTION OF** is a **single-record operation**, not a cascade mechanism:

```sql
UPDATE Emp FOR PORTION OF EPeriod
  FROM DATE '2024-02-01' TO DATE '2024-03-01'
  SET EDept = 4
-- This splits ONE record into three parts:
-- Before (preserved), Updated portion, After (preserved)
```

SQL:2011 does NOT provide automatic cascade correction for retroactive updates affecting multiple existing records.

### What pg_bitemporal Provides

The PostgreSQL extension distinguishes between:

- **`ll_bitemporal_update`**: Temporal change (fact changed at a point)
- **`ll_bitemporal_correction`**: Data correction (we recorded it wrong)

Both are **local operations** on individual records - neither provides automatic cascade logic.

### The Gap: Theory vs Practice

The **cascade correction** described in our scenario is a theoretical ideal that must be implemented as **application-level logic** using available primitives:

| Level             | What It Provides                                  | What It Lacks         |
| ----------------- | ------------------------------------------------- | --------------------- |
| SQL:2011          | FOR PORTION OF (single record splits)             | Cascade logic         |
| pg_bitemporal     | Local corrections and updates                     | Automatic cascade     |
| Theoretical Ideal | Full cascade correction preserving future changes | Direct implementation |

### Critical Algorithm for Cascade Correction (Theoretical)

```
1. BEGIN TRANSACTION
2. IDENTIFY all affected records (any overlapping with correction period)
3. CLOSE transaction times for ALL affected records atomically
4. BUILD new complete timeline:
   - Split periods as needed
   - Apply correction to affected portion
   - Preserve future changes (cascade)
5. INSERT all new records with current transaction_from
6. VALIDATE no overlapping valid times at current transaction time
7. COMMIT TRANSACTION
```

**Key Insight**: Steps 3-5 must happen atomically BEFORE validation.

## Types of Temporal Operations

1. **Temporal Change**: Fact changes at a point in time (splits timeline)
2. **Data Correction**: Fix wrong value, same validity period (force_update)
3. **Backdated Change**: Late-arriving info about a past change
4. **Retroactive Correction**: Complex correction affecting multiple periods with CASCADE

## Query Semantics After Cascade Correction

Using our scenario after October 6:

| Query                                                 | Result | Explanation                           |
| ----------------------------------------------------- | ------ | ------------------------------------- |
| "What is the current value?"                          | B      | Current valid record                  |
| "What was the value on Feb 15, 2024?"                 | C      | After correction, before March change |
| "What was the value on Mar 15, 2024?"                 | B      | March change preserved                |
| "What did we think on Oct 5 was the value on Feb 15?" | A      | Historical knowledge                  |
| "What did we think on Oct 5 was the value on Mar 15?" | B      | March change was known                |

## activerecord-bitemporal: Specific Limitations

### The Fundamental Flaw

The gem's core issue is **validation timing** in the `bitemporal_build_update_records` method:

```ruby
# WRONG: What activerecord-bitemporal does
1. Find affected records
2. Build new timeline
3. Validate for overlaps (sees both old and new as current!)
4. Close old records
5. Insert new records

# CORRECT: What it should do
1. Find affected records
2. Close old records FIRST
3. Build and insert new timeline
4. Then validate for overlaps
```

### Specific Failures in Our Scenario

For our example with changes at March 1 then February 1:

1. **Simple Updates Work**: The March 1 update succeeds (single timeline split)
2. **Retroactive Fails**: The February 1 correction fails with "Bitemporal has already been taken"
3. **Why**: The gem sees both the old March record and new February record as current during validation

### Other Limitations

1. **No Cascade Logic**: Even if validation worked, the gem doesn't implement timeline cascade
2. **force_update Confusion**: `force_update` ignores `valid_at` context (line 463 in bitemporal.rb)
3. **No Complex Timeline Operations**: Can't handle updates that affect multiple existing periods

### The Architectural Problem

This isn't a simple bug - it's a fundamental architectural limitation:

- The gem validates at the wrong point in the transaction lifecycle
- It lacks the concept of cascade correction entirely
- It conflates different temporal operation semantics

The gem essentially provides only:

- Basic temporal updates (that split single records)
- Simple corrections (that don't cascade)
- Both fail when multiple periods are involved

## Theoretical Correctness Principles

1. **Transaction Time Immutability**: Never modify past transaction times, only close them
2. **Atomic Timeline Reconstruction**: Close ALL affected records before inserting new ones
3. **Cascade Preservation**: Future temporal changes remain valid from new baseline
4. **Complete History**: Every state transition is preserved in transaction time

## Implementation Comparison: Our Scenario

### How Different Systems Handle Our February 1 Correction

| System                       | What Happens                                                                             | Result                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------ |
| **Theoretical Ideal**        | Cascade correction: Close all affected records, rebuild timeline preserving March change | A→C (Feb 1), C→B (Mar 1) ✓                       |
| **SQL:2011 FOR PORTION OF**  | Would only work on single record if one existed from Jan-Dec                             | Cannot handle our multi-record scenario          |
| **pg_bitemporal correction** | Would correct the Jan-Mar record locally                                                 | Would need manual cascade logic for March record |
| **activerecord-bitemporal**  | Validation fails with "already been taken"                                               | Cannot perform operation ✗                       |

### Building Cascade Correction

To implement proper cascade correction, you need:

```ruby
# Pseudocode for application-level cascade correction
def cascade_correction(entity_id, correction_date, new_value)
  transaction do
    # 1. Find ALL affected records (not just the one at correction_date)
    affected = find_all_records_from(entity_id, correction_date)

    # 2. Close ALL their transaction times atomically
    affected.each { |r| r.close_transaction_time! }

    # 3. Rebuild ENTIRE timeline from correction point
    timeline = []
    timeline << build_corrected_period(correction_date, new_value)
    timeline += cascade_future_changes(affected, correction_date)

    # 4. Insert all new records
    timeline.each(&:save!)

    # 5. Validate only AFTER all updates
    validate_no_overlaps!(entity_id)
  end
end
```

## Conclusion

### The Reality

1. **Cascade correction is theoretically correct** but not provided by standard implementations
2. **SQL:2011 provides primitives** (FOR PORTION OF) but not cascade logic
3. **pg_bitemporal provides semantic clarity** (update vs correction) but still local operations
4. **activerecord-bitemporal fails fundamentally** due to wrong validation timing

### The Takeaway

**Proper bitemporal cascade correction requires application-level implementation** using available primitives. No current system provides it out-of-the-box. The theoretical model described in bitemporal theory papers represents an ideal that must be consciously implemented, not an automatic feature of temporal databases.

The activerecord-bitemporal gem's limitations go beyond missing cascade logic - it fails at even simpler retroactive operations due to fundamental architectural flaws in its validation approach.
