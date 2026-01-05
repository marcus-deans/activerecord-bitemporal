# Bitemporal Data Model: Core Concepts and Retroactive Corrections

## 1. Fundamental Principles

### 1.1 Time Dimensions

A bitemporal data model tracks two orthogonal time dimensions for every fact:

**Valid Time (Application Time)**

- Represents when a fact is true in the real world
- User-controlled and mutable through corrections
- Can represent past, present, or future periods
- Denoted as `[valid_from, valid_to)` using closed-open intervals

**Transaction Time (System Time)**

- Represents when a fact is stored in the database
- System-controlled and immutable
- Monotonically increasing, append-only
- Denoted as `[transaction_from, transaction_to)` using closed-open intervals

### 1.2 Immutability Principle

**Critical Invariant**: Transaction time is immutable. Once a record is written with a transaction time, that record can never be modified or deleted. It can only be logically superseded by closing its `transaction_to` timestamp.

This immutability enables:

- Complete audit trails
- "What we knew when" queries
- Regulatory compliance
- Forensic analysis

### 1.3 Temporal Consistency Rules

1. **No Retroactive Transaction Time**: Cannot insert records with `transaction_from` in the past
2. **Monotonic Transaction Time**: `transaction_from` must always be >= any previous transaction time
3. **Valid Time Freedom**: Valid time can be set to any period (past, present, or future)
4. **Period Continuity**: For complete history, valid periods should be contiguous without gaps
5. **Overlapping Prevention**: At any transaction time T, no two records for the same entity can have overlapping valid times

## 2. Data Model Requirements

### 2.1 Required Attributes

Every bitemporal relation requires:

```
entity_id:         Logical entity identifier
valid_from:        Start of valid time period
valid_to:          End of valid time period
transaction_from:  Start of transaction time period
transaction_to:    End of transaction time period
[attributes]:      Business data
```

### 2.2 Temporal Semantics

**Closed-Open Intervals**: Both time dimensions use `[start, end)` semantics:

- Start time is inclusive
- End time is exclusive
- Enables seamless period adjacency without gaps or overlaps

**Infinity Representation**:

- Common convention: `9999-12-31 23:59:59` represents "until changed"
- Alternative: NULL or specific infinity markers

### 2.3 Current vs Historical Records

A record is "current" when:

- `valid_from <= NOW < valid_to` (currently valid)
- `transaction_to = ∞` (latest knowledge)

A record is "historical" when either:

- `valid_to <= NOW` (no longer valid)
- `transaction_to < ∞` (superseded knowledge)

## 3. Temporal Operations - Detailed Scenarios

### 3.1 INSERT Operations

#### Basic Insert

```
Operation: INSERT Employee (id=1, salary=50000) at T0
Result:
  ID=1: salary=50000, VT[T0, ∞), TT[T0, ∞)
```

#### Future-Dated Insert

```
Operation: INSERT Employee (id=2, salary=60000, valid_from='2025-01-01') at T0
Result:
  ID=2: salary=60000, VT[2025-01-01, ∞), TT[T0, ∞)
```

#### Bounded Period Insert

```
Operation: INSERT Employee (id=3, salary=55000, valid='2024-Q1') at T0
Result:
  ID=3: salary=55000, VT[2024-01-01, 2024-04-01), TT[T0, ∞)
```

### 3.2 UPDATE - Temporal Change

A temporal change represents a fact changing in the real world.

#### Complete Example: Simple Update

```
Initial: ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)
Operation: UPDATE salary=60000 WHERE id=1 at T1 (current time: 2024-03-15)

Step 1: Close original
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]

Step 2: Insert history + new state
  ID=2: salary=50000, VT[2024-01-01, 2024-03-15), TT[T1, ∞)
  ID=3: salary=60000, VT[2024-03-15, ∞), TT[T1, ∞)
```

#### Complex Example: Update Within Bounded Period

```
Initial: ID=1: salary=50000, VT[2024-01-01, 2024-12-31), TT[T0, ∞)
Operation: UPDATE salary=60000 FOR PORTION FROM 2024-03-01 TO 2024-06-01

Result after operation at T1:
  ID=1: salary=50000, VT[2024-01-01, 2024-12-31), TT[T0, T1]  -- closed
  ID=2: salary=50000, VT[2024-01-01, 2024-03-01), TT[T1, ∞)   -- before
  ID=3: salary=60000, VT[2024-03-01, 2024-06-01), TT[T1, ∞)   -- updated
  ID=4: salary=50000, VT[2024-06-01, 2024-12-31), TT[T1, ∞)   -- after
```

