# frozen_string_literal: true

# Fork-added timeline operations: correct, shift_genesis, terminate, their cancels and reopen.
#
# After any of them the entity's current timeline has no seams (adjacent segments with equal
# business attributes) and no zero-length rows, whatever upstream writes left there. Rows
# whose range and values don't change keep their rows, and a call that changes nothing
# writes nothing and leaves self alone (see perform_timeline_operation).
#
# They read the entity's rows unscoped (see timeline_rows), so a transaction_at, valid_at or
# bitemporal_at block around the call, a scoping block or the model's default scope can't
# hide a row from them.
#
# Loaded from fork.rb once ActiveRecord is loaded; the fork's error classes live there.
module ActiveRecord
  module Bitemporal
    module TimelineOperations
      # Cascade Correction: Correct a retroactive value while preserving future changes
      #
      # A patch over [valid_from, valid_to), like SQL:2011's UPDATE ... FOR PORTION OF: each
      # segment overlapping the span keeps its own attributes there, with only the given ones
      # replaced. Gaps stay gaps, and segments the patch wouldn't change keep their rows. Unlike
      # the standard, adjacent equal segments are merged and zero-length rows closed anywhere in
      # the timeline, as every operation here does, so a correction that changes nothing writes
      # only to do that, and otherwise nothing.
      #
      # Both times are taken as the valid-time column stores them (see cast_valid_time).
      #
      # @param valid_from [Time, Date, String] When the correction starts being true
      # @param valid_to [Time, Date, String, nil] When the correction ends (optional)
      #   - If specified: Correct exactly [valid_from, valid_to), resume timeline at valid_to
      #   - If omitted: Correct from valid_from to the end of the segment containing it, preserving
      #     every later segment. That end counts even when the next segment holds equal values.
      # @param attributes [Hash] The corrected attribute values
      # @raise [ArgumentError] if valid_to <= valid_from, or attributes name a bitemporal column
      # @raise [ActiveRecord::RecordNotFound] if no segment contains valid_from
      # @raise [ActiveRecord::Bitemporal::ValidDatetimeRangeError] if valid_to is past the timeline's end
      # @return [Boolean] true if successful
      def correct(valid_from:, valid_to: nil, **attributes)
        valid_from = cast_valid_time(valid_from_key, valid_from)
        valid_to = cast_valid_time(valid_to_key, valid_to)

        if valid_to && valid_to <= valid_from
          raise ArgumentError, "valid_to (#{valid_to}) must be greater than valid_from (#{valid_from})"
        end

        bitemporal_columns = BITEMPORAL_INFRASTRUCTURE_COLUMNS + [valid_from_key.to_s, valid_to_key.to_s]
        rejected = attributes.keys.map(&:to_s).select { |key|
          bitemporal_columns.include?(self.class.attribute_aliases.fetch(key, key))
        }
        unless rejected.empty?
          raise ArgumentError, "correct can't write bitemporal columns: #{rejected.join(', ')}"
        end

        with_bitemporal_option(correcting: true) do
          _correct_record(valid_from: valid_from, valid_to: valid_to, attributes: attributes)
        end
      end

      # Shift Genesis: Move when an entity's timeline begins (purely temporal)
      #
      # Unlike correct(), this changes *when* the entity existed, not *what* its attributes were.
      #   - Backward: Extends the first segment earlier (entity "existed sooner")
      #   - Forward: Trims/removes segments before the new start (entity "started later")
      #   - No-op: Returns true if new_valid_from equals current genesis, writing only to merge
      #     seams or close zero-length rows left in the timeline
      #
      # Raises ActiveRecord::RecordNotFound if no current-knowledge records exist.
      # Raises ArgumentError if new_valid_from would erase all segments (>= last valid_to).
      # new_valid_from is taken as the valid-time column stores it (see cast_valid_time).
      #
      # @param new_valid_from [Time, Date, String] The new start date for the entity's timeline
      # @return [Boolean] true if successful
      def shift_genesis(new_valid_from:)
        new_valid_from = cast_valid_time(valid_from_key, new_valid_from)
        _shift_genesis_record(new_valid_from: new_valid_from)
      end

      # Terminate: Set a finite end date for the entity's timeline (right edge)
      #
      # Unlike destroy (which operates on transaction time), this truncates the
      # valid-time timeline. Segments beyond termination_time are removed; a
      # segment spanning the boundary is truncated.
      #
      # Raises ActiveRecord::RecordNotFound if no current-knowledge records exist.
      # Raises ArgumentError if termination_time <= first valid_from or > last valid_to.
      # Re-terminating earlier works; re-terminating later is reopen, then terminate.
      # Terminating at the current end is a no-op, writing only to merge seams or close
      # zero-length rows left in the timeline.
      # termination_time is taken as the valid-time column stores it (see cast_valid_time).
      #
      # @param termination_time [Time, Date, String] When the entity stops being valid
      # @return [Boolean] true if successful
      def terminate(termination_time:)
        termination_time = cast_valid_time(valid_to_key, termination_time)
        _terminate_record(termination_time: termination_time)
      end

      # Cancel Termination: Full reversal via transaction history
      #
      # Restores the complete pre-termination timeline by searching backward
      # through transaction history. Recovers ALL segments that were removed
      # during termination.
      #
      # IMPORTANT: This is an undo — it restores the timeline as it stood just
      # before the termination, not the current timeline with valid_to extended.
      # If anything was recorded for the entity after the termination (a correct,
      # an update!, a re-terminate, ...), it refuses instead of discarding that:
      # it raises RecordedSinceTerminationError and writes nothing. reopen lifts the
      # end and keeps them.
      #
      # Segments it restores unchanged keep their current rows. No-op if entity is not
      # currently terminated, writing only to merge seams or close zero-length rows left in
      # the timeline.
      #
      # @raise [ActiveRecord::RecordNotFound] if no current-knowledge records exist
      # @raise [ActiveRecord::Bitemporal::PreTerminationStateNotFoundError] if
      #   transaction history cannot determine the pre-termination state
      # @raise [ActiveRecord::Bitemporal::RecordedSinceTerminationError] if changes were
      #   recorded after the termination (a PreTerminationStateNotFoundError)
      # @return [Boolean] true if successful
      def cancel_termination
        _cancel_termination_record
      end

      # Reopen: Lift the end of a terminated timeline (right edge)
      #
      # The last segment continues, with the values it already has, to DEFAULT_VALID_TO.
      # The end-side mirror of a backward shift_genesis, which extends the first segment's
      # values earlier.
      #
      # IMPORTANT: This is an edit, not an undo — like terminate and correct, it changes the
      # current timeline in valid time and never reads transaction history. Segments a
      # termination removed stay removed (cancel_termination brings them back). It works
      # whatever was recorded after the termination (a correct, an update!, a re-terminate,
      # ...), so it's the recourse when cancel_termination raises
      # RecordedSinceTerminationError.
      #
      # An end in the past is lifted as one in the future, and so is the end an upstream
      # destroy of the last segment leaves. Moving an end later is reopen, then terminate;
      # wrap both in a transaction to make the move atomic.
      #
      # The other segments keep their rows. No-op if the timeline isn't terminated (last
      # segment extends to infinity), writing only to merge seams or close zero-length rows
      # left in the timeline.
      #
      # @raise [ActiveRecord::RecordNotFound] if no current-knowledge records exist
      # @return [Boolean] true if successful
      def reopen
        _reopen_record
      end

      # Predicate: Is this entity's timeline terminated (finite end)?
      #
      # Zero-length rows don't count, as the operations look past them. Like them, it reads
      # the current timeline whatever block or scope it's called in.
      #
      # @return [Boolean] true if last segment's valid_to < DEFAULT_VALID_TO
      def terminated?
        last_valid_to = current_knowledge_rows.where(holding_a_time).maximum(valid_to_key)
        return false if last_valid_to.nil?
        last_valid_to < ActiveRecord::Bitemporal::DEFAULT_VALID_TO
      end

      # Cancel Shift Genesis: Full reversal via transaction history
      #
      # Restores the complete timeline at the original genesis by searching backward
      # through transaction history. Recovers ALL segments removed during a forward shift.
      #
      # IMPORTANT: This is an undo — it restores the most recent timeline that started
      # at the original genesis, as it stood just before the genesis moved off it, as
      # cancel_termination restores the most recent unterminated one. If anything was
      # recorded for the entity after that move (a correct, an update!, a terminate,
      # another shift_genesis, ...), it refuses instead of discarding that: it raises
      # RecordedSinceGenesisShiftError and writes nothing; a shift_genesis to the
      # original genesis moves it back and keeps them. So after two shifts it refuses,
      # and a second cancel finds nothing to cancel.
      #
      # Segments it restores unchanged keep their current rows. No-op if the genesis is the
      # original one (never shifted, shifted back, or already canceled), writing only to merge
      # seams or close zero-length rows left in the timeline.
      #
      # @raise [ActiveRecord::RecordNotFound] if no current-knowledge records exist
      # @raise [ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError] if
      #   transaction history holds no timeline at the original genesis
      # @raise [ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError] if changes were
      #   recorded after the genesis moved off the original (a PreShiftGenesisStateNotFoundError)
      # @return [Boolean] true if successful
      def cancel_shift_genesis
        _cancel_shift_genesis_record
      end

      # Predicate: Has this entity's genesis been shifted from its original value?
      #
      # Zero-length rows don't count, as the operations look past them. Like them, it reads
      # the whole timeline whatever block or scope it's called in.
      #
      # @return [Boolean] true if current genesis differs from original creation genesis
      def shifted_genesis?
        current_genesis = current_knowledge_rows
          .where(holding_a_time)
          .order(valid_from_key => :asc)
          .pick(valid_from_key)
        return false if current_genesis.nil?

        original_genesis = find_original_genesis
        current_genesis != original_genesis
      end

      def correcting?
        bitemporal_option[:correcting].present?
      end

      private

      # == Fork-owned copies of upstream's refinements
      #
      # Upstream's ActiveRecord::Base#dup override and Persistence#update_transaction_to
      # are refinements (`using Module.new { refine ... }` in bitemporal.rb), active only
      # inside the Persistence module body there. In this file plain #dup would copy the
      # bitemporal internal state onto new segments, and #update_transaction_to is
      # undefined. These helpers take the record as an argument because they're called
      # on records other than self.
      #
      # Keep them in sync: on every upstream merge, diff upstream's refinements block in
      # bitemporal.rb and mirror any change here (see timeline_operations_spec.rb).

      # Mirrors upstream's refined ActiveRecord::Base#dup: copy without the bitemporal
      # internal status.
      def timeline_dup(record)
        record.dup.tap { |copy|
          copy.instance_exec do
            @_swapped_id_previously_was = nil
            @_swapped_id = nil
            @previously_force_updated = false
          end unless copy.frozen?
        }
      end

      # Mirrors upstream's refined Persistence#update_transaction_to: close the row in
      # transaction time, setting deleted_at too when the model has that column.
      def timeline_close(record, value)
        if record.class.column_names.include?("deleted_at")
          record.update_columns(transaction_to: value, deleted_at: value)
        else
          record.update_columns(transaction_to: value)
        end
      end

      BITEMPORAL_INFRASTRUCTURE_COLUMNS = %w[id type created_at updated_at bitemporal_id transaction_from transaction_to deleted_at].freeze

      # Stored columns only: an attribute with no column can't tell two rows apart
      def bitemporal_business_attributes(record)
        excluded = BITEMPORAL_INFRASTRUCTURE_COLUMNS + [valid_from_key, valid_to_key]
        record.attributes.slice(*record.class.column_names).except(*excluded)
      end

      # A time as the valid-time column `key` stores it: what reading a row written with it gives
      # back. A date column keeps the day, a datetime column its precision, microseconds at most.
      # Operations take their times through this once, on entry, so they compare with stored
      # boundaries the same values they write.
      #
      # The time is read in Time.zone first, as upstream's valid_at reads it (Uniqueness's
      # scope_relation casts valid_datetime to the column's type the same way). It then goes the
      # way a write and a read take it: the column's type, the connection, and back through the
      # type. The connection matters for a datetime column declared without a precision, whose
      # type keeps nanoseconds while the connection writes microseconds.
      #
      # DEFAULT_VALID_TO stays the end of the timeline: it's cast as upstream's attribute default
      # casts it, without the move into Time.zone that gives the day before in a zone behind UTC.
      def cast_valid_time(key, time)
        time =
          if time == ActiveRecord::Bitemporal::DEFAULT_VALID_TO
            ActiveRecord::Bitemporal::DEFAULT_VALID_TO
          elsif time.respond_to?(:in_time_zone)
            time.in_time_zone
          else
            time
          end
        type = self.class.type_for_attribute(key)
        type.deserialize(self.class.connection.type_cast(type.serialize(time)))
      end

      # Every row of this entity, in every valid and transaction time. Unscoped, so neither a
      # transaction_at, valid_at or bitemporal_at block around the call, a caller's scoping
      # block nor the model's default scope can hide a row: an operation works on the whole
      # timeline, as upstream's uniqueness validation reads it. (Upstream's
      # ignore_valid_datetime and within_deleted have no condition to remove from it.) An STI
      # subclass still reads only its own type: that condition comes from the class.
      def timeline_rows
        self.class.unscoped.where(bitemporal_id: bitemporal_id)
      end

      # The rows of current knowledge: those not closed in transaction time
      def current_knowledge_rows
        timeline_rows.where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
      end

      # Serializes writes to this entity's timeline until the surrounding transaction ends.
      # PostgreSQL only. An operation that raises rolls back to its own savepoint, which
      # releases the locks taken here; those the transaction took earlier stay held.
      #
      # 1. A transaction-scoped advisory lock with this key:
      #      pg_advisory_xact_lock(hashtext(<table_name>), hashtext(<bitemporal_id as text>))
      #    The key is a public contract. A caller holding that lock in the same transaction
      #    and these operations wait for each other, and an operation called while holding
      #    it re-enters it instead of deadlocking. Unlike a row lock it holds even when the
      #    entity has no row valid now.
      # 2. FOR UPDATE on the row valid now, by the statement upstream's save and save! lock
      #    with outside any block. They lock that row first and then close the row valid at
      #    the record's own time, another row for a future-dated update. Taking any other row
      #    before this one could deadlock with them; taking this one first makes them wait
      #    holding nothing. It's pinned to now, whatever block or scope the caller is in.
      # 3. FOR UPDATE on every current-knowledge row, not just the one valid now. Upstream's
      #    save and destroy lock rows but never take the advisory lock, so this makes an
      #    upstream write already in flight on any of these rows commit before this
      #    operation reads the timeline.
      #
      # Not covered: upstream writes that read the timeline before they lock a row this
      # operation holds. A save on an entity with no row valid now locks no row first, and
      # destroy reads the version it copies before it locks the row it closes. Either can
      # read the timeline before this operation commits and write after. Callers serialize
      # such writes with these operations by holding the same advisory lock.
      def lock_timeline!
        keys = [self.class.table_name, bitemporal_id.to_s].map { |value|
          Arel::Nodes::NamedFunction.new("hashtext", [Arel::Nodes.build_quoted(value)])
        }
        lock = Arel::Nodes::NamedFunction.new("pg_advisory_xact_lock", keys)
        self.class.connection.execute(Arel::SelectManager.new.project(lock).to_sql)

        # save!'s statement as the default scope builds it at now
        now = Time.current
        self.class.unscoped
          .transaction_from_lteq(now).transaction_to_gt(now)
          .valid_from_lteq(now).valid_to_gt(now)
          .where(bitemporal_id: bitemporal_id)
          .lock!.pluck(:id)

        current_knowledge_rows.lock!.pluck(:id)
      end

      # Shared skeleton of the six timeline operations.
      #
      # Owns the steps every operation repeats: transaction, lock, timestamp, fetch,
      # normalize, close, insert, validate and reloading self. The block does the
      # op-specific part (guards, build): it receives the current segments and
      # current_time, and returns [replaced, pieces], the segments the op replaces and the
      # new pieces it adds. Raising in the block leaves the transaction before any write;
      # an op's no-op exit replaces nothing ([[], []]).
      #
      # The segments leave out zero-length rows (an upstream destroy at a segment's exact
      # start leaves one), so the guards and builders see only versions that hold a time.
      #
      # The result (segments - replaced + pieces) is normalized before anything is
      # written: zero-length pieces are dropped and equal adjacent neighbours merged,
      # seams an upstream update! left included. Only its difference from the current rows
      # is written. A row the result keeps, or a piece with the range and business
      # attributes of a current row, keeps that row; every other current row, zero-length
      # ones included, is closed, and every other piece inserted. So after any operation
      # the timeline has no seams and no zero-length rows, and only the rows that change
      # are recorded again.
      #
      # current_time is read only once the locks are held, so it is later than every write
      # that committed while this operation waited for them. A current row recorded after it
      # all the same, by a host whose clock runs ahead, raises before anything is written
      # (see refuse_rows_recorded_later!).
      #
      # Afterwards self is reloaded onto the new timeline (see reload_onto_timeline). A call
      # with nothing to write writes nothing and leaves self alone.
      def perform_timeline_operation
        # The reload at the end would swap in fresh attributes, so refuse up front as update! does
        raise FrozenError, "can't modify frozen attributes" if frozen?

        ActiveRecord::Base.transaction(requires_new: true) do
          lock_timeline!
          current_time = Time.current

          rows = find_all_current_knowledge_segments
          refuse_rows_recorded_later!(rows, current_time)
          segments = rows.reject { |row| zero_length?(row) }

          # Guard and build (op-specific)
          replaced, pieces = yield(segments, current_time)

          # Normalize the resulting timeline, then diff it against the current rows
          timeline = segments.reject { |segment| replaced.any? { |record| record.equal?(segment) } } + pieces
          timeline = merge_equal_neighbours(
            timeline.reject { |piece| zero_length?(piece) }.sort_by { |piece| [piece[valid_from_key], piece[valid_to_key]] },
            current_time
          )
          records_to_close, new_records = timeline_changes(rows, timeline)
          next true if records_to_close.empty? && new_records.empty?

          # CLOSE old records FIRST (critical ordering)
          records_to_close.each do |record|
            timeline_close(record, current_time)
          end

          # Insert new records
          new_records.each do |record|
            record.save_without_bitemporal_callbacks!(validate: false)
            # save! raises when a callback throws :abort, but the transaction block Rails opens
            # inside it joins the enclosing one and swallows an ActiveRecord::Rollback raised
            # before the insert: it returns nil without inserting, and the rows closed above
            # would stay closed
            raise ActiveRecord::RecordNotSaved.new("Failed to save the record", record) unless record.persisted?
          end

          # Validate the new timeline (post-hoc)
          validate_cascade_correction_timeline!

          reload_onto_timeline

          true
        end
      end

      # Raises TransactionTimeSkewError when a current row was recorded after current_time.
      # A host whose clock runs ahead of this one records such a row, and closing it at
      # current_time would set its transaction_to before its transaction_from. Clock skew
      # between hosts is otherwise out of scope, as it is for upstream's writes.
      #
      # current_time is compared as read, not as the column would store it: a stored time is
      # cut to the column's precision, never rounded up. So a row recorded at or before
      # current_time never reads as later than it, and a row that does is later than the
      # transaction_to a close would store too.
      def refuse_rows_recorded_later!(rows, current_time)
        latest = rows.max_by(&:transaction_from)
        return unless latest && latest.transaction_from > current_time

        raise TransactionTimeSkewError,
          "#{self.class} with bitemporal_id=#{bitemporal_id} has a current row (id=#{latest.id}) " \
          "with transaction_from #{latest.transaction_from.iso8601(6)}, " \
          "#{(latest.transaction_from - current_time).round(6)} seconds after this operation's " \
          "time #{current_time.iso8601(6)}. Closing it would set its transaction_to before its " \
          "transaction_from; the host that recorded it may have a clock running ahead"
      end

      # Raises RecordNotFound when the entity has no segment: no current-knowledge row, or
      # only zero-length ones. correct raises its own, naming the time no segment contains.
      def refuse_empty_timeline!(segments)
        return unless segments.empty?

        raise ActiveRecord::RecordNotFound.new(
          "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
          "(no current-knowledge records)",
          self.class, "bitemporal_id", bitemporal_id
        )
      end

      def zero_length?(record)
        record[valid_from_key] == record[valid_to_key]
      end

      # The condition a row that isn't zero-length meets
      def holding_a_time
        self.class.arel_table[valid_from_key].lt(self.class.arel_table[valid_to_key])
      end

      # Merges equal neighbours of a timeline ordered by valid time: a piece ending where the
      # next one starts, with equal business attributes, takes over the next one's range. A
      # stored segment is never extended in place: it's closed and replaced by a new piece.
      def merge_equal_neighbours(timeline, current_time)
        timeline.each_with_object([]) { |piece, acc|
          previous = acc.last
          if previous && previous[valid_to_key] == piece[valid_from_key] &&
             bitemporal_business_attributes(previous) == bitemporal_business_attributes(piece)
            acc[-1] = timeline_piece(previous, previous[valid_from_key], previous[valid_to_key], current_time) unless previous.new_record?
            acc.last[valid_to_key] = piece[valid_to_key]
          else
            acc << piece
          end
        }
      end

      # What turns the current rows into timeline: [rows to close, pieces to insert]. A row
      # the timeline holds is kept. So is a row with a new piece's range and business
      # attributes, in place of that piece, so an unchanged version isn't recorded again.
      def timeline_changes(rows, timeline)
        kept = timeline.reject(&:new_record?)
        new_records = []
        timeline.select(&:new_record?).each do |piece|
          unchanged = rows.find { |row|
            kept.none? { |record| record.equal?(row) } &&
              row[valid_from_key] == piece[valid_from_key] && row[valid_to_key] == piece[valid_to_key] &&
              bitemporal_business_attributes(row) == bitemporal_business_attributes(piece)
          }
          unchanged ? kept << unchanged : new_records << piece
        end

        [rows.reject { |row| kept.any? { |record| record.equal?(row) } }, new_records]
      end

      # Leaves self as reload would: on the current version valid at self's valid datetime
      # (now when it has none). When no version is valid then, self takes the latest version
      # starting before it, else the first one. Runs the real reload pinned to that version,
      # so every reload hook runs (dirty tracking, autosave flags, a model's own resets) and
      # unsaved changes are discarded.
      def reload_onto_timeline
        # Cast as the database stores it: Ruby compares a Date with a Time as midnight UTC
        at = cast_valid_time(valid_from_key, valid_datetime || Time.current)
        # Unscoped, so no scope or block of the caller's can hide a version, the ones this op
        # just wrote included
        versions = current_knowledge_rows
          .order(valid_from_key => :asc)
          .reject { |r| r[valid_from_key] == r[valid_to_key] }
        covering = versions.find { |r| r[valid_from_key] <= at && at < r[valid_to_key] }
        version = covering ||
          versions.reverse.find { |r| r[valid_from_key] <= at } ||
          versions.first

        # Forced, so neither the times self was loaded at nor a caller's valid_at!,
        # transaction_at! or ignore_* block can move the lookup off that version. Pinned at
        # `at` when the version covers it, so a strict-loading record's associations, which
        # reload preloads under this pin, load at the time reload would load them at.
        # Unscoped as above, and with self's own ignore_* options off, since they'd win over
        # the forced ones.
        previous_swapped_id = swapped_id
        ActiveRecord::Bitemporal.valid_at!(covering ? at : version[valid_from_key]) do
          ActiveRecord::Bitemporal.transaction_at!(Time.current) do
            with_bitemporal_option(ignore_valid_datetime: false, ignore_transaction_datetime: false) do
              reload(unscoped: true)
            end
          end
        end
        @_swapped_id_previously_was = previous_swapped_id
      end

      # Cascade Correction: Main implementation
      def _correct_record(valid_from:, valid_to:, attributes:)
        perform_timeline_operation do |segments, current_time|
          # 1. One segment must contain valid_from
          containing_record = segments.find { |r|
            r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
          }

          if containing_record.nil?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} at #{valid_from}",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          # 2. Unbounded corrections end where the containing segment ends, even at a seam
          effective_valid_to = valid_to || containing_record[valid_to_key]

          # Guard: correction must not extend past the entity's timeline end
          #
          # A terminated (or shift-genesis-truncated) entity has a finite valid_to on
          # its last segment. Allowing a bounded correction to specify a valid_to
          # beyond that point would silently "un-terminate" the entity — extending
          # its lifetime without going through reopen or cancel_termination.
          #
          #   Timeline:  |---A---|---B---|  (terminated at T)
          #   Correction:        |---X-------->|  ← valid_to past T — REJECTED
          #
          # Unbounded corrections (no explicit valid_to) are safe — they inherit the
          # containing record's valid_to, which already respects the timeline boundary.
          #
          # A patch leaves a trailing gap empty, so this no longer guards against un-terminating.
          # It stays as part of the contract callers rely on (e.g. to answer a 409).
          timeline_end = segments.last[valid_to_key]
          if effective_valid_to > timeline_end
            raise ActiveRecord::Bitemporal::ValidDatetimeRangeError,
              "correction valid_to (#{effective_valid_to}) exceeds timeline end " \
              "(#{timeline_end}). Reopen the timeline or cancel its termination first to extend it."
          end

          # 3. Patch the span
          build_correction_records(segments, valid_from, effective_valid_to, attributes, current_time)
        end
      end

      # Shift Genesis: Main implementation
      def _shift_genesis_record(new_valid_from:)
        perform_timeline_operation do |segments, current_time|
          # 1. Guard: entity must exist
          refuse_empty_timeline!(segments)

          genesis = segments.first

          # 2. No-op: same date, nothing to replace
          next [[], []] if new_valid_from == genesis[valid_from_key]

          # 3. Guard: forward shift must not erase all segments
          if new_valid_from >= segments.last[valid_to_key]
            raise ArgumentError,
              "shift_genesis would erase all segments: new_valid_from (#{new_valid_from}) " \
              ">= last segment valid_to (#{segments.last[valid_to_key]})"
          end

          # 4. Build records to replace and new records
          if new_valid_from < genesis[valid_from_key]
            build_genesis_backward_shift(genesis, new_valid_from, current_time)
          else
            build_genesis_forward_shift(segments, new_valid_from, current_time)
          end
        end
      end

      def find_all_current_knowledge_segments
        current_knowledge_rows
          # valid_to breaks ties, so a zero-length row comes before the segment it shares a start with
          .order(valid_from_key => :asc, valid_to_key => :asc)
          .to_a
          .each { |record|
            record.id = record.swapped_id
            record.clear_changes_information
          }
      end

      def build_genesis_backward_shift(genesis, new_valid_from, current_time)
        [[genesis], [timeline_piece(genesis, new_valid_from, genesis[valid_to_key], current_time)]]
      end

      def build_genesis_forward_shift(segments, new_valid_from, current_time)
        records_to_close = []
        new_records = []

        segments.each do |segment|
          if segment[valid_to_key] <= new_valid_from
            # Entirely before — close, no replacement
            records_to_close << segment

          elsif segment[valid_from_key] < new_valid_from
            # Spans the boundary — close + trimmed replacement
            records_to_close << segment
            new_records << timeline_piece(segment, new_valid_from, segment[valid_to_key], current_time)

          else
            # valid_from >= new_valid_from — untouched, stop
            break
          end
        end

        [records_to_close, new_records]
      end

      # Terminate: Main implementation
      def _terminate_record(termination_time:)
        perform_timeline_operation do |segments, current_time|
          # 1. Guard: entity must exist
          refuse_empty_timeline!(segments)

          first_segment = segments.first
          last_segment = segments.last

          # 2. Guard: termination_time must be after timeline start
          if termination_time <= first_segment[valid_from_key]
            raise ArgumentError,
              "termination_time (#{termination_time}) must be greater than " \
              "first segment valid_from (#{first_segment[valid_from_key]})"
          end

          # 3. Guard: termination_time must not exceed timeline end
          if termination_time > last_segment[valid_to_key]
            raise ArgumentError,
              "termination_time (#{termination_time}) exceeds last segment " \
              "valid_to (#{last_segment[valid_to_key]})"
          end

          # 4. No-op: already terminated at this exact time, nothing to replace
          next [[], []] if termination_time == last_segment[valid_to_key]

          # 5. Build records to replace and new records
          build_termination_records(segments, termination_time, current_time)
        end
      end

      # Cancel Termination: Main implementation
      def _cancel_termination_record
        perform_timeline_operation do |segments, current_time|
          # 1. Guard: entity must exist
          refuse_empty_timeline!(segments)

          # 2. No-op: not terminated (last segment extends to infinity), nothing to replace
          next [[], []] if segments.last[valid_to_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_TO

          # 3. Find pre-termination state via transaction history
          pre_termination_state, terminated_at = find_pre_termination_state
          if pre_termination_state.nil?
            raise PreTerminationStateNotFoundError,
              "Cannot determine pre-termination state for #{self.class} " \
              "with bitemporal_id=#{bitemporal_id}"
          end

          # 4. Guard: restoring that state would discard anything recorded after the termination
          if recorded_since?(terminated_at)
            raise RecordedSinceTerminationError,
              "Changes were recorded for #{self.class} with bitemporal_id=#{bitemporal_id} " \
              "after its termination; cancelling it would discard them. To lift the end and " \
              "keep them, call reopen"
          end

          # 5. Replace ALL current segments with the pre-termination ones (see restored_pieces)
          [segments, restored_pieces(pre_termination_state, current_time)]
        end
      end

      # Reopen: Main implementation
      def _reopen_record
        perform_timeline_operation do |segments, current_time|
          # 1. Guard: entity must exist
          refuse_empty_timeline!(segments)

          last_segment = segments.last

          # 2. No-op: not terminated (last segment extends to infinity), nothing to replace
          next [[], []] if last_segment[valid_to_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_TO

          # 3. Continue the last segment to infinity, as it is: no history is read
          [
            [last_segment],
            [timeline_piece(last_segment, last_segment[valid_from_key], ActiveRecord::Bitemporal::DEFAULT_VALID_TO, current_time)],
          ]
        end
      end

      def build_termination_records(segments, termination_time, current_time)
        records_to_close = []
        new_records = []

        segments.each do |segment|
          if segment[valid_to_key] <= termination_time
            # Entirely before termination — UNTOUCHED
            next
          elsif segment[valid_from_key] < termination_time
            # Spans boundary — CLOSE + truncated copy
            records_to_close << segment
            new_records << timeline_piece(segment, segment[valid_from_key], termination_time, current_time)
          else
            # segment.valid_from >= termination_time — entirely after — CLOSE, no replacement
            records_to_close << segment
          end
        end

        [records_to_close, new_records]
      end

      # The most recent snapshot the block accepts, and the change point it ended at:
      # [segments, change_point], or nil when it accepts none. Each cancel finds the timeline
      # it restores with it.
      #
      # == How it works (transaction history search)
      #
      # Every bitemporal mutation closes old records (transaction_to = now) and
      # inserts new ones (transaction_from = now). This creates "change points"
      # — transaction_to values where the timeline was rewritten.
      #
      # We walk backward through change points, reconstructing the timeline that
      # was active just before each change, until the block accepts one.
      #
      # A snapshot's zero-length rows are no part of it, so a snapshot of nothing else is
      # skipped: there's no timeline in it to restore.
      def find_latest_snapshot
        change_points = timeline_rows
          .where.not(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .distinct.pluck(:transaction_to)
          .sort.reverse

        change_points.each do |cp|
          state = timeline_rows
            .where(self.class.arel_table[:transaction_from].lt(cp))
            .where(self.class.arel_table[:transaction_to].gteq(cp))
            .order(valid_from_key => :asc)
            .to_a
            .each { |r|
              r.id = r.swapped_id
              r.clear_changes_information
            }
            .reject { |r| zero_length?(r) }

          next if state.empty?
          return [state, cp] if yield(state)
        end

        nil
      end

      # The most recent snapshot with an infinite end, and the change point it ended at:
      # [segments, change_point], or nil when no snapshot has one (see find_latest_snapshot).
      def find_pre_termination_state
        find_latest_snapshot { |state| state.last[valid_to_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
      end

      # Whether anything was recorded for this entity after change_point, the moment the
      # operation a cancel undoes took effect: a row inserted after it, or a row closed after
      # it (some writes only close rows, such as a terminate at a segment boundary). Rows that
      # operation wrote carry change_point itself, so the bounds are strict. Any row of the
      # family counts, whatever its valid time.
      def recorded_since?(change_point)
        transaction_from = self.class.arel_table[:transaction_from]
        transaction_to = self.class.arel_table[:transaction_to]
        timeline_rows
          .where(
            transaction_from.gt(change_point).or(
              transaction_to.gt(change_point).and(transaction_to.not_eq(ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO))
            )
          )
          .exists?
      end

      # A cancel's new pieces: the snapshot's segments as new records with this op's
      # transaction_from, to replace every current segment (the skeleton keeps the rows of those
      # that come back unchanged). Must clear deleted_at because historical records have it set
      # (by timeline_close or upstream's update_transaction_to), and
      # bitemporal_assign_initialize_value would use it to overwrite transaction_to during save.
      def restored_pieces(snapshot, current_time)
        snapshot.map { |segment|
          timeline_piece(segment, segment[valid_from_key], segment[valid_to_key], current_time).tap { |piece|
            piece.deleted_at = nil if piece.class.column_names.include?("deleted_at")
          }
        }
      end

      # Cancel Shift Genesis: Main implementation
      #
      # Algorithm mirrors _cancel_termination_record (perform_timeline_operation does
      # the lock, fetch, normalize, close, insert, validate and reloading self):
      # 1. Guard existence → 2. No-op if genesis matches original →
      # 3. Find the most recent timeline at the original genesis → 4. Refuse if anything
      # was recorded since → 5. Replace current with it
      def _cancel_shift_genesis_record
        perform_timeline_operation do |segments, current_time|
          # 1. Guard: entity must exist
          refuse_empty_timeline!(segments)

          # 2. No-op: genesis matches original (never shifted, or already canceled), nothing to replace
          current_genesis = segments.first[valid_from_key]
          original_genesis = find_original_genesis
          next [[], []] if current_genesis == original_genesis

          # 3. Find the timeline at the original genesis via transaction history
          pre_shift_state, shifted_at = find_pre_shift_genesis_state(original_genesis)
          if pre_shift_state.nil?
            raise PreShiftGenesisStateNotFoundError,
              "Cannot determine pre-shift genesis state for #{self.class} " \
              "with bitemporal_id=#{bitemporal_id}"
          end

          # 4. Guard: restoring that state would discard anything recorded after the genesis
          #    moved off it, a later shift included
          if recorded_since?(shifted_at)
            raise RecordedSinceGenesisShiftError,
              "Changes were recorded for #{self.class} with bitemporal_id=#{bitemporal_id} " \
              "after its genesis shift; cancelling it would discard them. To move the genesis " \
              "back to #{original_genesis} and keep them, call shift_genesis with that time"
          end

          # 5. Replace ALL current segments with the pre-shift ones (see restored_pieces)
          [segments, restored_pieces(pre_shift_state, current_time)]
        end
      end

      # Find the original genesis date — the valid_from of the entity's very first
      # database record, ordered by transaction_from (creation time).
      #
      # This is the "birth date" that was set when the entity was first created.
      # It never changes even as the entity is updated, corrected, or shifted.
      #
      # @return [Time, nil] the original genesis time, or nil if no records exist
      def find_original_genesis
        timeline_rows
          .order(transaction_from: :asc, valid_from_key => :asc)
          .pick(valid_from_key)
      end

      # Find the pre-shift state: the most recent complete timeline snapshot whose genesis
      # (first segment's valid_from) is the original genesis, as find_pre_termination_state
      # finds the most recent one with an infinite end (see find_latest_snapshot).
      #
      # Walking backward through change points, a timeline an earlier shift left at another
      # genesis is passed over:
      #
      #   Transaction time →
      #   ┌───────────────────────────────────────────────────────────┐
      #   │ t1: CREATE    |---A---|---B---|---C--->∞                  │ genesis = Jan (original)
      #   │ t2: SHIFT →       |-A-|---B---|---C--->∞                  │ genesis = Feb
      #   │ t3: SHIFT →           |---B---|---C--->∞                  │ genesis = Mar
      #   │                                                           │
      #   │ Walking backward from t3:                                 │
      #   │   change_point = t3 → t2 state: genesis Feb, passed over  │
      #   │   change_point = t2 → t1 state: genesis Jan → FOUND       │
      #   └───────────────────────────────────────────────────────────┘
      #
      # Here the cancel then refuses, since the t3 shift was recorded after t2 (see
      # recorded_since?). After the t2 shift alone, it would restore the t1 timeline.
      #
      # @param original_genesis [Time] the entity's original genesis (see find_original_genesis)
      # @return [Array(Array<ActiveRecord::Base>, Time), nil] the pre-shift segment records
      #   and the change point they ended at (t2 above), or nil if no snapshot starts at the
      #   original genesis
      def find_pre_shift_genesis_state(original_genesis)
        find_latest_snapshot { |state| state.first[valid_from_key] == original_genesis }
      end

      def validate_cascade_correction_timeline!
        # Check for overlapping valid times at current transaction time
        records = current_knowledge_rows
          .order(valid_from_key => :asc, valid_to_key => :asc)
          .to_a

        records.each_cons(2) do |r1, r2|
          if r1[valid_to_key] > r2[valid_from_key]
            message = "Overlapping valid periods detected: " \
                      "#{r1[valid_from_key]}-#{r1[valid_to_key]} overlaps with " \
                      "#{r2[valid_from_key]}-#{r2[valid_to_key]}"
            raise ActiveRecord::RecordInvalid.new(self), message
          end
        end
      end

      # Builds correct's patch over [valid_from, valid_to): returns [replaced, pieces].
      #
      # Each segment overlapping the span is split at the span's edges and the piece inside gets
      # `attributes`; a segment the patch wouldn't change is kept as it is. The pieces aren't
      # merged here: perform_timeline_operation merges equal neighbours across the whole
      # resulting timeline, old seams included, before anything is written. When no segment
      # would change, this returns [[], []].
      def build_correction_records(segments, valid_from, valid_to, attributes, current_time)
        segments.each_with_object([[], []]) { |segment, (replaced, pieces)|
          from = segment[valid_from_key]
          to = segment[valid_to_key]
          next unless from < valid_to && to > valid_from

          corrected = timeline_piece(segment, [from, valid_from].max, [to, valid_to].min, current_time)
          corrected.assign_attributes(attributes)
          next if bitemporal_business_attributes(corrected) == bitemporal_business_attributes(segment)

          replaced << segment
          pieces.concat([
            (timeline_piece(segment, from, valid_from, current_time) if from < valid_from),
            corrected,
            (timeline_piece(segment, valid_to, to, current_time) if to > valid_to),
          ].compact)
        }
      end

      # A new current-knowledge row with source's attributes over [from, to)
      def timeline_piece(source, from, to, current_time)
        timeline_dup(source).tap { |piece|
          piece.id = nil
          piece[valid_from_key] = from
          piece[valid_to_key] = to
          piece.transaction_from = current_time
          piece.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
        }
      end
    end

    module Persistence
      include TimelineOperations
    end
  end
end
