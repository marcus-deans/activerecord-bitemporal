# frozen_string_literal: true

# Fork-added timeline operations: correct, shift_genesis, terminate and their cancels.
#
# Loaded from fork.rb once ActiveRecord is loaded; the fork's error classes live there.
module ActiveRecord
  module Bitemporal
    module TimelineOperations
      # Cascade Correction: Correct a retroactive value while preserving future changes
      #
      # @param valid_from [Time, Date, String] When the correction starts being true
      # @param valid_to [Time, Date, String, nil] When the correction ends (optional)
      #   - If specified: Correct exactly [valid_from, valid_to), resume timeline at valid_to
      #   - If omitted: Correct from valid_from to next change point, preserve all future changes
      # @param attributes [Hash] The corrected attribute values
      # @return [Boolean] true if successful
      def correct(valid_from:, valid_to: nil, **attributes)
        valid_from = valid_from.in_time_zone if valid_from.respond_to?(:in_time_zone)
        valid_to = valid_to.in_time_zone if valid_to.respond_to?(:in_time_zone)

        if valid_to && valid_to <= valid_from
          raise ArgumentError, "valid_to (#{valid_to}) must be greater than valid_from (#{valid_from})"
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
      #   - No-op: Returns true without DB changes if new_valid_from equals current genesis
      #
      # Raises ActiveRecord::RecordNotFound if no current-knowledge records exist.
      # Raises ArgumentError if new_valid_from would erase all segments (>= last valid_to).
      #
      # @param new_valid_from [Time, Date, String] The new start date for the entity's timeline
      # @return [Boolean] true if successful
      def shift_genesis(new_valid_from:)
        new_valid_from = new_valid_from.in_time_zone if new_valid_from.respond_to?(:in_time_zone)
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
      # Re-terminating earlier works; re-terminating later requires cancel_termination first.
      #
      # @param termination_time [Time, Date, String] When the entity stops being valid
      # @return [Boolean] true if successful
      def terminate(termination_time:)
        termination_time = termination_time.in_time_zone if termination_time.respond_to?(:in_time_zone)
        _terminate_record(termination_time: termination_time)
      end

      # Cancel Termination: Full reversal via transaction history
      #
      # Restores the complete pre-termination timeline by searching backward
      # through transaction history. Recovers ALL segments that were removed
      # during termination.
      #
      # IMPORTANT: This is a full undo — it restores the state from BEFORE the
      # termination, not just the current state with valid_to extended. Any
      # operations performed after termination (corrections, etc.) are lost.
      #
      # No-op if entity is not currently terminated.
      #
      # @raise [ActiveRecord::RecordNotFound] if no current-knowledge records exist
      # @raise [ActiveRecord::Bitemporal::PreTerminationStateNotFoundError] if
      #   transaction history cannot determine the pre-termination state
      # @return [Boolean] true if successful
      def cancel_termination
        _cancel_termination_record
      end

      # Predicate: Is this entity's timeline terminated (finite end)?
      #
      # @return [Boolean] true if last segment's valid_to < DEFAULT_VALID_TO
      def terminated?
        last_valid_to = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .order(valid_from_key => :desc)
          .pick(valid_to_key)
        return false if last_valid_to.nil?
        last_valid_to < ActiveRecord::Bitemporal::DEFAULT_VALID_TO
      end

      # Cancel Shift Genesis: Full reversal via transaction history
      #
      # Restores the complete pre-shift timeline by searching backward through
      # transaction history. Recovers ALL segments removed during a forward shift.
      #
      # IMPORTANT: This is a full undo — it restores the state from BEFORE the
      # most recent genesis change. Any operations performed after the shift
      # (corrections, updates, etc.) are lost.
      #
      # No-op if the genesis has never been shifted (matches original creation).
      #
      # @raise [ActiveRecord::RecordNotFound] if no current-knowledge records exist
      # @raise [ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError] if
      #   transaction history cannot determine the pre-shift state
      # @return [Boolean] true if successful
      def cancel_shift_genesis
        _cancel_shift_genesis_record
      end

      # Predicate: Has this entity's genesis been shifted from its original value?
      #
      # @return [Boolean] true if current genesis differs from original creation genesis
      def shifted_genesis?
        current_genesis = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
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

      def bitemporal_business_attributes(record)
        excluded = BITEMPORAL_INFRASTRUCTURE_COLUMNS + [valid_from_key, valid_to_key]
        record.attributes.except(*excluded)
      end

      def coalesce_adjacent_segments!(current_time)
        segments = find_all_current_knowledge_segments
        return if segments.size < 2

        segments.drop(1).each_with_object([segments.first]) do |segment, acc|
          if acc.last[valid_to_key] == segment[valid_from_key] &&
             bitemporal_business_attributes(acc.last) == bitemporal_business_attributes(segment)
            earlier = acc.last

            # Build merged record spanning both ranges
            merged = timeline_dup(earlier)
            merged.id = nil
            merged[valid_to_key] = segment[valid_to_key]
            merged.transaction_from = current_time
            merged.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO

            # Close both originals, then insert merged record
            timeline_close(earlier, current_time)
            timeline_close(segment, current_time)
            merged.save_without_bitemporal_callbacks!(validate: false)

            # Replace last accumulated with merged for chain handling
            merged.id = merged.swapped_id
            merged.clear_changes_information
            acc[-1] = merged
          else
            acc << segment
          end
        end
      end

      # Serializes writes to this entity's timeline until the surrounding transaction ends.
      #
      # 1. A transaction-scoped advisory lock on (table_name, bitemporal_id), built exactly
      #    like dsptch-api's Bitemporal::Methods.lock_family!, so the two are one lock: app
      #    code holding lock_family! and these operations wait for each other, and an
      #    operation called under lock_family! re-enters it instead of deadlocking. Unlike a
      #    row lock it holds even when the entity has no row valid now. Keep the key in sync
      #    with the app.
      # 2. FOR UPDATE on every current-knowledge row, not just the one valid now. Upstream's
      #    save and destroy lock rows but never take the advisory lock, so this makes an
      #    upstream write already in flight on any of these rows commit before this
      #    operation reads the timeline.
      #
      # Not covered: an upstream save or destroy on an entity with no row valid now. Its own
      # lock covers no rows, so it can read the timeline before this operation commits and
      # write after. The app closes that by wrapping such writes in lock_family!.
      def lock_timeline!
        keys = [self.class.table_name, bitemporal_id.to_s].map { |value|
          Arel::Nodes::NamedFunction.new("hashtext", [Arel::Nodes.build_quoted(value)])
        }
        lock = Arel::Nodes::NamedFunction.new("pg_advisory_xact_lock", keys)
        self.class.connection.execute(Arel::SelectManager.new.project(lock).to_sql)

        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .lock!
          .pluck(:id)
      end

      # Shared skeleton of the five timeline operations.
      #
      # Owns the steps every operation repeats: transaction, lock, timestamp, close,
      # insert, coalesce, validate and repointing self. The block does the op-specific
      # part (fetch, guards, build): it receives current_time and returns
      # [records_to_close, new_records]. Raising in the block, or a `return` from the
      # calling op (its no-op exits), leaves the transaction before any write.
      #
      # current_time is read only once the locks are held, so it is later than every write
      # that committed while this operation waited for them.
      #
      # Kept exactly as each op behaved before this was extracted, to be changed here
      # in one place later:
      # - self only gets its ids and time columns copied from the segment it points at
      # - when no segment covers now, self points at all_current.public_send(repoint_fallback):
      #   :last for every op except cancel_shift_genesis, which passes :first
      def perform_timeline_operation(repoint_fallback: :last)
        ActiveRecord::Base.transaction(requires_new: true) do
          lock_timeline!
          current_time = Time.current

          # Fetch, guard and build (op-specific)
          records_to_close, new_records = yield(current_time)

          # CLOSE old records FIRST (critical ordering)
          records_to_close.each do |record|
            timeline_close(record, current_time)
          end

          # Insert new records
          new_records.each do |record|
            record.save_without_bitemporal_callbacks!(validate: false)
          end

          # Coalesce adjacent identical segments
          coalesce_adjacent_segments!(current_time)

          # Validate the new timeline (post-hoc)
          validate_cascade_correction_timeline!

          # Update self to point at the currently-valid record, else the fallback.
          # Query DB since untouched segments aren't in new_records
          all_current = find_all_current_knowledge_segments
          current_record = all_current.find { |r|
            r[valid_from_key] <= Time.current && r[valid_to_key] > Time.current
          } || all_current.public_send(repoint_fallback)

          @_swapped_id_previously_was = swapped_id
          @_swapped_id = current_record.swapped_id
          self[valid_from_key] = current_record[valid_from_key]
          self[valid_to_key] = current_record[valid_to_key]
          self.transaction_from = current_record.transaction_from
          self.transaction_to = current_record.transaction_to

          true
        end
      end

      # Cascade Correction: Main implementation
      def _correct_record(valid_from:, valid_to:, attributes:)
        perform_timeline_operation do |current_time|
          # 1. Find all affected records (current knowledge, from valid_from onward)
          affected_records = find_affected_records_for_correction(valid_from)

          # Check if any record actually contains valid_from
          # (valid_from must fall within an existing record's valid time range)
          containing_record = affected_records.find { |r|
            r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
          }

          if containing_record.nil?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} at #{valid_from}",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          # 2. Determine effective valid_to (for unbounded corrections)
          effective_valid_to = valid_to || determine_correction_end(valid_from, affected_records)

          # Guard: correction must not extend past the entity's timeline end
          #
          # A terminated (or shift-genesis-truncated) entity has a finite valid_to on
          # its last segment. Allowing a bounded correction to specify a valid_to
          # beyond that point would silently "un-terminate" the entity — extending
          # its lifetime without going through cancel_termination.
          #
          #   Timeline:  |---A---|---B---|  (terminated at T)
          #   Correction:        |---X-------->|  ← valid_to past T — REJECTED
          #
          # Unbounded corrections (no explicit valid_to) are safe — they inherit the
          # containing record's valid_to, which already respects the timeline boundary.
          all_segments = find_all_current_knowledge_segments
          timeline_end = all_segments.last[valid_to_key]
          if effective_valid_to > timeline_end
            raise ActiveRecord::Bitemporal::ValidDatetimeRangeError,
              "correction valid_to (#{effective_valid_to}) exceeds timeline end " \
              "(#{timeline_end}). Cancel termination first to extend the timeline."
          end

          # 3. Build the new timeline: [records_to_close, new_timeline]
          bitemporal_build_cascade_correction_records(
            affected_records: affected_records,
            valid_from: valid_from,
            valid_to: effective_valid_to,
            attributes: attributes,
            current_time: current_time
          )
        end
      end

      # Shift Genesis: Main implementation
      def _shift_genesis_record(new_valid_from:)
        perform_timeline_operation do |current_time|
          # 1. Fetch all current-knowledge segments
          segments = find_all_current_knowledge_segments

          # 2. Guard: entity must exist
          if segments.empty?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
              "(no current-knowledge records)",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          genesis = segments.first

          # 3. No-op: same date
          return true if new_valid_from == genesis[valid_from_key]

          # 4. Guard: forward shift must not erase all segments
          if new_valid_from >= segments.last[valid_to_key]
            raise ArgumentError,
              "shift_genesis would erase all segments: new_valid_from (#{new_valid_from}) " \
              ">= last segment valid_to (#{segments.last[valid_to_key]})"
          end

          # 5. Build records to close and new records
          if new_valid_from < genesis[valid_from_key]
            build_genesis_backward_shift(genesis, new_valid_from, current_time)
          else
            build_genesis_forward_shift(segments, new_valid_from, current_time)
          end
        end
      end

      def find_all_current_knowledge_segments
        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .order(valid_from_key => :asc)
          .to_a
          .each { |record|
            record.id = record.swapped_id
            record.clear_changes_information
          }
      end

      def build_genesis_backward_shift(genesis, new_valid_from, current_time)
        new_genesis = timeline_dup(genesis)
        new_genesis.id = nil
        new_genesis[valid_from_key] = new_valid_from
        new_genesis.transaction_from = current_time
        new_genesis.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO

        [[genesis], [new_genesis]]
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

            trimmed = timeline_dup(segment)
            trimmed.id = nil
            trimmed[valid_from_key] = new_valid_from
            trimmed.transaction_from = current_time
            trimmed.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
            new_records << trimmed

          else
            # valid_from >= new_valid_from — untouched, stop
            break
          end
        end

        [records_to_close, new_records]
      end

      # Terminate: Main implementation
      def _terminate_record(termination_time:)
        perform_timeline_operation do |current_time|
          # 1. Fetch all current-knowledge segments
          segments = find_all_current_knowledge_segments

          # 2. Guard: entity must exist
          if segments.empty?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
              "(no current-knowledge records)",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          first_segment = segments.first
          last_segment = segments.last

          # 3. Guard: termination_time must be after timeline start
          if termination_time <= first_segment[valid_from_key]
            raise ArgumentError,
              "termination_time (#{termination_time}) must be greater than " \
              "first segment valid_from (#{first_segment[valid_from_key]})"
          end

          # 4. Guard: termination_time must not exceed timeline end
          if termination_time > last_segment[valid_to_key]
            raise ArgumentError,
              "termination_time (#{termination_time}) exceeds last segment " \
              "valid_to (#{last_segment[valid_to_key]})"
          end

          # 5. No-op: already terminated at this exact time
          return true if termination_time == last_segment[valid_to_key]

          # 6. Build records to close and new records
          build_termination_records(segments, termination_time, current_time)
        end
      end

      # Cancel Termination: Main implementation
      def _cancel_termination_record
        perform_timeline_operation do |current_time|
          # 1. Fetch all current-knowledge segments
          segments = find_all_current_knowledge_segments

          # 2. Guard: entity must exist
          if segments.empty?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
              "(no current-knowledge records)",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          # 3. No-op: not terminated (last segment extends to infinity)
          return true if segments.last[valid_to_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_TO

          # 4. Find pre-termination state via transaction history
          pre_termination_state = find_pre_termination_state
          if pre_termination_state.nil?
            raise PreTerminationStateNotFoundError,
              "Cannot determine pre-termination state for #{self.class} " \
              "with bitemporal_id=#{bitemporal_id}"
          end

          # 5. Close ALL current segments; recreate pre-termination segments with new transaction_from.
          #    Must clear deleted_at because historical records have it set (by timeline_close or
          #    upstream's update_transaction_to), and bitemporal_assign_initialize_value would use it
          #    to overwrite transaction_to during save.
          new_records = pre_termination_state.map do |old_record|
            new_record = timeline_dup(old_record)
            new_record.id = nil
            new_record.transaction_from = current_time
            new_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
            new_record.deleted_at = nil if new_record.class.column_names.include?("deleted_at")
            new_record
          end

          [segments, new_records]
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

            truncated = timeline_dup(segment)
            truncated.id = nil
            truncated[valid_to_key] = termination_time
            truncated.transaction_from = current_time
            truncated.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
            new_records << truncated
          else
            # segment.valid_from >= termination_time — entirely after — CLOSE, no replacement
            records_to_close << segment
          end
        end

        [records_to_close, new_records]
      end

      def find_pre_termination_state
        change_points = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .within_deleted
          .where.not(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .distinct.pluck(:transaction_to)
          .sort.reverse

        change_points.each do |cp|
          state = self.class
            .where(bitemporal_id: bitemporal_id)
            .ignore_valid_datetime
            .within_deleted
            .where(self.class.arel_table[:transaction_from].lt(cp))
            .where(self.class.arel_table[:transaction_to].gteq(cp))
            .order(valid_from_key => :asc)
            .to_a
            .each { |r|
              r.id = r.swapped_id
              r.clear_changes_information
            }

          next if state.empty?
          return state if state.last[valid_to_key] == ActiveRecord::Bitemporal::DEFAULT_VALID_TO
        end

        nil
      end

      # Cancel Shift Genesis: Main implementation
      #
      # Algorithm mirrors _cancel_termination_record (perform_timeline_operation does
      # the lock, close, insert, coalesce, validate and repointing self):
      # 1. Fetch segments → 2. Guard existence → 3. No-op if genesis matches original →
      # 4. Find pre-shift state → 5. Close current, recreate pre-shift
      # Unlike the other ops, self falls back to the *first* segment when none covers now.
      def _cancel_shift_genesis_record
        perform_timeline_operation(repoint_fallback: :first) do |current_time|
          # 1. Fetch all current-knowledge segments
          segments = find_all_current_knowledge_segments

          # 2. Guard: entity must exist
          if segments.empty?
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self.class} with 'bitemporal_id'=#{bitemporal_id} " \
              "(no current-knowledge records)",
              self.class, "bitemporal_id", bitemporal_id
            )
          end

          # 3. No-op: genesis matches original (never shifted, or already canceled)
          current_genesis = segments.first[valid_from_key]
          original_genesis = find_original_genesis
          return true if current_genesis == original_genesis

          # 4. Find pre-shift state via transaction history
          pre_shift_state = find_pre_shift_genesis_state(current_genesis)
          if pre_shift_state.nil?
            raise PreShiftGenesisStateNotFoundError,
              "Cannot determine pre-shift genesis state for #{self.class} " \
              "with bitemporal_id=#{bitemporal_id}"
          end

          # 5. Close ALL current segments; recreate pre-shift segments with new transaction_from.
          #    Must clear deleted_at because historical records have it set (by timeline_close or
          #    upstream's update_transaction_to), and bitemporal_assign_initialize_value would use it
          #    to overwrite transaction_to during save.
          new_records = pre_shift_state.map do |old_record|
            new_record = timeline_dup(old_record)
            new_record.id = nil
            new_record.transaction_from = current_time
            new_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
            new_record.deleted_at = nil if new_record.class.column_names.include?("deleted_at")
            new_record
          end

          [segments, new_records]
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
        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .within_deleted
          .order(transaction_from: :asc, valid_from_key => :asc)
          .pick(valid_from_key)
      end

      # Find the pre-shift state: the most recent complete timeline snapshot where
      # the genesis (first segment's valid_from) differs from current_genesis.
      #
      # == How it works (transaction history search)
      #
      # Every bitemporal mutation closes old records (transaction_to = now) and
      # inserts new ones (transaction_from = now). This creates "change points"
      # — transaction_to values where the timeline was rewritten.
      #
      # We walk backward through change points, reconstructing the timeline that
      # was active just before each change, until we find one with a different
      # genesis:
      #
      #   Transaction time →
      #   ┌─────────────────────────────────────────────────────┐
      #   │ t1: CREATE    |---A---|---B---|---C--->∞             │ genesis = Jan 1
      #   │               └──────────────────────┘              │
      #   │ t2: SHIFT →   closed at t2                          │
      #   │               |---B---|---C--->∞                    │ genesis = Mar 1
      #   │               └──────────────┘                      │
      #   │                                                     │
      #   │ Walking backward from t2:                           │
      #   │   change_point = t2 → reconstruct t1 state          │
      #   │   t1 genesis = Jan 1 ≠ current (Mar 1) → FOUND! ✅  │
      #   └─────────────────────────────────────────────────────┘
      #
      # @param current_genesis [Time] the current first segment's valid_from
      # @return [Array<ActiveRecord::Base>, nil] the pre-shift segment records,
      #   or nil if no prior state with a different genesis can be found
      def find_pre_shift_genesis_state(current_genesis)
        change_points = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .within_deleted
          .where.not(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .distinct.pluck(:transaction_to)
          .sort.reverse

        change_points.each do |cp|
          state = self.class
            .where(bitemporal_id: bitemporal_id)
            .ignore_valid_datetime
            .within_deleted
            .where(self.class.arel_table[:transaction_from].lt(cp))
            .where(self.class.arel_table[:transaction_to].gteq(cp))
            .order(valid_from_key => :asc)
            .to_a
            .each { |r|
              r.id = r.swapped_id
              r.clear_changes_information
            }

          next if state.empty?
          return state if state.first[valid_from_key] != current_genesis
        end

        nil
      end

      def find_affected_records_for_correction(correction_valid_from)
        self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .where("#{valid_to_key} > ?", correction_valid_from)
          .order(valid_from_key => :asc)
          .to_a
          .each { |record|
            record.id = record.swapped_id
            record.clear_changes_information
          }
      end

      def determine_correction_end(correction_valid_from, affected_records)
        # Find the record that contains valid_from
        containing_record = affected_records.find { |r|
          r[valid_from_key] <= correction_valid_from && r[valid_to_key] > correction_valid_from
        }

        if containing_record
          # Correction ends at this record's valid_to (next change point)
          containing_record[valid_to_key]
        else
          # valid_from is in a gap or before all records - use infinity
          ActiveRecord::Bitemporal::DEFAULT_VALID_TO
        end
      end

      def validate_cascade_correction_timeline!
        # Check for overlapping valid times at current transaction time
        records = self.class
          .where(bitemporal_id: bitemporal_id)
          .ignore_valid_datetime
          .where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .order(valid_from_key => :asc)
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

      def bitemporal_build_cascade_correction_records(affected_records:, valid_from:, valid_to:, attributes:, current_time:)
        new_timeline = []

        # Sort by valid_from to process in order
        sorted_records = affected_records.sort_by { |r| r[valid_from_key] }

        # Only close records that overlap the correction range [valid_from, valid_to)
        records_to_close = sorted_records.select { |r| r[valid_from_key] < valid_to }

        # 1. BEFORE: If first affected record starts before valid_from, create trimmed version
        first_record = sorted_records.first
        if first_record && first_record[valid_from_key] < valid_from
          before_record = timeline_dup(first_record)
          before_record.id = nil
          before_record[valid_to_key] = valid_from
          before_record.transaction_from = current_time
          before_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
          new_timeline << before_record
        end

        # 2. CORRECTION: Create the corrected record with new attributes
        # Inherit from the record that contains valid_from (not from self)
        containing_record = sorted_records.find { |r|
          r[valid_from_key] <= valid_from && r[valid_to_key] > valid_from
        }
        correction_record = timeline_dup(containing_record)
        correction_record.id = nil
        correction_record.assign_attributes(attributes)
        correction_record[valid_from_key] = valid_from
        correction_record[valid_to_key] = valid_to
        correction_record.transaction_from = current_time
        correction_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
        new_timeline << correction_record

        # 3. AFTER: Cascade - preserve records that extend past valid_to
        if valid_to < ActiveRecord::Bitemporal::DEFAULT_VALID_TO
          sorted_records.each do |record|
            next unless record[valid_to_key] > valid_to

            if record[valid_from_key] < valid_to
              # Partially overlapped — trim start to valid_to
              after_record = timeline_dup(record)
              after_record.id = nil
              after_record[valid_from_key] = valid_to
              after_record.transaction_from = current_time
              after_record.transaction_to = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO
              new_timeline << after_record
            else
              # Fully after correction — untouched, stop
              break
            end
          end
        end

        [records_to_close, new_timeline.sort_by { |r| r[valid_from_key] }]
      end
    end

    module Persistence
      include TimelineOperations
    end
  end
end