### 3.3 UPDATE - Data Correction

A correction fixes wrong data without changing when facts were true.

#### Example: Correcting a Value

```
Current state: ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)
Realization: Salary was actually 52000, not 50000
Operation: CORRECT salary=52000 WHERE id=1 at T1

Result:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]   -- what we thought
  ID=2: salary=52000, VT[2024-01-01, ∞), TT[T1, ∞)    -- corrected truth
```

### 3.4 DELETE Operations

#### Logical Delete

```
Initial: ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)
Operation: DELETE WHERE id=1 at T1 (current time: 2024-03-15)

Result:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]           -- closed
  ID=2: salary=50000, VT[2024-01-01, 2024-03-15), TT[T1, ∞)   -- final state
```

#### Delete with Future Effect

```
Initial: ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)
Operation: DELETE WHERE id=1 EFFECTIVE 2024-06-01 at T1

Result:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]           -- closed
  ID=2: salary=50000, VT[2024-01-01, 2024-06-01), TT[T1, ∞)   -- valid until June
```

## 4. SQL:2011 Standard Operations

### 4.1 UPDATE FOR PORTION OF

The SQL:2011 standard introduces `UPDATE FOR PORTION OF` for temporal updates, but it's important to understand its actual scope:

```sql
-- Initial record: ENo=22217, EDept=3, Valid[2010-01-01, 2011-11-12)
UPDATE Emp FOR PORTION OF EPeriod
  FROM DATE '2011-02-03' TO DATE '2011-09-10'
  SET EDept = 4
  WHERE ENo = 22217

-- Result: THREE records (single record split):
-- Record 1: EDept=3, Valid[2010-01-01, 2011-02-03)  -- preserved before
-- Record 2: EDept=4, Valid[2011-02-03, 2011-09-10)  -- updated portion
-- Record 3: EDept=3, Valid[2011-09-10, 2011-11-12)  -- preserved after
```

**Key Points**:

- Operates on a **single record** at a time
- **Splits** the record at the period boundaries
- **Preserves** values outside the update period
- Does **NOT** cascade to other records
- This is a **local operation**, not a timeline reconstruction

### 4.2 DELETE FOR PORTION OF

Similar to UPDATE, this operates on single records:

```sql
DELETE Emp FOR PORTION OF EPeriod
  FROM DATE '2011-02-03' TO DATE '2011-09-10'
  WHERE ENo = 22217
```

Creates gaps in the timeline by removing specific portions while preserving the rest.

### 4.3 System-Versioned Tables

SQL:2011 provides automatic transaction time management through system versioning, but updates remain local operations without cascade logic.

## 5. Retroactive Corrections: Theoretical Ideal vs Reality

### 5.1 Problem Statement

Retroactive corrections involve changing our knowledge about the past. For example:

- "We recorded salary as $50k from Jan 1, but it was actually $55k"
- "The rate change we recorded for Mar 1 actually happened Feb 15"

### 5.2 The Theoretical Ideal

The theoretically correct behavior for retroactive corrections involves **cascade correction** - preserving future changes while updating the baseline from which they occurred. This is described in section 5.4 below.

### 5.3 Why Implementations Often Fall Short

Standard implementations (including SQL:2011) don't provide automatic cascade correction because:

1. SQL:2011 FOR PORTION OF is a single-record operation
2. Cascade logic requires application-level coordination
3. Most systems provide primitives but not complete cascade algorithms

### 5.4 Correct Algorithm for Retroactive Cascade Corrections

**Critical Insight**: All affected records must have their transaction times closed BEFORE creating new records. This algorithm represents the theoretical ideal, which must be implemented at the application level.

```
ALGORITHM: Retroactive Cascade Correction (Theoretical)
INPUT: entity_id, correction_time, new_attributes

1. BEGIN TRANSACTION

2. IDENTIFY affected records:
   SELECT * FROM table
   WHERE entity_id = :entity_id
     AND valid_from <= :correction_end
     AND valid_to > :correction_start
     AND transaction_to = ∞

3. CLOSE transaction times:
   UPDATE table
   SET transaction_to = NOW
   WHERE record_id IN (affected_records)

4. BUILD new timeline (CASCADE LOGIC):
   FOR each affected period:
     IF period overlaps correction:
       Split and apply correction
     ELSE:
       Preserve existing values with cascade

5. INSERT new records:
   All with transaction_from = NOW, transaction_to = ∞

6. VALIDATE consistency:
   Assert no valid_time overlaps at current transaction_time

7. COMMIT TRANSACTION
```

