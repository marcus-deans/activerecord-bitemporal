# Fork Changelog

What this fork of [kufu/activerecord-bitemporal](https://github.com/kufu/activerecord-bitemporal) adds to and changes in the gem, by area. Numbers link the fork's pull requests. Upstream's own changes are in the root [CHANGELOG.md](../CHANGELOG.md). For how the operations work, see [ARCHITECTURE.md](./ARCHITECTURE.md); for how to use them, [README.md](./README.md).

## Operations

- `correct(valid_from:, valid_to: nil, **attributes)` fixes a past value and keeps the changes after it ([#1](https://github.com/marcus-deans/activerecord-bitemporal/pull/1)). Without `valid_to`, it runs to the end of the segment containing `valid_from`.
  - It closes only the rows of the segments it overlaps; later segments keep their rows ([#3](https://github.com/marcus-deans/activerecord-bitemporal/pull/3)).
  - A bounded correction is a patch, like SQL:2011's `UPDATE ... FOR PORTION OF`: each segment in the span keeps its own values for the attributes not given, gaps stay gaps, and segments it wouldn't change keep their rows ([#12](https://github.com/marcus-deans/activerecord-bitemporal/pull/12)).
  - A bitemporal column, or an alias of one, among the attributes raises `ArgumentError` ([#12](https://github.com/marcus-deans/activerecord-bitemporal/pull/12)).
  - A `valid_to` past the timeline's end raises `ValidDatetimeRangeError` ([#6](https://github.com/marcus-deans/activerecord-bitemporal/pull/6)).
- `shift_genesis(new_valid_from:)` moves the start of the timeline without changing any values: backward extends the first segment, forward removes and trims the segments before the new start ([#2](https://github.com/marcus-deans/activerecord-bitemporal/pull/2)).
- `terminate(termination_time:)` ends the timeline, truncating the segment that spans the end and removing those after it. `cancel_termination` restores the timeline from before the termination, and `terminated?` says whether the timeline has a finite end ([#5](https://github.com/marcus-deans/activerecord-bitemporal/pull/5)).
- `cancel_shift_genesis` restores the timeline from before a genesis shift, and `shifted_genesis?` says whether the genesis differs from the original one ([#7](https://github.com/marcus-deans/activerecord-bitemporal/pull/7)). It restores the most recent timeline at the original genesis, so it undoes one shift and never toggles between two shifted ones ([#22](https://github.com/marcus-deans/activerecord-bitemporal/pull/22)).
- `reopen` lifts a terminated timeline's end: the last segment continues to infinity, whatever was recorded since the termination ([#22](https://github.com/marcus-deans/activerecord-bitemporal/pull/22)).

## Cancels

- A cancel refuses when anything was recorded for the entity after the operation it undoes, rather than discard it: `cancel_termination` raises `RecordedSinceTerminationError` and `cancel_shift_genesis` raises `RecordedSinceGenesisShiftError`, before writing anything. Each subclasses its cancel's not-found error ([#17](https://github.com/marcus-deans/activerecord-bitemporal/pull/17)).

## The Timeline After an Operation

- Adjacent segments with equal values are merged, so a correction leaves no seam ([#4](https://github.com/marcus-deans/activerecord-bitemporal/pull/4)).
- Every operation leaves the current timeline with no seam and no zero-length row, wherever they were, and writes only the rows that change. Zero-length rows are set aside before the guards, so none is ever taken for a segment, and `terminated?` and `shifted_genesis?` ignore them too ([#19](https://github.com/marcus-deans/activerecord-bitemporal/pull/19)).

## The Record After an Operation

- `correct` and `shift_genesis` set `swapped_id_previously_was`, as the other operations did ([#6](https://github.com/marcus-deans/activerecord-bitemporal/pull/6)).
- Every operation reloads the record it was called on, through `reload`, onto the version valid at the time the record was loaded at, and discards unsaved changes as `reload` does ([#13](https://github.com/marcus-deans/activerecord-bitemporal/pull/13)).
- That reload casts the record's time to the column's type and reads the versions unscoped, and a frozen record raises `FrozenError` before any write ([#14](https://github.com/marcus-deans/activerecord-bitemporal/pull/14)).

## Times

- `correct`, `shift_genesis` and `terminate` take their times as the valid-time column stores them: read in `Time.zone`, then cut to the column's type and precision. A `correct` span that is empty once cast raises `ArgumentError` ([#15](https://github.com/marcus-deans/activerecord-bitemporal/pull/15)).

## Locking and Concurrency

- Every operation takes an advisory lock on the entity, keyed on its table name and `bitemporal_id`, then row-locks every current-knowledge row, and reads the time only once it holds both. The advisory lock's key is public, so callers can hold the same lock ([#11](https://github.com/marcus-deans/activerecord-bitemporal/pull/11)).
- Before the row locks, an operation takes the lock upstream's `save!` takes first, on the row valid now, so it can't deadlock with a future-dated `update!` ([#16](https://github.com/marcus-deans/activerecord-bitemporal/pull/16)).
- An operation that finds a current row recorded after its own time, as a host whose clock runs ahead records one, raises `TransactionTimeSkewError` before writing ([#21](https://github.com/marcus-deans/activerecord-bitemporal/pull/21)).
- The README documents which writes the locks don't cover, and that an operation that raises releases the locks it took ([#16](https://github.com/marcus-deans/activerecord-bitemporal/pull/16), [#23](https://github.com/marcus-deans/activerecord-bitemporal/pull/23)).

## Blocks and Scopes

- Every read an operation makes, `terminated?` and `shifted_genesis?` included, starts from `unscoped`, so neither a `transaction_at`, `valid_at` or `bitemporal_at` block, a `scoping` block nor the model's `default_scope` hides a row from it ([#21](https://github.com/marcus-deans/activerecord-bitemporal/pull/21)).

## Validations and Callbacks

- Documented and pinned: the model's validations don't run on the rows an operation writes, its save and create callbacks run once per inserted row, and its commit callbacks once per operation ([#20](https://github.com/marcus-deans/activerecord-bitemporal/pull/20)).
- A callback that aborts an inserted row's save raises `RecordNotSaved` and rolls the operation back ([#23](https://github.com/marcus-deans/activerecord-bitemporal/pull/23)).

## Code Layout

- Fork code lives in `lib/activerecord-bitemporal/fork.rb` and `timeline_operations.rb`. Upstream's files are unchanged, apart from the line that requires `fork.rb`, and the operations share one skeleton, `perform_timeline_operation` ([#10](https://github.com/marcus-deans/activerecord-bitemporal/pull/10)).
- Merged upstream v7.0.2 and later ([#8](https://github.com/marcus-deans/activerecord-bitemporal/pull/8)).
- Merged upstream master as of `8837a71`, which drops Rails 7.1 ([#24](https://github.com/marcus-deans/activerecord-bitemporal/pull/24)). Upstream syncs land as merge commits, so kufu's master stays an ancestor.

## Specs and Docs

- The fork's specs follow upstream's conventions ([#18](https://github.com/marcus-deans/activerecord-bitemporal/pull/18)).
- Review repros were added ([#9](https://github.com/marcus-deans/activerecord-bitemporal/pull/9)), then moved into the operations' specs, with the concurrency gap the README describes kept as a pending example.
