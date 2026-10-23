# Fork Hardening Plan

Working plan for fixing what the 2026-10-23 review of the fork's timeline operations found
(`correct`, `shift_genesis`, `terminate` and their cancels). Every fix is built and tested against
upstream v7.0.2+ (PR #8, merged into `dsptch`). Work lands as a stack of PRs into `dsptch`:
#9 (this plan) → #10 (step 1, refactor) → D1 (step 2), each based on the one before.

The previous plan in this file (coalesce adjacent identical segments) shipped in PR #4 (`3e6a8fd`).
Its invariant still stands: **no two adjacent current-knowledge segments may have identical business
attributes.** dsptch-api's `future_versions` relies on it, because a seam between identical segments
reads as a phantom scheduled change.

## Working conventions

- Cite methods, not line numbers. Every upstream merge shifts `bitemporal.rb`.
- Repros for open findings live in `spec/review_repros/*_repro.rb`. They aren't picked up by the
  normal suite. Run them with:
  `mise exec ruby@4.0.6 -- bundle exec rspec spec/review_repros --pattern '**/*_repro.rb'`
  (15 examples, 9 failing after D1). Each fix moves its repro into the matching spec
  file as a real example and deletes it from `spec/review_repros/`.
- Never run two rspec processes at once: `spec/spec_helper.rb` drops and recreates the test DB.
- One PR per step into `dsptch`. The full suite stays green at every step.

## Fork boundary (rule)

**The fork never edits upstream code or changes upstream behaviour.** Fork-added code can be
refactored freely. This keeps upstream syncs conflict-free.

- As of 2026-10-23, the fork had changed **0** upstream lines. Its 847 added lines sit in three places
  inside upstream's `bitemporal.rb` (one is a stray blank line), plus two error classes in `errors.rb`.
- Since step 1, fork code lives in two fork-owned files:
  - `lib/activerecord-bitemporal/fork.rb`, the entry point. It defines the fork's error classes at
    require time, like upstream's `errors.rb`, and registers an `on_load` hook.
  - `lib/activerecord-bitemporal/timeline_operations.rb`, loaded by that hook and included into
    `ActiveRecord::Bitemporal::Persistence`.
  - The only upstream-file footprint is `require "activerecord-bitemporal/fork"` at the end of
    `lib/activerecord-bitemporal.rb`. It must stay after upstream's `on_load` block, so the fork's
    hook runs after upstream's.
- ⚠️ **Refinements caveat:**
  - Upstream's `update_transaction_to` and its `dup` override are Ruby refinements, active only inside
    the `Persistence` module body in `bitemporal.rb`.
  - The refined `dup` resets `@_swapped_id`, `@_swapped_id_previously_was` and `@previously_force_updated`.
    Plain `dup` copies them, which silently corrupts new segments.
  - Fork code outside that file needs its own equivalents, covered by specs.
  - **On every upstream sync, diff upstream's refinements block and mirror any change into the fork's helpers.**
- Gaps in upstream behaviour are closed in dsptch-api (e.g. `lock_family!`) or offered upstream to kufu
  as a PR, never patched in the fork.

## 0. Branch migration (in progress)

Target model: `dsptch` is the product branch dsptch-api pins, and `master` mirrors kufu/master.

- [x] PR #8 (upstream v7.0.2 sync) retargeted to `dsptch`. Held; CI green on the full matrix.
- [x] dsptch-api PR into `stage`: Gemfile `branch: 'master'` → `branch: 'dsptch'`, with the lockfile
      revision unchanged at `2f0de0c`. rnwbllabs/dsptch-api#20598, merged 2026-10-23. Close the stale
      draft #14238 (same change, Aug 2026).
- [x] PR #8 merged into `dsptch` on 2026-10-23 as **merge commit** `1a5c798`.
  - **Upstream-sync PRs always use "Create a merge commit", never squash.** A squash drops kufu's
    master as an ancestor of `dsptch`. Every later sync would then merge against the stale v7.0.0
    base and conflict wherever kufu re-edits lines, and the no-force-push ruleset makes that
    unfixable. Normal fork PRs squash.
- [ ] dsptch-api PR bumping the lockfile to a newer `dsptch` revision. Decide what goes into it before
      Monday's deploy (the v7.0.2 sync alone, or the hardening stack as well).
- [ ] Production deploy (planned Mon 2026-10-26) carries the switch to dsptch-api `main`.
- [x] Rollback safety verified (2026-10-23, against GitHub, with caches wiped and `BUNDLE_DEPLOYMENT=1`):
      Bundler 2.7.2 fetches a locked revision directly by SHA and never checks it's on the named
      branch. An old release locked to `branch: master` @ `2f0de0c` therefore still builds after the
      reset, **as long as `2f0de0c` stays reachable**. Only frozen installs are safe this way; a
      `bundle update` would re-resolve `master` to the new history.
- [x] Protect `dsptch` on GitHub. Its history is what keeps `2f0de0c` fetchable, and that's a squash
      commit no PR ref holds. Applied 2026-10-23 as two repository rulesets (ids 25757048, 25757050):
  - *dsptch-integrity*: block deletion and non-fast-forward pushes. **No bypass, not even admins.**
  - *dsptch-pr-flow*: require a PR (0 approvals); admins may bypass for emergencies. Don't require
    specific status checks: CI matrix job names change when upstream changes the matrix (kufu's
    `drop-rails-7-1-support` is in flight), which would leave PRs stuck waiting on a check that
    never reports. GitHub also set `require_extra_approval_for_unattributed_changes: true` on
    this rule by default. It's undocumented in the REST docs and hasn't blocked a merge so far.
  - `master` stays unprotected until the reset; afterwards it can only move by sync.
- [ ] Graphite: trunk is set to `dsptch`, but `gt track` still reports "untracked branch dsptch", and
      Graphite has no GitHub access to this repo yet (grant it at app.graphite.com/settings). Until
      then the stack is plain git branches, with PRs opened via `gh`.
- [ ] Then: tag the old master head (`legacy-master-2f0de0c`), reset `master` to `upstream/master`, and
      make `dsptch` the GitHub default branch.

## 1. Findings

"Exposure" is how dsptch-api is affected today: it is UTC with `datetime` columns, and uses
`correct`, `terminate`, `cancel_termination` and `shift_genesis` on payroll models.

| ID  | Finding | Where | dsptch-api exposure |
| --- | ------- | ----- | ------------------- |
| F1  | Each op's `lock!` runs through the default scope, so it locks only the row valid **now**. A future-dated or past-terminated entity locks 0 rows, and concurrent writes leave overlapping current rows. Upstream `save`/`_update_row` has the same pattern. | all five `_*_record` ops | **High** on paths without the app's `lock_family!`: timecode correct/terminate, external-map correct, `Bitemporal::ShiftGenesis`, cancel_termination controllers |
| F2  | `current_time` is read *before* the lock. A writer that lands in between gets `transaction_to < transaction_from`, and "as known at T" queries return overlapping history. | all five `_*_record` ops | Same paths as F1 |
| F3  | A bounded `correct` that spans several segments copies the containing segment's untouched attributes over the whole span, and fills any gap inside it. | `bitemporal_build_cascade_correction_records` | `timecodes/correct.rb`, the only bounded caller: a span crossing a scheduled change flattens it |
| F4  | `self` is stale and dirty after every op. Only ids and time columns are copied back. A later `save` silently reverts the op. | the five "repoint self" blocks | Mitigated: the services `reload` around `correct` |
| F5  | Coalescing closes rows inserted by the same op, leaving `transaction_from == transaction_to` rows that fail the model's own validation. | `coalesce_adjacent_segments!` | Yes: invalid rows in the audit history |
| F6  | Model validations are skipped (`validate: false` on every insert); only an overlap check runs. | all inserts, `validate_cascade_correction_timeline!` | Mitigated: services call `valid?` first |
| F7  | `after_save` fires once per inserted row (3× for one `correct`), and `bitemporal_*` callbacks never fire. | `save_without_bitemporal_callbacks!` call sites | Unknown: check PaperTrail/callbacks on these models |
| F8  | With Date-typed valid time in a non-UTC zone, the inputs aren't type-cast, so ops break at segment boundaries. | `correct`, `determine_correction_end`, builders | None (UTC + datetime) |
| F9  | `cancel_shift_genesis` toggles between the last two geneses instead of undoing to the original. `shifted_genesis?` is true after a plain upstream update before genesis. | `find_pre_shift_genesis_state`, `find_original_genesis` | None (app never calls it) |
| F10 | `terminate` at a time inside a gap ends the timeline at the gap's start. Probably *correct*, since the entity doesn't exist in the gap: document it rather than fix it. | `_terminate_record` | Low |
| F11 | Calling an op inside a global `transaction_at`/`valid_at` block builds from a partial view, or raises a misleading `RecordNotFound`. | segment queries | Low |
| F12 | Dead code: `correcting?`, and the infinity branch of `determine_correction_end` (unreachable). | — | None |
| F13 | All five ops copy-paste one skeleton (timestamp, lock, fetch, guards, close, insert, coalesce, validate, repoint). This is why F1/F2/F4 each exist five times, with diverging fallbacks (`.first` vs `.last`). | — | Root cause |

## 2. Decisions needed

**D1. Lock mechanism (F1, F2).** ✅ **Decided 2026-10-23 and implemented** (step 2). Upstream's
`save`/`destroy` are off-limits (see the fork-boundary rule), so everything is inside fork code:
1. **Advisory lock.** Take a Postgres advisory transaction lock on `(table_name, bitemporal_id)`,
   built exactly like dsptch-api's `lock_family!` (`hashtext` of each). Then the app's lock and the
   gem's are the *same* lock. It's re-entrant, so the app's existing calls nest harmlessly.
2. **Row locks.** Also take `FOR UPDATE` on every current-knowledge row
   (`ignore_valid_datetime`), not just the row valid now. This keeps interlocking with upstream's
   plain `update!`/`destroy`, which row-lock the row they touch.
3. **Timestamp.** Read it *after* both locks (fixes F2).

**Remaining gap.** Suppose a plain upstream `update!`/`destroy` runs on an entity with no row valid
now, and starts *after* a fork op has begun. Upstream's own lock covers nothing in that case.
- Fix it in the app: wrap such writes in `lock_family!`.
- Optionally, propose upstream's lock scope as a fix to kufu.
- Match the app's key byte-for-byte (`bitemporal_id` is a UUID string there).

Notes from implementing it:
- dsptch-api has a **second** advisory-lock scheme. `Api::TemporalPrecondition#lock_family` keys on
  `('api:temporal_family', "#{model.name}:#{family_key}")`, deliberately apart from `lock_family!`.
  The gem matches `lock_family!`, the only key it can compute. API services that call
  `lock_family!` take both, always in the order API → family → rows.
- Waiting on the gem's lock counts against the app's `lock_timeout`. A timeout raises SQLSTATE
  55P03, which the app already renders as a 503 "write contended".
- Lock order is advisory → rows. A transaction that does a plain `update!` on an entity and then
  calls an op on it, without taking `lock_family!` first, can deadlock with another
  `lock_family!` holder. Postgres aborts one side (40P01, also a 503). Rule for the app: take
  `lock_family!` before the first write to an entity in a transaction.

**D2. Bounded correction semantics (F3).** Options:
- (a) *Patch*: each overlapping segment keeps its own attributes, and only the named ones change. Gaps are preserved, and coalescing merges identical results.
- (b) *Snapshot* (current): the span becomes one segment, the containing segment plus the given attributes.

*Recommendation:* (a). It also fixes gap-filling for `correct`. Callers that pass a full attribute set still get (b)'s flattening; `cancel_future_changes` does this on purpose and keeps working. The `cascade_correction_spec` provenance example that encodes (b) has to change. Note: `timecodes/correct.rb` passes the full correctable set from its baseline, so it only benefits once it passes just the changed attributes.

**D3. Validations (F6).** *Recommendation:* by default, validate only the segments that receive new attributes, with an opt-out. Don't validate the trimmed before/after copies of old rows: legacy data could fail validations added since.

**D4. Callback contract (F7).** First check which callbacks and PaperTrail hooks dsptch-api's bitemporal models have, and whether anything relies on per-row firing.

**D5. Where `self` points after an op (F4).** *Recommendation:* for every op, the segment covering now, otherwise the last one. Refresh *all* attributes from it and clear dirty state.

**D6. Coalescing scope (F5).** *Recommendation:* keep coalescing the whole timeline, since that's the invariant above. Rows created earlier in the same op were never visible outside the transaction, so delete them instead of closing them.

## 3. Work order (one PR each, into `dsptch`)

1. **Refactor fork code only, with no behaviour change.** Two commits:
   - **1a. Move.** Move every fork addition out of `bitemporal.rb` and `errors.rb` into
     `timeline_operations.rb`, replacing the two refinements with fork-owned helpers plus specs.
     Afterwards `git diff upstream/master -- lib/activerecord-bitemporal/{bitemporal,errors}.rb` is empty.
   - **1b. Skeleton (F13).** One private helper owns lock → timestamp → fetch → yield (the op builds
     the rows to close and insert) → close → insert → coalesce → validate → repoint `self`. Keep
     today's quirks exactly, including timestamp-before-lock and the `.first` vs `.last` fallback;
     later steps fix them in one place.
   - Bar for both: suite green and unchanged, and the repros show the same 11 failures.
   - ✅ **Done** on local branch `refactor/fork-module`: `a2f0e6c` (move), `f9718ec` (skeleton), plus a
     fix keeping the error classes defined at require time. Suite 1915 examples / 0 failures; the same
     11 repros fail; an SQL trace of every op path is identical before and after.
     - The helpers are `timeline_dup` / `timeline_close`; the skeleton is `perform_timeline_operation`.
     - `timeline_operations_spec.rb` pins today's `.first`/`.last` repoint fallback, so step 3 (D5)
       updates those examples.
2. **F1 + F2** inside the helper, per D1. Port the concurrency repros.
   - ✅ **Done** on branch `fix/d1-family-lock`.
     - `lock_timeline!` takes the advisory lock (same SQL as `lock_family!`), then `FOR UPDATE` on
       every current-knowledge row.
     - `perform_timeline_operation` reads `current_time` after both locks.
     - Specs ("locking the timeline" in `timeline_operations_spec.rb`):
       - SQL order for all five ops: advisory lock, then row locks, then the first write
       - a future-dated entity waits for an app `lock_family!` holder and builds on its commit
       - another connection's `FOR UPDATE NOWAIT` fails mid-op
       - re-entry under `lock_family!`
     - 7 of the 8 new examples fail on the pre-D1 code.
     - Suite 1923 / 0 failures. The F1 and F2 repros went green and were removed. The plain-`update!`
       race repro stays red by design (the remaining gap above).
3. **F4** per D5.
4. **F5** per D6.
5. **F3** per D2.
6. **Smaller items:** F6/F7 (D3/D4), F8 (type-cast inputs with `type_for_attribute`, as `scope_relation` does), F9, F11, F12.
7. **Docs** (section 5).

## 4. dsptch-api follow-ups

- **Now, independent of the gem:** add `lock_family!` to the unprotected paths listed under F1. It's the quickest protection for production while gem fixes land.
- D1's remaining gap: plain `update!`/`destroy` on these models, for entities that may have no row valid now, should run inside `lock_family!`.
- After step 3: the `reload` calls around `correct` become redundant (harmless to keep).
- After step 5: `timecodes/correct.rb` should pass only changed attributes.
- Optional: expose the gem's lock so `lock_family!` delegates to it, leaving one key definition. Until
  then, a change to either key silently splits the lock, and the gem's spec only pins its own copy.
- Take `lock_family!` before the first write to an entity in a transaction (see the D1 notes on lock order).
- Worth a look: `with_family_precondition` doesn't take `lock_family!` itself, so its digest check
  races with non-API writers. That's documented in the app as intentional; with the gem now on
  `lock_family!`'s key, taking it there too would also serialize API writes with gem operations.

## 5. Docs cleanup

- `docs/ARCHITECTURE.md` hasn't been updated since PR #3:
  - the bounded-correction diagram still closes and re-inserts untouched segments
  - the algorithm lacks the timeline-end guard, coalescing and repointing
  - there's no shift_genesis section
- `docs/BITEMPORAL_CONCEPTS.md` says to rebuild and close the whole timeline, which contradicts the surgical design. It also uses `correct(...)` for a force_update-style fix.
- `docs/README.md`:
  - `correct` before genesis raises `RecordNotFound`, not `ArgumentError`
  - the force_update example overstates what it replaces
  - the `destroy` semantics are wrong in two places
  - examples use `rate:` where the schema has `hourly_rate_cents`
- Undocumented: `PreTerminationStateNotFoundError`, `PreShiftGenesisStateNotFoundError`, coalescing, skipped validations, and the state of `self` after an op.
- Replace line-number references with method names everywhere.
- Root `README.md`: say it's a fork and link `docs/`. CHANGELOG: add fork entries; consider a fork version suffix (it currently reports 7.0.2, same as upstream).
- When this plan is done, delete it or move what's worth keeping into `docs/`.