**Note**: This cascade correction is NOT provided by SQL:2011 or most implementations. It represents the theoretically correct behavior that must be built using available primitives.

### 5.5 Cascading Corrections - Complete Example (Theoretical)

#### Scenario: Complex Timeline with Multiple Corrections

**Initial State at T0:**

```
ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)
```

**Update 1 at T1 (2024-02-01): Salary increases to 60000 effective March 1**

```
Operation: UPDATE salary=60000 EFFECTIVE 2024-03-01

After T1:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]          -- closed
  ID=2: salary=50000, VT[2024-01-01, 2024-03-01), TT[T1, ∞)  -- before
  ID=3: salary=60000, VT[2024-03-01, ∞), TT[T1, ∞)           -- after
```

**Update 2 at T2 (2024-03-15): Salary increases to 70000 effective May 1**

```
Operation: UPDATE salary=70000 EFFECTIVE 2024-05-01

After T2:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]          -- historical
  ID=2: salary=50000, VT[2024-01-01, 2024-03-01), TT[T1, T2] -- closed
  ID=3: salary=60000, VT[2024-03-01, ∞), TT[T1, T2]          -- closed
  ID=4: salary=50000, VT[2024-01-01, 2024-03-01), TT[T2, ∞)  -- current knowledge
  ID=5: salary=60000, VT[2024-03-01, 2024-05-01), TT[T2, ∞)  -- current knowledge
  ID=6: salary=70000, VT[2024-05-01, ∞), TT[T2, ∞)           -- current knowledge
```

**Retroactive Correction at T3: Salary was actually 55000 from Feb 1**

```
Operation: RETROACTIVE UPDATE salary=55000 EFFECTIVE 2024-02-01

Critical: Must close ALL affected records (ID=4, ID=5, ID=6) BEFORE inserting new timeline

After T3:
  ID=1-3: [unchanged, already closed]
  ID=4: salary=50000, VT[2024-01-01, 2024-03-01), TT[T2, T3] -- closed
  ID=5: salary=60000, VT[2024-03-01, 2024-05-01), TT[T2, T3] -- closed
  ID=6: salary=70000, VT[2024-05-01, ∞), TT[T2, T3]          -- closed
  ID=7: salary=50000, VT[2024-01-01, 2024-02-01), TT[T3, ∞)  -- new timeline
  ID=8: salary=55000, VT[2024-02-01, 2024-03-01), TT[T3, ∞)  -- corrected period
  ID=9: salary=60000, VT[2024-03-01, 2024-05-01), TT[T3, ∞)  -- preserved
  ID=10: salary=70000, VT[2024-05-01, ∞), TT[T3, ∞)          -- preserved
```

### 5.6 Why Order Matters - Validation Timing

**Incorrect Implementation (fails):**

```python
def retroactive_update(entity_id, valid_at, new_value):
    # 1. Find affected records
    affected = find_current_records(entity_id, valid_at)

    # 2. Build new timeline
    new_records = build_timeline(affected, valid_at, new_value)

    # 3. Validate (WRONG TIMING!)
    if overlaps_exist(new_records):
        raise ValidationError("Overlapping periods")

    # 4. Close old records
    close_transaction_times(affected)

    # 5. Insert new records
    insert_all(new_records)
```

**Correct Implementation:**

```python
def retroactive_update(entity_id, valid_at, new_value):
    # 1. Find affected records
    affected = find_current_records(entity_id, valid_at)

    # 2. FIRST: Close all transaction times
    close_transaction_times(affected)  # Critical: Do this FIRST

    # 3. Build and insert new timeline
    new_records = build_timeline(affected, valid_at, new_value)
    insert_all(new_records)

    # 4. THEN: Validate
    if overlaps_exist_at_current_time(entity_id):
        rollback()
        raise ValidationError("Overlapping periods")

    commit()
```

## 6. Robust Implementation Patterns

### 6.1 pg_bitemporal: PostgreSQL Extension

