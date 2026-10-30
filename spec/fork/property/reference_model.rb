# frozen_string_literal: true

module ForkProperty
  INF = ActiveRecord::Bitemporal::DEFAULT_VALID_TO
  TT_INF = ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO

  # One version of an entity: its business attributes over [from, to) in valid time
  Segment = Struct.new(:from, :to, :attrs) do
    def zero_length?
      from == to
    end

    def covers?(time)
      from <= time && time < to
    end
  end

  # The entity's current rows after one write to it, as [row id, segment] pairs, and whether
  # that write closed a row. Only a write that closes rows leaves a change point in
  # transaction history, so those are the writes the cancels walk back through.
  Snapshot = Struct.new(:recorded_at, :rows, :closed_rows) do
    def segments
      rows.map(&:last)
    end
  end

  # What an operation does to the current timeline: the timeline it leaves and the path that
  # got there, or the error it raises. An error is a class: the operation may raise it or a
  # subclass of it, unless it's one of EXACT_ERRORS.
  Outcome = Struct.new(:timeline, :path, :error)

  # The fork's timeline operations as pure functions over the current timeline, a list of
  # segments ordered by valid time. This is the executable description the property harness
  # checks every fork operation against; the comments state the semantics, the code pins
  # them down. A change to an operation's semantics changes its function here in the same PR.
  #
  # Every fork operation works on the segments that hold a time (zero-length rows don't
  # count) and leaves its result normalized: zero-length pieces dropped and equal neighbours
  # merged. Path :noop means the operation's own guard found nothing to do; it may still
  # write, to normalize what an upstream write left.
  #
  # The upstream writes at the end keep the model in step with the background traffic. Their
  # outcomes are only compared, never enforced.
  module ReferenceModel
    module_function

    # The cancels raise these exact classes when nothing can be restored. Their subclasses
    # mean something else: a refusal because changes were recorded since.
    EXACT_ERRORS = [
      ActiveRecord::Bitemporal::PreTerminationStateNotFoundError,
      ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError,
    ].freeze

    def holding_a_time(segments)
      segments.reject(&:zero_length?)
    end

    # A segment ending where the next one starts, with equal attributes, takes over its range
    def merge_equal_neighbours(segments)
      segments.each_with_object([]) { |segment, merged|
        previous = merged.last
        if previous && previous.to == segment.from && previous.attrs == segment.attrs
          merged[-1] = Segment.new(previous.from, segment.to, previous.attrs)
        else
          merged << segment
        end
      }
    end

    def normalize(segments)
      merge_equal_neighbours(holding_a_time(segments))
    end

    def covering(segments, time)
      segments.find { |segment| segment.covers?(time) }
    end

    def done(timeline, path)
      Outcome.new(normalize(timeline), path, nil)
    end

    def raises(error)
      Outcome.new(nil, nil, error)
    end

    # == Fork operations

    # correct(valid_from:, valid_to:, **attributes): a patch over [from, to). Each segment
    # overlapping it keeps its own attributes there, with only the given ones replaced; gaps
    # stay gaps. Without `to`, the patch ends where the segment containing `from` ends, even
    # where the next segment holds equal values.
    def correct(segments, from, to, attributes)
      return raises(ArgumentError) if to && to <= from

      segments = holding_a_time(segments)
      containing = covering(segments, from)
      return raises(ActiveRecord::RecordNotFound) unless containing

      to ||= containing.to
      return raises(ActiveRecord::Bitemporal::ValidDatetimeRangeError) if to > segments.last.to

      patched = false
      timeline = segments.flat_map { |segment|
        next [segment] unless segment.from < to && segment.to > from

        corrected = segment.attrs.merge(attributes)
        next [segment] if corrected == segment.attrs

        patched = true
        [
          (Segment.new(segment.from, from, segment.attrs) if segment.from < from),
          Segment.new([segment.from, from].max, [segment.to, to].min, corrected),
          (Segment.new(to, segment.to, segment.attrs) if segment.to > to),
        ].compact
      }
      done(timeline, patched ? :patch : :noop)
    end

    # terminate(termination_time:): the timeline ends at `at`. Segments after it go, and the
    # one spanning it is cut there. `at` must be after the first segment's start and no later
    # than the current end; at the current end there's nothing to do.
    def terminate(segments, at)
      segments = holding_a_time(segments)
      return raises(ActiveRecord::RecordNotFound) if segments.empty?
      return raises(ArgumentError) if at <= segments.first.from || at > segments.last.to
      return done(segments, :noop) if at == segments.last.to

      timeline = segments.filter_map { |segment|
        if segment.to <= at
          segment
        elsif segment.from < at
          Segment.new(segment.from, at, segment.attrs)
        end
      }
      done(timeline, :truncate)
    end

    # reopen: an edit, not an undo. The last segment continues to infinity with the values it
    # has; whatever a termination removed stays removed.
    def reopen(segments)
      segments = holding_a_time(segments)
      return raises(ActiveRecord::RecordNotFound) if segments.empty?

      last = segments.last
      return done(segments, :noop) if last.to == INF

      done(segments[0...-1] + [Segment.new(last.from, INF, last.attrs)], :reopen)
    end

    # shift_genesis(new_valid_from:): the timeline starts at `to`. Backward, the first segment
    # starts earlier with its values; forward, segments before `to` go and the one spanning it
    # starts there. A shift that would leave nothing raises.
    def shift_genesis(segments, to)
      segments = holding_a_time(segments)
      return raises(ActiveRecord::RecordNotFound) if segments.empty?

      genesis = segments.first
      return done(segments, :noop) if to == genesis.from
      return raises(ArgumentError) if to >= segments.last.to

      if to < genesis.from
        done([Segment.new(to, genesis.to, genesis.attrs), *segments.drop(1)], :backward)
      else
        timeline = segments.filter_map { |segment|
          next if segment.to <= to

          segment.from < to ? Segment.new(to, segment.to, segment.attrs) : segment
        }
        done(timeline, :forward)
      end
    end

    # cancel_termination: an undo. Restores the most recent timeline with an infinite end, as
    # it stood before the write that replaced it, and refuses when anything was recorded for
    # the entity after that write. Not terminated, there's nothing to do.
    def cancel_termination(segments, history)
      segments = holding_a_time(segments)
      return raises(ActiveRecord::RecordNotFound) if segments.empty?
      return done(segments, :noop) if segments.last.to == INF

      timeline, write = restorable_timeline(history) { |candidate| candidate.last.to == INF }
      return raises(ActiveRecord::Bitemporal::PreTerminationStateNotFoundError) unless timeline
      return raises(ActiveRecord::Bitemporal::RecordedSinceTerminationError) unless write == history.size - 1

      done(timeline, :restore)
    end

    # cancel_shift_genesis: an undo. Restores the most recent timeline that started at the
    # original genesis, as it stood before the write that replaced it, and refuses when
    # anything was recorded for the entity after that write. At the original genesis, there's
    # nothing to do.
    def cancel_shift_genesis(segments, history, original_genesis)
      segments = holding_a_time(segments)
      return raises(ActiveRecord::RecordNotFound) if segments.empty?
      return done(segments, :noop) if segments.first.from == original_genesis

      timeline, write = restorable_timeline(history) { |candidate| candidate.first.from == original_genesis }
      return raises(ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError) unless timeline
      return raises(ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError) unless write == history.size - 1

      done(timeline, :restore)
    end

    # The timelines a cancel can restore, most recent first: the timeline just before each
    # write that closed rows (each change point), its zero-length rows left out, and a timeline
    # of nothing else skipped. Returns the first one the block accepts, and the index in
    # history of the write that replaced it. Every later write appends to history, so
    # "nothing recorded since" means that write is the last one.
    def restorable_timeline(history)
      (history.size - 1).downto(1) { |write|
        next unless history[write].closed_rows

        timeline = holding_a_time(history[write - 1].segments)
        next if timeline.empty?
        return [timeline, write] if yield(timeline)
      }
      nil
    end

    # The version self is left on after an operation that wrote: the one valid at self's
    # time, else the latest one starting before it, else the first one
    def self_version(segments, at)
      segments = holding_a_time(segments)
      covering(segments, at) || segments.reverse.find { |segment| segment.from <= at } || segments.first
    end

    # == Upstream writes
    #
    # Upstream doesn't normalize, so these results aren't normalized either. A model error of
    # StandardError means only "this raises".

    # update! saved at `target`: the segment covering it is split there, the part from target
    # on taking the record's attributes. At a segment's start it raises. In a gap, a segment
    # from target to the next segment's start is inserted.
    def update(segments, target, attributes)
      containing = covering(segments, target)
      if containing
        return raises(ActiveRecord::Bitemporal::ValidDatetimeRangeError) if containing.from == target

        return Outcome.new(segments.flat_map { |segment|
          next [segment] unless segment.equal?(containing)

          [Segment.new(segment.from, target, segment.attrs), Segment.new(target, segment.to, attributes)]
        }, nil, nil)
      end

      following = segments.find { |segment| segment.from > target }
      return raises(StandardError) unless following

      Outcome.new((segments + [Segment.new(target, following.from, attributes)]).sort_by { |s| [s.from, s.to] }, nil, nil)
    end

    # force_update { save! } on the version covering `from`: replaced in place by [from, to)
    # with the record's attributes
    def force_update(segments, from, to, attributes)
      containing = covering(segments, from)
      return raises(StandardError) unless containing

      Outcome.new(segments.map { |segment|
        segment.equal?(containing) ? Segment.new(from, to, attributes) : segment
      }.sort_by { |s| [s.from, s.to] }, nil, nil)
    end

    # destroy of the version valid at `at`: it ends at `at`
    def destroy(segments, at)
      containing = covering(segments, at)
      return raises(StandardError) unless containing

      Outcome.new(segments.map { |segment|
        segment.equal?(containing) ? Segment.new(segment.from, at, segment.attrs) : segment
      }, nil, nil)
    end
  end
end
