# frozen_string_literal: true

module ForkProperty
  # Deliberate bugs in the fork's timeline operations, to check that the property harness
  # catches them. FORK_PROPERTY_MUTANT=<name> loads this file and prepends that mutant to
  # TimelineOperations at runtime; lib/ is never edited. A mutant acts only inside the
  # property examples (see .enabled), so other specs in the same run see the real operations.
  #
  # Each overrides a private method of lib/activerecord-bitemporal/timeline_operations.rb,
  # some with a copy of part of its body. When one of those methods changes, update or drop
  # its mutant here.
  module Mutants
    class << self
      def install(name)
        mutant = ALL.fetch(name) {
          raise ArgumentError, "FORK_PROPERTY_MUTANT is one of #{ALL.keys.join(', ')}, not #{name.inspect}"
        }
        ActiveRecord::Bitemporal::TimelineOperations.prepend(mutant)
      end

      def enabled
        @enabled = true
        yield
      ensure
        @enabled = false
      end

      def enabled?
        @enabled == true
      end
    end

    # Equal neighbours stay unmerged, so an operation leaves a seam
    module NoMerge
      private

      def merge_equal_neighbours(timeline, current_time)
        Mutants.enabled? ? timeline : super
      end
    end

    # Zero-length rows count as segments: the guards and builders see them, and they're kept
    module ZeroLengthAsSegment
      private

      def zero_length?(record)
        Mutants.enabled? ? false : super
      end
    end

    # The cancels walk change points oldest first, so they find the oldest timeline they
    # could restore instead of the most recent one
    module CancelWalkOldestFirst
      private

      # find_latest_snapshot's walk, with the change points in ascending order
      def find_latest_snapshot
        return super unless Mutants.enabled?

        table = self.class.arel_table
        change_points = timeline_rows
          .where.not(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO)
          .distinct.pluck(:transaction_to)
          .sort
        change_points.each do |change_point|
          state = load_segments(
            timeline_rows
              .where(table[:transaction_from].lt(change_point))
              .where(table[:transaction_to].gteq(change_point))
              .order(valid_from_key => :asc)
          ).reject { |row| zero_length?(row) }
          next if state.empty?
          return [state, change_point] if yield(state)
        end
        nil
      end
    end

    # The cancels never refuse, so they discard what was recorded after the operation they undo
    module NoRecordedSinceGuard
      private

      def recorded_since?(change_point)
        Mutants.enabled? ? false : super
      end
    end

    # Only a row inserted after the change point makes a cancel refuse, not a row only closed
    # after it (as a terminate at a segment boundary closes rows and inserts none)
    module RecordedSinceInsertsOnly
      private

      def recorded_since?(change_point)
        return super unless Mutants.enabled?

        timeline_rows.where(self.class.arel_table[:transaction_from].gt(change_point)).exists?
      end
    end

    # Self is reloaded onto the version valid now, not at its own valid datetime
    module ReloadAtNow
      private

      def reload_onto_timeline
        return super unless Mutants.enabled?

        with_bitemporal_option(valid_datetime: Time.current) { super }
      end
    end

    # A call with nothing to write still reloads self, discarding its unsaved changes
    module NoopReloads
      private

      def timeline_changes(rows, timeline)
        changes = super
        reload_onto_timeline if Mutants.enabled? && changes.all?(&:empty?)
        changes
      end
    end

    # Every current row is closed and every segment recorded again, changed or not
    module RewriteUnchanged
      private

      def timeline_changes(rows, timeline)
        return super unless Mutants.enabled?

        current_time = Time.current
        [rows, timeline.map { |piece| piece.new_record? ? piece : timeline_piece(piece, piece[valid_from_key], piece[valid_to_key], current_time) }]
      end
    end

    # The last piece to insert never is, as if its save did nothing
    module InsertSkipped
      private

      def timeline_changes(rows, timeline)
        records_to_close, new_records = super
        Mutants.enabled? ? [records_to_close, new_records[0...-1]] : [records_to_close, new_records]
      end
    end

    ALL = {
      "no_merge" => NoMerge,
      "zero_length_as_segment" => ZeroLengthAsSegment,
      "cancel_walk_oldest_first" => CancelWalkOldestFirst,
      "no_recorded_since_guard" => NoRecordedSinceGuard,
      "recorded_since_inserts_only" => RecordedSinceInsertsOnly,
      "reload_at_now" => ReloadAtNow,
      "noop_reloads" => NoopReloads,
      "rewrite_unchanged" => RewriteUnchanged,
      "insert_skipped" => InsertSkipped,
    }.freeze
  end
end