The pg_bitemporal extension provides sophisticated bitemporal operations with clear semantics:

#### Bitemporal Update vs Correction

**`ll_bitemporal_update`**: Represents a temporal change

- The fact changed at a specific point in time
- May split effective periods to show when changes occurred
- Example: "Starting March 1, the rate increased to $60"

**`ll_bitemporal_correction`**: Represents a data correction

- We recorded it wrong; here's what it should have been
- Maintains the same effective period while updating values
- Example: "The rate was always $55, not $50 as we recorded"

Both operations:

- Preserve transaction time immutability
- Close existing assertion periods
- Insert new records (never mutate)
- Work on individual records or sets (no automatic cascade)

#### Example: pg_bitemporal Correction

```sql
-- Before: value=50, Effective[Jan-1, Dec-31], Asserted[Oct-1, ∞]
SELECT * FROM bitemporal_internal.ll_bitemporal_correction(
  'table', 'value', '55', 'id', '1',
  temporal_relationships.timeperiod('2024-01-01...2024-12-31'),
  now()
);
-- After:
-- Record 1: value=50, Effective[Jan-1, Dec-31], Asserted[Oct-1, Oct-15] -- closed
-- Record 2: value=55, Effective[Jan-1, Dec-31], Asserted[Oct-15, ∞]    -- new
```

### 6.2 XTDB: Immutable Transaction Log

XTDB (formerly Crux) implements bitemporal data through an immutable transaction log architecture:

- Every transaction is an immutable event
- Valid time and transaction time are first-class concepts
- Supports complex temporal queries natively
- Provides automatic indexing for temporal predicates

### 6.3 Important Limitation: Cascade Logic

**Critical Point**: Neither pg_bitemporal, XTDB, nor SQL:2011 provide automatic cascade correction for retroactive updates affecting multiple future records. This must be implemented as application logic using the provided primitives.

## 7. Temporal Constraints

### 7.1 Entity Uniqueness

**Constraint**: For any entity_id and transaction_time, valid periods must not overlap.

```sql
-- SQL:2011 syntax
UNIQUE (entity_id, valid_period WITHOUT OVERLAPS)
```

**Validation Timing**: Must be checked AFTER transaction time updates, not during.

### 7.2 Referential Integrity

Child valid periods must be contained within parent valid periods:

```sql
FOREIGN KEY (parent_id, PERIOD valid_period)
REFERENCES parent (id, PERIOD valid_period)
```

The child's valid period must be covered by the union of parent periods.

## 8. Temporal Predicates

### 8.1 Allen's Interval Relations

Bitemporal systems require period comparison predicates:

```sql
-- OVERLAPS: Periods have any time in common
P1 OVERLAPS P2 ≡ P1.start < P2.end AND P2.start < P1.end

-- CONTAINS: P1 fully contains P2
P1 CONTAINS P2 ≡ P1.start <= P2.start AND P2.end <= P1.end

-- EQUALS: Periods are identical
P1 EQUALS P2 ≡ P1.start = P2.start AND P1.end = P2.end

-- PRECEDES: P1 ends before P2 starts (with optional gap)
P1 PRECEDES P2 ≡ P1.end <= P2.start

-- MEETS: P1 ends exactly when P2 starts
P1 MEETS P2 ≡ P1.end = P2.start
```

### 8.2 Temporal Coalescing

Merge adjacent or overlapping periods with same attributes:

```sql
-- Before coalescing:
ID=1: salary=50000, VT[2024-01-01, 2024-03-01)
ID=2: salary=50000, VT[2024-03-01, 2024-06-01)
ID=3: salary=50000, VT[2024-06-01, 2024-09-01)

-- After coalescing:
ID=1: salary=50000, VT[2024-01-01, 2024-09-01)
```

## 9. Query Patterns - Comprehensive

### 9.1 Current State Queries

```sql
-- Simple current state
SELECT * FROM Employee
WHERE valid_from <= NOW() AND valid_to > NOW()
  AND transaction_to = '9999-12-31';

-- Current state with joins
SELECT e.*, d.name as dept_name
FROM Employee e
JOIN Department d ON e.dept_id = d.id
WHERE e.valid_from <= NOW() AND e.valid_to > NOW()
  AND e.transaction_to = '9999-12-31'
  AND d.valid_from <= NOW() AND d.valid_to > NOW()
  AND d.transaction_to = '9999-12-31';
```

