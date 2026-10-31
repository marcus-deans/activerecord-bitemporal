# Testing the Fork

This fork adds timeline operations (`correct`, `terminate`, `cancel_termination`, `reopen`, `shift_genesis`, `cancel_shift_genesis`) on top of upstream [kufu/activerecord-bitemporal](https://github.com/kufu/activerecord-bitemporal). Its specs live apart from upstream's, so either suite runs on its own and a sync with upstream never touches the fork's specs.

## Layout

| Path | What it is |
| --- | --- |
| `spec/activerecord-bitemporal/` | Upstream's specs, as upstream has them |
| `spec/fork/cascade_correction_spec.rb` | `correct` |
| `spec/fork/terminate_spec.rb` | `terminate`, `cancel_termination`, `reopen`, `terminated?` |
| `spec/fork/shift_genesis_spec.rb` | `shift_genesis`, `cancel_shift_genesis`, `shifted_genesis?` |
| `spec/fork/timeline_operations_spec.rb` | What the operations share: self after an operation, seams and zero-length rows, callbacks, time casting, the caller's blocks and scopes, locking |
| `spec/fork/upstream_sentinel_spec.rb` | Fails when upstream changes code the fork copies (see [Upstream sentinel](#upstream-sentinel)) |
| `spec/fork/property/` | The property harness: random operation sequences checked against a reference model (see [Property harness](#property-harness)) |
| `spec/spec_helper.rb`, `spec/schema.rb`, `spec/database.yml` | Upstream's, shared by both suites |

Boundary rules:

- Fork code lives in `lib/activerecord-bitemporal/fork.rb` and `lib/activerecord-bitemporal/timeline_operations.rb`; its only footprint in upstream's files is the `require` at the end of `lib/activerecord-bitemporal.rb`.
- Fork specs live under `spec/fork/`. Upstream's files, specs and spec support included, stay as upstream has them, so a sync merges without conflicts.
- A fork spec that needs its own table defines it at the top of its file with `ActiveRecord::Schema.define`, as `timeline_operations_spec.rb` and `property/operation_sequences_spec.rb` do, instead of adding it to `spec/schema.rb`.
- Fork specs follow the conventions of upstream's specs.

## Running

```sh
docker compose up -d                              # PostgreSQL on localhost:5432 (compose.yml)

bundle exec rspec                                 # everything
bundle exec rspec spec/activerecord-bitemporal    # upstream's specs only
bundle exec rspec spec/fork                       # the fork's specs only
```

The two directories split the suite: their example counts add up to the full run's. Upstream's specs run on the fork as a check that the fork's code changes nothing upstream does.

CI runs `bundle exec rspec` on Ruby 3.2 to 4.0 against each Rails in `gemfiles/`. To run one of those locally:

```sh
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec rspec
```

**One run per database.** `spec_helper.rb` drops and recreates the database named in `spec/database.yml` at the start of every run, so two runs against the same database break each other. To run several at once (the deep tier split by model, say), give each its own copy of the tree with another database name in its `spec/database.yml`, and don't commit that change.

## Property harness

The example specs pin cases someone thought of. The harness looks for the ones nobody did: it generates sequences of fork operations and upstream writes, and checks every step against a model of what should happen.

| File | What it holds |
| --- | --- |
| `property/reference_model.rb` | `ReferenceModel`: each fork operation as a pure function over the current timeline, a list of segments. Its comments state the semantics, its code pins them down. It also models upstream's `update!`, `force_update` and `destroy`, for comparison only. |
| `property/sequence_runner.rb` | `Runner`, which generates or replays a sequence and checks each step; shrinking; `Batch`, which runs a batch of sequences and writes the report |
| `property/operation_sequences_spec.rb` | The models, the tiers, the ENV knobs, and the examples |
| `property/mutants.rb` | Deliberate bugs, to check that the harness catches them (see [Mutants](#mutants)) |

### What a sequence does

A sequence runs over one or two entities of one model, each step at its own transaction time, frozen with Timecop. A step is one of:

- **A fork operation**, called on self (the record the operations are called on). Sometimes self has unsaved attribute changes first, the call runs inside a caller's block or scope (`transaction_at`, `valid_at`, `bitemporal_at`, `valid_at!` with `transaction_at!`, `scoping`, `ignore_valid_datetime`, `ignore_transaction_datetime`), or its time is passed as a `Date` or a `String`. Arguments are drawn mostly from the timeline's own boundaries, and the cancels are tried more often right after the operation they undo.
- **An upstream write**, as background traffic: `update!` on a version loaded at some time or on self, also inside `valid_at` into a gap; `destroy`; `force_update`.
- **Loading self** another way: `find_at_time`, the first or latest version, a new record, a version from a past transaction, a closed row.

The models are `Employee` (datetime valid time, `deleted_at`), `Department` (date valid time, no `deleted_at`) and `CustomColumnRecord` (valid time in `effective_from`/`effective_to`, an integer column; its table is defined in the spec). A batch can also turn on:

- **zero-length rows**: an upstream `destroy` at a segment's start may leave a zero-length row, which the fork operations must ignore and clear;
- **seams**: upstream writes lean towards leaving equal neighbours, which the fork operations must merge.

### What it checks

After a fork operation:

- the same outcome as `ReferenceModel`: the timeline it leaves, or the error it raises (the cancels' not-found errors exactly, so a refusal, which subclasses them, can't pass for one);
- raising, it writes nothing and leaves self as it was;
- a minimal write: only rows whose segment changes are closed, only new segments inserted. With nothing to write it writes nothing, not even `updated_at`, and leaves self alone;
- self left on the version `ReferenceModel.self_version` picks, with the attributes of a fresh load, no unsaved changes and its valid datetime kept;
- no zero-length current row and no equal neighbours left.

After every write, upstream's included:

- a write that raises leaves no row behind;
- rows are only inserted or closed, at now: never deleted, never otherwise changed, never in another entity. New rows are current, with `created_at` at their `transaction_from`;
- current rows don't overlap, and the default scope sees exactly them;
- the rows current at each earlier write's transaction time are the rows that write left, and sampled `transaction_at` and `find_at_time` queries agree;
- `terminated?`, `shifted_genesis?` and sampled `find_at_time` point queries agree with the timeline;
- `update!` on a self an operation left behaves as on a freshly loaded record.

An upstream write's outcome is only compared with the model. A difference is an *upstream divergence*: counted in the report (`FORK_PROPERTY_DIVERGENCES=1` prints them), never a failure, since upstream's own behaviour isn't what the harness pins.

### Tiers

| Tier | How | What | Time |
| --- | --- | --- | --- |
| smoke | the default; part of every `rspec` run | 4 batches, 22 sequences of up to 30 steps | about 10 seconds |
| deep | `FORK_PROPERTY=deep` | 12 batches of 300 sequences of up to 40 steps: each model with zero-length rows and seams off and on | about 13 minutes in one process, 5 split by model across three |

The smoke tier prints nothing unless it fails, and stops at its first failure. The deep tier, and any run from a seed, runs every sequence, shrinks the first failure of each signature, writes a report per batch to `$TMPDIR/activerecord-bitemporal-fork-property/<model>-<first seed>.txt` and prints one line per batch.

Run the deep tier before merging a change to the operations or to the harness, and after a sync that changes upstream's persistence, scopes or callbacks. `FORK_PROPERTY_MODEL` splits it by model, to run in parallel, each with its own database (see [Running](#running)):

```sh
FORK_PROPERTY=deep FORK_PROPERTY_MODEL=Employee bundle exec rspec spec/fork/property
```

The deep tier also runs on GitHub. In the Actions tab, choose **Fork property (deep)**, then **Run workflow**. The workflow, `.github/workflows/fork-property.yml`, runs one job per model, each with its own PostgreSQL, so the models run at once. Its inputs choose the Ruby version and the gemfile in `gemfiles/`; the defaults, Ruby `4.0` and `rails_8.1`, are the newest pair in the Test workflow's matrix. Each job uploads its model's reports as the artifact `fork-property-<model>` on the run's page, whether it passes or fails. Nothing else starts the workflow, except a pull request that changes the workflow file, which runs it with the defaults.

### ENV knobs

| Variable | Effect |
| --- | --- |
| `FORK_PROPERTY=deep` | The deep tier instead of the smoke tier |
| `FORK_PROPERTY_MODEL` | `Employee`, `Department` or `CustomColumnRecord`: only that model's batches; with a seed, the model to run (default `Employee`) |
| `FORK_PROPERTY_SEED` | One batch from this seed instead of the tier's batches |
| `FORK_PROPERTY_COUNT` | Sequences in that batch (default 1); in a tier, in each batch |
| `FORK_PROPERTY_STEPS` | Steps per sequence at most (default 40); in a tier, in each batch |
| `FORK_PROPERTY_ZERO_LENGTH=1` | With a seed: zero-length rows on |
| `FORK_PROPERTY_SEAMS=1` | With a seed: seams on |
| `FORK_PROPERTY_SHRINK=0` | Don't shrink failures |
| `FORK_PROPERTY_OUT` | Where reports go |
| `FORK_PROPERTY_DIVERGENCES=1` | Print upstream divergences |
| `FORK_PROPERTY_MUTANT` | Check that the harness catches that mutant |

### When it fails

A failure has a signature, the step kind and the check that broke (`correct:timeline`, `cancel_termination:not_minimal`, `history:replay`, ...). For the first failure of each signature in a batch, the report gives:

- the message, with the step and the timeline before, after and wanted;
- the last steps that ran, each with what it wrote;
- the sequence shrunk: steps deleted while it still fails with the same signature, then each step simplified (its dt to one second, its unsaved attributes, block or scope and time format dropped);
- Ruby that replays the shrunk sequence;
- the command that reruns the sequence from its seed.

For example:

```
=== correct:timeline (seed 1000)
timeline mismatch
  op: e0 +1s correct(valid_from: d31, valid_to: d33, {company_id: 1, emp_code: "y"}) (time as a date)
  before: [d27,d33){name="a",emp_code="y",company_id=2}
  after:  [d27,d31){name="a",emp_code="y",company_id=2}
  want:   [d27,d31){name="a",emp_code="y",company_id=2} [d31,d33){name="a",emp_code="y",company_id=1}
...
-- replay:
ForkProperty.replay(Employee, [
  ForkProperty::Step.new(kind: :create, entity: 0, dt: 1, args: { from: ForkProperty.day(27), to: ForkProperty.day(33), attrs: { name: "b", emp_code: "x", company_id: 2 } }),
  ForkProperty::Step.new(kind: :correct, entity: 0, dt: 1, args: { from: ForkProperty.day(31), to: ForkProperty.day(33), attrs: { company_id: 1, emp_code: "y" } }),
], zero_length: false, check_seed: 1000)
-- rerun: FORK_PROPERTY_MODEL=Employee FORK_PROPERTY_SEED=1000 FORK_PROPERTY_STEPS=30 FORK_PROPERTY_SEAMS=1 bundle exec rspec spec/fork/property
```

Times read as days from 2026-01-01 (`d31`), plus seconds; `INF` is the end of valid time. `e0` is the first entity, and `+1s` the transaction time since the previous step.

To work on it:

1. **Rerun it** with the rerun command. Sequence *i* of a batch runs from seed *first seed + i*, so any one of them reruns alone, and writes its report.
2. **Replay it.** `ForkProperty.replay` returns `[failure or nil, runner]`, and `runner.log` tells what each step did. In a scratch spec in `spec/fork/property/`, not to commit:

   ```ruby
   require 'spec_helper'
   require_relative 'reference_model'
   require_relative 'sequence_runner'

   RSpec.describe "replay" do
     it do
       failure, runner = ForkProperty.replay(Employee, [...], zero_length: false, check_seed: 1000)
       puts runner.log
       expect(failure).to be_nil, failure&.message
     end
   end
   ```

3. **Decide which is wrong**, the operation or `ReferenceModel`. When it's the model, the semantics are in question: the model, its comment and the operation's documentation in `docs/` change together.
4. **Pin it** with an example in the spec that owns the operation (see [Layout](#layout)), written in that spec's style with plain setup, not the harness. The harness finds the case; the example keeps it fixed.

### Mutants

`FORK_PROPERTY_MUTANT=<name>` prepends a deliberate bug to `TimelineOperations` at runtime; `lib/` is never edited. The property example then passes when a check catches the mutant, and prints which check and after how many sequences; it fails when the mutant survives. The mutant acts only inside that example, so `FORK_PROPERTY_MUTANT=no_merge bundle exec rspec spec/fork` runs every other spec against the real operations.

| Mutant | The bug | First caught by, in the smoke tier |
| --- | --- | --- |
| `no_merge` | Equal neighbours aren't merged | `cancel_termination:timeline` |
| `zero_length_as_segment` | Zero-length rows count as segments | `reopen:succeeded` |
| `cancel_walk_oldest_first` | The cancels restore the oldest restorable timeline, not the most recent | `cancel_shift_genesis:raised` |
| `no_recorded_since_guard` | The cancels never refuse, discarding what was recorded since | `cancel_termination:succeeded` |
| `recorded_since_inserts_only` | A row only closed since doesn't make a cancel refuse | Survives it; the deep tier catches it by `cancel_shift_genesis:succeeded` |
| `reload_at_now` | Self is reloaded at now, not at its own valid datetime | `correct:self_version` |
| `noop_reloads` | A call with nothing to write reloads self anyway | `cancel_shift_genesis:moved_self_with_nothing_to_write` |
| `rewrite_unchanged` | Every current row is closed and rewritten, changed or not | `shift_genesis:not_minimal` |
| `insert_skipped` | The last piece to insert never is | `correct:timeline` |

Check them all after changing the harness, a check or the generator above all, to see that it still catches what it did:

```sh
for mutant in no_merge zero_length_as_segment cancel_walk_oldest_first no_recorded_since_guard \
              reload_at_now noop_reloads rewrite_unchanged insert_skipped; do
  FORK_PROPERTY_MUTANT=$mutant bundle exec rspec spec/fork/property
done
FORK_PROPERTY=deep FORK_PROPERTY_MUTANT=recorded_since_inserts_only bundle exec rspec spec/fork/property
```

Each mutant overrides a private method of `timeline_operations.rb`, some with a copy of part of its body. When one of those methods changes, update or drop its mutant.

### Keeping the model in step

- A change to what an operation does changes its function in `reference_model.rb`, and the comment above it, in the same PR. The harness fails until it does: that's the point.
- A new operation gets a function in `ReferenceModel`, a kind in `FORK_OPERATIONS`, and a place in `Runner`'s generation, description and execution; consider a mutant for it too.
- A change to the generator changes the sequence each seed produces, so seeds in older reports no longer reproduce. Shrunk replays still do: they're plain steps.

## Upstream sentinel

Refinements reach only the file that uses them, so `TimelineOperations` can't use those in upstream's `bitemporal.rb` and carries copies of two: `timeline_dup` mirrors the refined `ActiveRecord::Base#dup`, `timeline_close` the refined `Persistence#update_transaction_to`. `spec/fork/upstream_sentinel_spec.rb` fingerprints upstream's refinements block (a SHA256 of its code, ignoring indentation, blank lines and full-line comments), so a sync that changes the block fails instead of leaving the copies behind:

- **"is unchanged since the fork last mirrored it" fails**: review upstream's change (the message has the `git diff` to run), mirror what applies into `timeline_dup` or `timeline_close` and their examples in `timeline_operations_spec.rb`, and record the new digest the message prints.
- **"is still there" fails**: upstream moved or reshaped the block. Find where the refined methods went, review them the same way, and point the sentinel at them.

Upstream behaviour the fork relies on by calling it, not copying it, is pinned by examples in `spec/fork` instead, which fail when the behaviour changes whatever the code looks like: the row lock `save!` takes and `valid_at` reading times in `Time.zone`, among others.

### After a sync with upstream

1. `bundle exec rspec spec/activerecord-bitemporal`: upstream's suite should pass on the fork as it does upstream.
2. `bundle exec rspec spec/fork`: the fork's specs, the sentinel and the smoke tier.
3. `FORK_PROPERTY=deep bundle exec rspec spec/fork/property` when the sync changed persistence, scopes or callbacks.