### 9.2 Historical Queries

```sql
-- State at specific time
SELECT * FROM Employee
WHERE valid_from <= '2024-01-15' AND valid_to > '2024-01-15'
  AND transaction_to = '9999-12-31';

-- History over a period
SELECT * FROM Employee
WHERE valid_from < '2024-06-01' AND valid_to > '2024-01-01'
  AND transaction_to = '9999-12-31'
ORDER BY valid_from;
```

### 9.3 Time Travel Queries

```sql
-- What we knew at T about V
SELECT * FROM Employee
WHERE valid_from <= :valid_time AND valid_to > :valid_time
  AND transaction_from <= :transaction_time
  AND transaction_to > :transaction_time;

-- Compare knowledge at different times
SELECT
  t1.salary as knew_then,
  t2.salary as know_now
FROM
  (SELECT * FROM Employee
   WHERE entity_id = :id
     AND valid_from <= :date AND valid_to > :date
     AND transaction_from <= :old_time
     AND transaction_to > :old_time) t1
FULL OUTER JOIN
  (SELECT * FROM Employee
   WHERE entity_id = :id
     AND valid_from <= :date AND valid_to > :date
     AND transaction_to = '9999-12-31') t2
ON t1.entity_id = t2.entity_id;
```

### 9.4 Audit Queries

```sql
-- Complete audit trail
SELECT
  entity_id,
  valid_from,
  valid_to,
  transaction_from,
  transaction_to,
  salary,
  CASE
    WHEN transaction_to = '9999-12-31' THEN 'Current'
    ELSE 'Historical'
  END as status
FROM Employee
WHERE entity_id = :id
ORDER BY transaction_from DESC, valid_from;

-- Changes made by time period
SELECT * FROM Employee
WHERE transaction_from >= :start_date
  AND transaction_from < :end_date
ORDER BY transaction_from;
```

### 9.5 Temporal Joins

```sql
-- Employees and their departments over time
SELECT
  e.name,
  d.name as dept_name,
  GREATEST(e.valid_from, d.valid_from) as valid_from,
  LEAST(e.valid_to, d.valid_to) as valid_to
FROM Employee e
JOIN Department d ON e.dept_id = d.entity_id
WHERE e.valid_from < d.valid_to
  AND d.valid_from < e.valid_to
  AND e.transaction_to = '9999-12-31'
  AND d.transaction_to = '9999-12-31';
```

## 10. Edge Cases and Complex Scenarios

### 10.1 Concurrent Updates

**Problem**: Two transactions updating the same entity simultaneously.

```
Transaction A at T1: UPDATE salary=60000 WHERE id=1
Transaction B at T1: UPDATE salary=65000 WHERE id=1

Incorrect Result (race condition):
  Both read same current record
  Both try to close and insert
  Constraint violation or data corruption

Correct Handling:
  Use SELECT FOR UPDATE or SERIALIZABLE isolation
  One transaction proceeds, other retries
```

### 10.2 Gap Handling

**Scenario**: Updates creating temporal gaps

```
Initial: ID=1: salary=50000, VT[2024-01-01, 2024-12-31)
Operation: UPDATE salary=60000 FOR PORTION FROM 2024-03-01 TO 2024-06-01

Result:
  ID=1: salary=50000, VT[2024-01-01, 2024-03-01)
  ID=2: salary=60000, VT[2024-03-01, 2024-06-01)
  ID=3: salary=50000, VT[2024-06-01, 2024-12-31)

Query at 2024-04-01: Returns salary=60000 ✓
Query at 2024-02-01: Returns salary=50000 ✓
```

### 10.3 Future Dating

**Scenario**: Recording future changes

```
Current time: 2024-03-15
Operation: INSERT salary=70000 EFFECTIVE 2024-07-01

Result: ID=1: salary=70000, VT[2024-07-01, ∞), TT[2024-03-15, ∞)

Queries:
  - Current state (2024-03-15): No result (not yet valid)
  - Future state (2024-07-15): Returns salary=70000
  - Audit shows: Recorded on 2024-03-15, effective 2024-07-01
```

### 10.4 Retroactive Deletions

**Scenario**: Removing a historical period

```
Current: ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, ∞)

Operation: DELETE FOR PORTION FROM 2024-02-01 TO 2024-03-01

Result:
  ID=1: salary=50000, VT[2024-01-01, ∞), TT[T0, T1]
  ID=2: salary=50000, VT[2024-01-01, 2024-02-01), TT[T1, ∞)
  ID=3: salary=50000, VT[2024-03-01, ∞), TT[T1, ∞)
  -- Gap from 2024-02-01 to 2024-03-01
```

## 11. Performance Considerations

### 11.1 Index Strategy

```sql
-- Primary temporal index
CREATE INDEX idx_bitemporal_current ON employee (
  entity_id,
  valid_from,
  valid_to
) WHERE transaction_to = '9999-12-31';

-- Historical lookup index
CREATE INDEX idx_bitemporal_history ON employee (
  entity_id,
  transaction_from,
  transaction_to,
  valid_from,
  valid_to
);

-- Audit index
CREATE INDEX idx_bitemporal_audit ON employee (
  entity_id,
  transaction_from
);
```

### 11.2 Partitioning Strategies

```sql
-- Partition by transaction_to for archival
CREATE TABLE employee_current PARTITION OF employee
  FOR VALUES IN ('9999-12-31');

CREATE TABLE employee_historical PARTITION OF employee
  FOR VALUES FROM ('1900-01-01') TO ('9999-12-31');

-- Or partition by valid_from for time-series queries
CREATE TABLE employee_2024 PARTITION OF employee
  FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

### 11.3 Query Optimization

```sql
-- Inefficient: Scanning all history
SELECT * FROM employee
WHERE entity_id = 1
  AND '2024-03-15' BETWEEN valid_from AND valid_to;

-- Efficient: Using temporal index
SELECT * FROM employee
WHERE entity_id = 1
  AND valid_from <= '2024-03-15'
  AND valid_to > '2024-03-15'
  AND transaction_to = '9999-12-31';
```

### 11.4 Storage Considerations

```
Record multiplication factor:
- Each UPDATE creates 2-3 new records
- N updates = ~2N+1 total records
- Storage growth: O(updates) not O(time)

Mitigation strategies:
- Archive old transaction times
- Compress historical partitions
- Vacuum/reorganize regularly
```

## 12. Common Implementation Pitfalls

### 12.1 Validation Before Closure

**Pitfall**: Validating constraints before closing transaction times
**Result**: False positive constraint violations
**Solution**: Always close transaction times first, then validate

### 12.2 Incomplete Timeline Updates

**Pitfall**: Only updating affected period, not entire timeline
**Result**: Inconsistent state, orphaned periods
**Solution**: Always rebuild complete timeline atomically

### 12.3 Missing Temporal Indexes

**Pitfall**: No indexes on temporal columns
**Result**: Full table scans for every temporal query
**Solution**: Create covering indexes for common query patterns

### 12.4 Ignoring Concurrent Access

**Pitfall**: No locking strategy for temporal updates
**Result**: Race conditions, data corruption
**Solution**: Use SELECT FOR UPDATE or SERIALIZABLE isolation

### 12.5 Mixing Temporal Semantics

**Pitfall**: Confusing corrections with temporal changes
**Result**: Incorrect timeline, lost history
**Solution**: Clear API separation between update types

### 12.6 Unbounded Valid Periods

**Pitfall**: Not handling infinity correctly
**Result**: Comparison failures, incorrect results
**Solution**: Use consistent infinity representation

## 13. Critical Implementation Requirements

### 13.1 Transaction Management

- All temporal operations must be atomic
- Use SERIALIZABLE isolation or temporal locks
- Prevent phantom reads during timeline reconstruction
- Implement retry logic for concurrent updates

### 13.2 Required System Capabilities

```
Minimum Requirements:
- Transaction support (ACID compliance)
- Row-level locking or MVCC
- Timestamp precision to microseconds
- Support for large timestamp values (infinity)
- Composite indexes
- Partial indexes (WHERE clause)

Recommended:
- Table partitioning
- Temporal data types (PERIOD, DATERANGE)
- Exclusion constraints
- Generated columns
```

### 13.3 API Design Principles

```ruby
# Clear operation separation
class BitemporalRecord
  # Temporal change - fact changes over time
  def update_at(valid_time, attributes)

  # Data correction - fix incorrect data
  def correct(attributes)

  # Retroactive update - complex timeline change
  def retroactive_update(valid_time, attributes)

  # Query interfaces
  def as_of(valid_time)
  def as_of_transaction(transaction_time)
  def history(from: nil, to: nil)
end
```

## 14. Distinction: Operation Types

### 14.1 Temporal Change

- **What**: Fact changes over time
- **Example**: "Salary increases on March 1"
- **Effect**: Splits valid period at change point
- **Records**: Creates before/after records
- **Use When**: Real-world state changes

### 14.2 Data Correction

- **What**: Fix incorrect data entry
- **Example**: "Salary was entered wrong, should be 52000 not 50000"
- **Effect**: Preserves valid period
- **Records**: Replaces entire record with same validity
- **Use When**: Correcting data entry errors

### 14.3 Backdated Change

- **What**: Late-arriving information about past changes
- **Example**: "Salary changed last month (recorded today)"
- **Effect**: Updates valid time in the past
- **Records**: May require cascading timeline updates
- **Use When**: Recording delayed information

### 14.4 Retroactive Correction

- **What**: Complex correction affecting multiple periods
- **Example**: "Rate was 55000 from Feb, not 50000, affecting all subsequent changes"
- **Effect**: Rebuilds entire affected timeline
- **Records**: Closes all affected, inserts complete new timeline
- **Use When**: Correcting cascading historical errors

## 15. Implementation Checklist

### Required Features

- [ ] Immutable transaction time
- [ ] Closed-open interval semantics
- [ ] Atomic timeline updates
- [ ] Temporal uniqueness constraints
- [ ] Period comparison predicates
- [ ] Current state queries (default)
- [ ] Historical state queries
- [ ] Time travel queries
- [ ] Audit trail queries

### Advanced Features

- [ ] Temporal joins
- [ ] Period coalescing
- [ ] Temporal foreign keys
- [ ] FOR PORTION OF operations
- [ ] Concurrent update handling
- [ ] Partitioning strategy
- [ ] Archival process

### Validation Rules

- [ ] No overlapping valid periods at same transaction time
- [ ] Transaction time always moves forward
- [ ] Valid periods use consistent infinity
- [ ] Child periods contained in parent periods
- [ ] Complete timeline without unintended gaps

## 16. References

1. **SQL:2011 Standard** (ISO/IEC 9075-2:2011)
   - Defines APPLICATION TIME and SYSTEM TIME
   - Specifies FOR PORTION OF semantics
   - WITHOUT OVERLAPS constraint

2. **Fowler, M.** "Temporal Patterns" (2005)
   - Distinction between actual time and record time
   - "What we knew when" principle

3. **XTDB** Documentation
   - Universal bitemporal model
   - Immutable transaction log architecture

4. **Kulkarni & Michels** "Temporal Features in SQL:2011" (2012)
   - FOR PORTION OF implementation
   - System-versioned tables

5. **PostgreSQL Temporal** (pg_bitemporal)
   - Practical implementation patterns
   - GIST exclusion constraints

## 17. Summary

### Core Principles

A correct bitemporal implementation requires:

1. **Immutable transaction time** - Never modify, only close and supersede
2. **Atomic timeline updates** - Close all affected records before inserting new ones
3. **Proper validation timing** - Validate after updates, not before
4. **Clear operation semantics** - Distinguish corrections from temporal changes
5. **Complete cascade handling** - Update entire affected timeline atomically

### The Critical Insight

For retroactive corrections to work properly, temporal validation must occur AFTER closing transaction times, not before. This sequencing is essential because:

1. Old records must be marked as superseded (transaction_to = NOW)
2. New timeline must be inserted with current transaction time
3. Only then can uniqueness constraints be properly evaluated

### Key Implementation Patterns

```
Correct Retroactive Update:
1. BEGIN TRANSACTION
2. Lock affected entity
3. Find all affected current records
4. Close transaction times (SET transaction_to = NOW)
5. Build complete new timeline
6. Insert new records (transaction_from = NOW)
7. Validate temporal constraints
8. COMMIT or ROLLBACK
```

### Design Guidelines

- **Immutability**: Transaction time provides an immutable audit log
- **Completeness**: Every operation preserves complete history
- **Consistency**: No overlapping valid periods at any transaction time
- **Atomicity**: Timeline updates must be all-or-nothing
- **Performance**: Design indexes for common query patterns
- **Clarity**: Separate APIs for different operation types

The bitemporal model provides powerful capabilities for temporal data management, but requires careful attention to operation sequencing, constraint validation, and transaction management to ensure correctness.
