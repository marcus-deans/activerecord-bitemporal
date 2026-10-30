# frozen_string_literal: true

module ForkProperty
  # Valid times are drawn around DAY_ZERO. Transaction time starts at START, inside that range,
  # and each step moves it on by the step's dt seconds, frozen with Timecop.
  DAY_ZERO = Time.utc(2026, 1, 1).in_time_zone
  START = DAY_ZERO + 25.days + 9.hours
  INFRASTRUCTURE_COLUMNS = %w[id type created_at updated_at bitemporal_id transaction_from transaction_to deleted_at].freeze
  FORK_OPERATIONS = %i[correct terminate cancel_termination shift_genesis cancel_shift_genesis reopen].freeze

  def self.day(number)
    DAY_ZERO + number.days
  end

  # One step of a sequence: an operation on entity 0 or 1, dt seconds of transaction time
  # after the previous step. Steps are plain data, so a sequence replays and shrinks.
  #
  # Kinds: :create, the fork operations, the upstream writes (:update on a version loaded at
  # load_at or now, :self_update on self, :destroy and :force_update), and :load_self, which
  # loads self (the record the fork operations are called on) another way. A fork operation's
  # args may also carry :unsaved (attributes assigned to self first), :wrap (a block or scope
  # it's called in) and :time_format (its time passed as a Date or a String).
  Step = Struct.new(:kind, :entity, :dt, :args, keyword_init: true)

  # A stored row. deleted_at is :none when the table has no such column.
  Row = Struct.new(:id, :transaction_from, :transaction_to, :from, :to, :created_at, :deleted_at, :attrs) do
    def segment
      Segment.new(from, to, attrs)
    end

    def live?
      transaction_to == TT_INF
    end
  end

  # A broken property. The signature names the step kind and the check, so shrinking keeps a
  # sequence failing the same way.
  class Failure < StandardError
    attr_reader :signature
    attr_accessor :steps

    def initialize(signature, message)
      @signature = signature
      super(message)
    end
  end

  # The harness's view of one entity: its current timeline, its history and self
  class Entity
    attr_reader :id, :original_genesis, :history, :self_record, :self_valid_datetime, :self_source
    attr_accessor :segments, :last_write

    def initialize(id, original_genesis, segments, snapshot)
      @id = id
      @original_genesis = original_genesis
      @segments = segments
      @history = [snapshot]
    end

    # self is now record, with the valid datetime it holds, as source left it
    def take_self(record, source, valid_datetime: record.valid_datetime)
      @self_record = record
      @self_valid_datetime = valid_datetime
      @self_source = source
      @self_taken_at = history.size
    end

    # Taken since the entity's last write, persisted and with no unsaved changes
    def self_fresh?
      @self_taken_at == history.size && !self_record.changed? && !self_record.new_record?
    end
  end

  module Format
    module_function

    # Days from DAY_ZERO, plus seconds: d3, d25+32400s. INF is the end of valid time.
    def label(time)
      return "nil" if time.nil?

      time = time.in_time_zone
      return "INF" if time == INF

      days, seconds = (time - DAY_ZERO).to_i.divmod(86_400)
      seconds.zero? ? "d#{days}" : "d#{days}+#{seconds}s"
    end

    def attrs(attributes)
      attributes.compact.map { |key, value| "#{key}=#{value.inspect}" }.join(",")
    end

    def segment(segment)
      "[#{label(segment.from)},#{label(segment.to)}){#{attrs(segment.attrs)}}"
    end

    def timeline(segments)
      return "(none)" if segments.nil?

      segments.empty? ? "(empty)" : segments.map { |each| segment(each) }.join(" ")
    end

    def outcome(outcome)
      return "loose" if outcome.nil?
      return "error/#{outcome.error.name.demodulize}" if outcome.error
      return "unchanged" if outcome.path == :unchanged

      outcome.path ? "ok/#{outcome.path}" : "ok"
    end

    # Steps as Ruby, for ForkProperty.replay
    def ruby(steps)
      lines = steps.map { |step|
        "  ForkProperty::Step.new(kind: #{step.kind.inspect}, entity: #{step.entity}, dt: #{step.dt}, args: #{literal(step.args)}),"
      }
      "[\n#{lines.join("\n")}\n]"
    end

    def literal(value)
      case value
      when ActiveSupport::TimeWithZone, Time
        return "ForkProperty::INF" if value == INF

        days, seconds = (value - DAY_ZERO).to_i.divmod(86_400)
        seconds.zero? ? "ForkProperty.day(#{days})" : "ForkProperty.day(#{days}) + #{seconds}"
      when Hash
        value.empty? ? "{}" : "{ #{value.map { |key, each| "#{key}: #{literal(each)}" }.join(', ')} }"
      else
        value.inspect
      end
    end
  end

  # Generates or replays a sequence of steps over one or two entities of a model, running
  # each at its own frozen transaction time and checking it right after.
  #
  # A fork operation must do exactly what ReferenceModel says: the same outcome, a minimal
  # write, and self left on the right version. An upstream write is background traffic: its
  # outcome is only compared with the model, and a difference is logged as a divergence. Every
  # write, upstream ones included, must keep the store's invariants: no rows written when it
  # raises, rows only ever inserted or closed at now, no overlap, and a transaction history
  # that replays to what the timeline was after every earlier write.
  class Runner
    UNCHANGED = Outcome.new(nil, :unchanged, nil)

    attr_reader :log, :stats, :divergences

    # zero_length: lets an upstream destroy at a segment's start leave a zero-length row, and
    #   stops comparing upstream writes with the model while the timeline holds one
    # seams: biases upstream writes towards leaving equal neighbours
    # values: the values generated attributes take, by column (not needed to replay)
    # check_seed: seeds the checks that sample snapshots and times
    def initialize(model, zero_length: false, seams: false, values: nil, check_seed: 0)
      @model = model
      @valid_from = model.valid_from_key
      @valid_to = model.valid_to_key
      @business = model.column_names - INFRASTRUCTURE_COLUMNS - [@valid_from, @valid_to]
      @has_deleted_at = model.column_names.include?("deleted_at")
      @date_column = model.type_for_attribute(@valid_from).type == :date
      @zero_length = zero_length
      @seams = seams
      @values = values
      @check_rng = Random.new(check_seed)
      @log = []
      @stats = Hash.new(0)
      @divergences = []
    end

    # Runs the given steps. Returns the steps that ran; a Failure carries them.
    def run(steps)
      run_steps { |index| steps[index] }
    end

    # Generates `steps` steps, each from the state the previous ones left, over up to
    # `entities` entities
    def run_generated(rng, steps:, entities:)
      run_steps { |index| generate_step(rng, entities) if index < steps }
    end

    private

    def run_steps
      @entities = []
      @now = START
      executed = []
      index = 0
      while (step = yield(index))
        index += 1
        # A shrunk sequence can lose the create a step needs
        next if step.kind == :create ? step.entity != @entities.size : step.entity >= @entities.size

        executed << step
        @now += step.dt
        Timecop.freeze(@now) { execute(step, executed.size) }
      end
      executed
    rescue Failure => failure
      failure.steps = executed
      raise
    end

    # ==== Generation

    def generate_step(rng, entities_wanted)
      dt = [1, 1, 30, 3600, rng.rand(1..21_600)].sample(random: rng)
      if @entities.empty? || (@entities.size < entities_wanted && rng.rand < 0.25)
        return Step.new(kind: :create, entity: @entities.size, dt: dt, args: generate_create(rng))
      end

      index = @entities.size > 1 && rng.rand < 0.5 ? 1 : 0
      entity = @entities[index]
      segments = entity.segments
      young = entity.history.size < 4
      # A cancel only succeeds right after the operation it undoes, so that case is boosted
      weights = {
        correct: 26, terminate: 9, cancel_termination: entity.last_write == :terminate ? 30 : 7,
        reopen: 8, shift_genesis: 10, cancel_shift_genesis: entity.last_write == :shift_genesis ? 30 : 6,
        update: young ? 60 : 18, self_update: 4, destroy: 5, force_update: 5, load_self: 8,
      }
      kind = weighted(rng, weights)
      unsaved = FORK_OPERATIONS.include?(kind) && rng.rand < 0.15 ? random_attrs(rng, 1) : nil
      args =
        case kind
        when :correct
          from = pick_time(rng, segments)
          roll = rng.rand
          to =
            if roll < 0.4 then nil
            elsif roll < 0.47 then INF
            elsif roll < 0.51 then from - rng.rand(0..2).days
            else
              other = pick_time(rng, segments)
              other > from ? other : from + rng.rand(1..8).days
            end
          # Sometimes the values the segment already holds, for a correction that changes nothing
          attrs =
            if rng.rand < 0.25 && (containing = ReferenceModel.covering(segments, from))
              containing.attrs.slice(*@values.keys.sample(rng.rand(1..[2, @values.size].min), random: rng)).transform_keys(&:to_sym)
            else
              random_attrs(rng)
            end
          { from: from, to: to, attrs: attrs }
        when :terminate
          roll = rng.rand
          at =
            if roll < 0.1 then segments.last.to
            elsif roll < 0.15 then segments.first.from - rng.rand(0..2).days
            else pick_time(rng, segments)
            end
          { at: at }
        when :shift_genesis
          roll = rng.rand
          to =
            if roll < 0.35 then segments.first.from - rng.rand(1..10).days
            elsif roll < 0.42 then segments.first.from
            else pick_time(rng, segments)
            end
          { to: to }
        when :cancel_termination, :cancel_shift_genesis, :reopen
          {}
        when :update
          at = pick_time(rng, segments)
          roll = rng.rand
          if roll < 0.12 && !@date_column
            { at: nil, load_at: nil, attrs: random_attrs(rng) }
          elsif ReferenceModel.covering(segments, at)
            { at: nil, load_at: at, attrs: random_attrs(rng) }
          else
            # Into a gap: loaded at some version, saved inside valid_at(at)
            { at: at, load_at: segments.sample(random: rng).from, attrs: random_attrs(rng) }
          end
        when :self_update
          { at: rng.rand < 0.5 && !@date_column ? nil : pick_time(rng, segments), attrs: random_attrs(rng) }
        when :destroy
          segment = segments.sample(random: rng)
          days = segment.to == INF ? 10 : ((segment.to - segment.from) / 1.day).floor
          at_start = @zero_length && rng.rand < 0.25
          return generate_step(rng, entities_wanted) if days < 2 && !at_start

          { at: at_start ? segment.from : segment.from + rng.rand(1..[days - 1, 10].min).days }
        when :force_update
          segment = segments.sample(random: rng)
          if @seams && rng.rand < 0.6 && (neighbour = seam_neighbour(rng, segments, segment))
            { at: segment.from, attrs: neighbour }
          else
            { at: segment.from, attrs: random_attrs(rng) }
          end
        when :load_self
          roll = rng.rand
          if roll < 0.35 then { how: :find_at_time, at: pick_time(rng, segments) }
          elsif roll < 0.5 then { how: :find_at_time, at: segments.sample(random: rng).from }
          elsif roll < 0.62 then { how: :find }
          elsif roll < 0.72 then { how: :latest_version }
          elsif roll < 0.8 then { how: :first_version }
          elsif roll < 0.86 then { how: :new_record }
          elsif roll < 0.94 then { how: :past_transaction, at: pick_time(rng, segments), tx: entity.history.sample(random: rng).recorded_at }
          else { how: :closed_row, pick: rng.rand(1000) }
          end
        end
      if @seams && kind == :update && rng.rand < 0.6
        # The update splits the segment covering its target: give the new part the next segment's values
        containing = ReferenceModel.covering(segments, args[:at] || args[:load_at] || @now)
        following = containing && segments.find { |segment| segment.from == containing.to && !segment.zero_length? }
        args[:attrs] = following.attrs.slice(*@values.keys).transform_keys(&:to_sym) if following
      end
      args[:unsaved] = unsaved if unsaved
      if FORK_OPERATIONS.include?(kind) && rng.rand < 0.35
        wraps = %i[transaction_at valid_at bitemporal_at forced scoping ignore_valid_datetime ignore_transaction_datetime]
        args[:wrap] = [wraps.sample(random: rng), rng.rand(100), rng.rand(0..60)]
      end
      if FORK_OPERATIONS.include?(kind) && rng.rand < 0.2
        args[:time_format] = rng.rand < 0.5 ? :date : :string
      end
      Step.new(kind: kind, entity: index, dt: dt, args: args)
    end

    def generate_create(rng)
      from = ForkProperty.day(rng.rand(0..30))
      to = rng.rand < 0.12 ? from + rng.rand(5..30).days : nil
      { from: from, to: to, attrs: @values.keys.to_h { |key| [key.to_sym, @values[key].sample(random: rng)] } }
    end

    # Mostly the timeline's own boundaries, near them or inside segments; sometimes any day,
    # the end of valid time, or now
    def pick_time(rng, segments)
      bounds = segments.flat_map { |segment| [segment.from, segment.to] }.uniq.reject { |time| time == INF }
      roll = rng.rand
      if roll < 0.35
        bounds.sample(random: rng)
      elsif roll < 0.5
        bounds.sample(random: rng) + rng.rand(-3..3).days
      elsif roll < 0.75
        segment = segments.sample(random: rng)
        days = segment.to == INF ? 10 : ((segment.to - segment.from) / 1.day).floor
        segment.from + rng.rand(0..[days, 10].min).days
      elsif roll < 0.9
        ForkProperty.day(rng.rand(-5..65))
      elsif roll < 0.92
        INF
      else
        rng.rand < 0.5 && !@date_column ? @now : @now.beginning_of_day
      end
    end

    def random_attrs(rng, count = nil)
      keys = @values.keys.sample(count || rng.rand(1..[2, @values.size].min), random: rng)
      keys.to_h { |key| [key.to_sym, @values[key].sample(random: rng)] }
    end

    # The values of a segment next to segment, to write a seam
    def seam_neighbour(rng, segments, segment)
      neighbours = segments.select { |other|
        !other.equal?(segment) && !other.zero_length? && (other.to == segment.from || other.from == segment.to)
      }
      neighbour = neighbours.sample(random: rng)
      neighbour && neighbour.attrs.slice(*@values.keys).transform_keys(&:to_sym)
    end

    def weighted(rng, weights)
      roll = rng.rand(weights.values.sum)
      weights.each { |kind, weight| return kind if (roll -= weight) < 0 }
    end

    def describe(step)
      args = step.args
      label = ->(time) { Format.label(time) }
      text =
        case step.kind
        when :create then "create(#{label.(args[:from])}..#{label.(args[:to])}, #{args[:attrs].inspect})"
        when :correct then "correct(valid_from: #{label.(args[:from])}, valid_to: #{label.(args[:to])}, #{args[:attrs].inspect})"
        when :terminate then "terminate(#{label.(args[:at])})"
        when :shift_genesis then "shift_genesis(#{label.(args[:to])})"
        when :cancel_termination, :cancel_shift_genesis, :reopen then step.kind.to_s
        when :update
          "update!(#{args[:attrs].inspect}) on X loaded at #{args[:load_at] ? label.(args[:load_at]) : 'now'}" \
            "#{" inside X.valid_at(#{label.(args[:at])})" if args[:at]}"
        when :self_update then "self.update!(#{args[:attrs].inspect})#{" inside self.valid_at(#{label.(args[:at])})" if args[:at]}"
        when :destroy then "destroy X loaded at #{label.(args[:at])}"
        when :force_update then "force_update { update!(#{args[:attrs].inspect}) } on X loaded at #{label.(args[:at])}"
        when :load_self then "self = #{args[:how]}#{" #{label.(args[:at])}" if args[:at]}"
        end
      text += " with self.attributes = #{args[:unsaved].inspect}" if args[:unsaved]
      text += " inside #{args[:wrap].first}" if args[:wrap]
      text += " (time as a #{args[:time_format]})" if args[:time_format]
      "e#{step.entity} +#{step.dt}s #{text}"
    end

    # ==== Execution

    def execute(step, number)
      @stats["kind:#{step.kind}"] += 1
      description = describe(step)
      return create(step, number, description) if step.kind == :create

      entity = @entities[step.entity]
      return load_self(entity, step.args, number, description) if step.kind == :load_self

      fork = FORK_OPERATIONS.include?(step.kind)
      before = all_rows
      before_raw = raw_rows if fork
      segments = entity.segments
      record = entity.self_record
      record.assign_attributes(step.args[:unsaved]) if step.args[:unsaved]
      self_before = self_state(record)
      self_fresh = entity.self_fresh?
      self_range = [record[@valid_from]&.in_time_zone, record[@valid_to]&.in_time_zone]
      # Past what the model describes for upstream writes
      loose = @zero_length && segments.any?(&:zero_length?)

      performed = fork ? perform_fork_operation(entity, step) : perform_upstream_write(entity, step)
      if performed.is_a?(String)
        @log << "#{number}. #{description}  => SKIPPED (#{performed})"
        @stats["skipped"] += 1
        return
      end

      expected, result, error, target = performed
      after = all_rows
      after_raw = raw_rows if fork
      timeline = current(after[entity.id]).map(&:segment)
      outcome = error ? "RAISE #{error.class}" : (after == before ? "nowrite" : "write")
      @log << "#{number}. #{description}  => #{outcome} #{error ? error.message[0, 120] : Format.timeline(timeline)}"
      @stats["#{step.kind}:#{Format.outcome(expected)}"] += 1
      if fork && !error
        @stats["#{step.kind}:returned_#{after == before ? 'nowrite' : 'write'}"] += 1
        @stats["normalizing_write:#{step.kind}"] += 1 if expected.path == :noop && after != before
        zero_length_rows = current(before[entity.id]).count { |row| row.from == row.to }
        @stats["zero_length_rows_closed:#{step.kind}"] += zero_length_rows if zero_length_rows > 0
      end

      context = -> { "\n  op: #{description}\n  before: #{Format.timeline(segments)}\n  after:  #{Format.timeline(timeline)}" }

      if loose
        @stats["#{fork ? 'zero_length_exact' : 'zero_length_loose'}:#{step.kind}"] += 1
        expected = error ? ReferenceModel.raises(StandardError) : nil unless fork
      end
      if fork
        check_fork_operation(step, entity, expected, result, error, before, after, self_before, before_raw, after_raw, context)
      else
        if step.kind == :self_update && self_fresh && expected&.timeline && self_range[0] <= target && target < self_range[1]
          check_self_update(entity, expected, error, after, context)
        end
        check_upstream_write(step, entity, expected, error, before, after, context)
      end

      returned = fork && !error
      check_rows(entity, before, after, step.kind, context)
      check_current_timeline(entity, after, returned && step.kind, context)
      record_writes(entity, step.kind, before, after)
      @entities.each { |each_entity| check_history(each_entity, after[each_entity.id], context) }
      if returned && after != before
        entity.take_self(record, :operation, valid_datetime: entity.self_valid_datetime)
      elsif step.kind == :self_update && !error
        entity.take_self(record, :self_update, valid_datetime: entity.self_valid_datetime)
      end
      check_predicates(entity)
      check_point_queries(entity)
    end

    def create(step, number, description)
      args = step.args
      record = @model.create!(cast(args[:attrs]).merge(@valid_from => args[:from], @valid_to => args[:to] || INF))
      timeline = [Segment.new(args[:from], args[:to] || INF, full_attrs(args[:attrs]))]
      live = current(rows(record.bitemporal_id))
      entity = Entity.new(record.bitemporal_id, args[:from], timeline, snapshot(live, false))
      entity.take_self(record, :create)
      @entities << entity
      @log << "#{number}. #{description}  => #{Format.timeline(timeline)}"
      fail!("create:timeline", "create wrote #{Format.timeline(live.map(&:segment))}") unless live.map(&:segment) == timeline
    end

    def load_self(entity, args, number, description)
      record =
        case args[:how]
        when :find_at_time then @model.find_at_time(args[:at], entity.id)
        when :find then @model.find_by(bitemporal_id: entity.id)
        when :latest_version then @model.ignore_valid_datetime.where(bitemporal_id: entity.id).order(@valid_from => :desc).first
        when :first_version then @model.ignore_valid_datetime.where(bitemporal_id: entity.id).order(@valid_from => :asc).first
        when :new_record then @model.new(bitemporal_id: entity.id)
        when :past_transaction then ActiveRecord::Bitemporal.transaction_at(args[:tx]) { @model.find_at_time(args[:at], entity.id) }
        when :closed_row
          closed = @model.unscoped.where(bitemporal_id: entity.id).where.not(transaction_to: TT_INF)
            .where("transaction_from < transaction_to").order(:id).to_a
          closed[args[:pick] % closed.size] unless closed.empty?
        end
      record ||= @model.ignore_valid_datetime.where(bitemporal_id: entity.id).order(@valid_from => :asc).first
      entity.take_self(record, :load)
      @log << "#{number}. #{description}  => self@#{Format.label(record[@valid_from])} valid_datetime=#{Format.label(entity.self_valid_datetime)}"
      check_predicates(entity)
    end

    # Returns [expected outcome, result, error raised]
    def perform_fork_operation(entity, step)
      args = step.args
      segments = entity.segments
      record = entity.self_record
      expected =
        case step.kind
        when :correct then ReferenceModel.correct(segments, args[:from], args[:to], cast(args[:attrs]))
        when :terminate then ReferenceModel.terminate(segments, args[:at])
        when :shift_genesis then ReferenceModel.shift_genesis(segments, args[:to])
        when :cancel_termination then ReferenceModel.cancel_termination(segments, entity.history)
        when :cancel_shift_genesis then ReferenceModel.cancel_shift_genesis(segments, entity.history, entity.original_genesis)
        when :reopen then ReferenceModel.reopen(segments)
        end
      time = ->(value) { passed_as(value, args[:time_format]) }
      @wrap_valid_datetime = nil
      @wrap_forced = false
      result = error = nil
      begin
        result = within(entity, args[:wrap]) {
          case step.kind
          when :correct
            if args[:to]
              record.correct(valid_from: time.(args[:from]), valid_to: time.(args[:to]), **args[:attrs])
            else
              record.correct(valid_from: time.(args[:from]), **args[:attrs])
            end
          when :terminate then record.terminate(termination_time: time.(args[:at]))
          when :shift_genesis then record.shift_genesis(new_valid_from: time.(args[:to]))
          else record.public_send(step.kind)
          end
        }
      rescue => error
      end
      [expected, result, error]
    end

    # Returns [expected outcome, result, error raised, the valid time the write targets], or
    # why it was skipped
    def perform_upstream_write(entity, step)
      args = step.args
      segments = entity.segments
      target = nil
      case step.kind
      when :update, :self_update
        if step.kind == :update
          record = args[:load_at] ? @model.find_at_time(args[:load_at], entity.id) : @model.find_by(bitemporal_id: entity.id)
          return "nothing to load" unless record
        else
          record = entity.self_record
          return "self is a new record or a closed row" if record.new_record? || record.transaction_to != TT_INF
        end
        target = args[:at] || record.valid_datetime || @now
        record.assign_attributes(args[:attrs])
        expected = record.changed? ? ReferenceModel.update(segments, target, business_attrs(record)) : UNCHANGED
        write = -> { args[:at] ? record.valid_at(args[:at]) { record.save! } : record.save! }
      when :destroy
        record = @model.find_at_time(args[:at], entity.id)
        return "nothing to load" unless record

        expected = ReferenceModel.destroy(segments, args[:at])
        write = -> { record.destroy or raise "destroy returned false" }
      when :force_update
        record = @model.find_at_time(args[:at], entity.id)
        return "nothing to load" unless record

        record.assign_attributes(args[:attrs])
        range = [record[@valid_from]&.in_time_zone, record[@valid_to]&.in_time_zone]
        expected = record.changed? ? ReferenceModel.force_update(segments, *range, business_attrs(record)) : UNCHANGED
        write = -> { record.force_update { record.save! } }
      end
      result = error = nil
      begin
        result = write.call
      rescue => error
      end
      [expected, result, error, target]
    end

    # Runs the block inside the block or scope a fork operation is called in. Notes the valid
    # datetime it gives self, and whether it's forced, for the check of self.
    def within(entity, wrap, &block)
      return yield unless wrap

      kind, snapshot, day = wrap
      transaction_time = entity.history[snapshot % entity.history.size].recorded_at
      valid_time = ForkProperty.day(day)
      case kind
      when :transaction_at
        ActiveRecord::Bitemporal.transaction_at(transaction_time, &block)
      when :valid_at
        @wrap_valid_datetime = valid_time
        ActiveRecord::Bitemporal.valid_at(valid_time, &block)
      when :bitemporal_at
        @wrap_valid_datetime = transaction_time
        ActiveRecord::Bitemporal.bitemporal_at(transaction_time, &block)
      when :forced
        @wrap_valid_datetime = valid_time
        @wrap_forced = true
        ActiveRecord::Bitemporal.valid_at!(valid_time) { ActiveRecord::Bitemporal.transaction_at!(transaction_time, &block) }
      when :scoping
        # A scope that matches no row
        @model.where(@business.first => "zzz").scoping(&block)
      when :ignore_valid_datetime
        ActiveRecord::Bitemporal.ignore_valid_datetime(&block)
      when :ignore_transaction_datetime
        ActiveRecord::Bitemporal.ignore_transaction_datetime(&block)
      end
    end

    # A time as a caller may pass it: a Date at midnight, or a String
    def passed_as(time, format)
      return time if time.nil? || format.nil?

      if format == :date && time == time.beginning_of_day
        time.to_date
      elsif format == :string
        time.utc.strftime("%Y-%m-%d %H:%M:%S")
      else
        time
      end
    end

    # Appends a snapshot to the history of each entity the step wrote to
    def record_writes(entity, kind, before, after)
      @entities.each { |each_entity|
        next if before[each_entity.id] == after[each_entity.id]

        each_entity.last_write = each_entity.equal?(entity) ? kind : :other
        live = current(after[each_entity.id])
        each_entity.segments = live.map(&:segment)
        live_before = before[each_entity.id].select(&:live?).map(&:id)
        closed = after[each_entity.id].any? { |row| live_before.include?(row.id) && !row.live? }
        each_entity.history << snapshot(live, closed)
      }
    end

    def snapshot(live, closed)
      Snapshot.new(@now, live.map { |row| [row.id, row.segment] }, closed)
    end

    # ==== Checks

    def fail!(signature, message)
      raise Failure.new(signature, message)
    end

    def check_fork_operation(step, entity, expected, result, error, before, after, self_before, before_raw, after_raw, context)
      kind = step.kind
      record = entity.self_record
      if expected.error
        fail!("#{kind}:succeeded", "expected #{expected.error}, got success#{context.()}") unless error
        right_error =
          if ReferenceModel::EXACT_ERRORS.include?(expected.error)
            error.instance_of?(expected.error)
          else
            error.is_a?(expected.error)
          end
        fail!("#{kind}:wrong_error", "expected #{expected.error}, got #{error.class}: #{error.message}#{context.()}") unless right_error
        # Raising leaves the history byte-identical and self alone
        fail!("#{kind}:raised_and_wrote", "raised #{error.class} but wrote rows#{context.()}") unless after == before && after_raw == before_raw
        fail!("#{kind}:raised_and_moved_self", "raised #{error.class} but self changed#{context.()}") unless self_state(record) == self_before
        return
      end
      if error
        fail!("#{kind}:raised", "raised #{error.class}: #{error.message}\n#{error.backtrace.first(4).join("\n")}#{context.()}\n  want:   #{Format.timeline(expected.timeline)}")
      end
      fail!("#{kind}:returned", "returned #{result.inspect}#{context.()}") unless result == true

      live = current(after[entity.id])
      want = expected.timeline
      fail!("#{kind}:timeline", "timeline mismatch#{context.()}\n  want:   #{Format.timeline(want)}") unless live.map(&:segment) == want

      # Only what changes is written: a current row (zero-length ones included) whose segment
      # the result holds keeps its row, every other one is closed, and only the result's
      # other segments are inserted
      live_before = current(before[entity.id])
      after_by_id = after[entity.id].to_h { |row| [row.id, row] }
      closed = live_before.reject { |row| after_by_id[row.id].live? }.map(&:id).sort
      want_closed = live_before.reject { |row| want.include?(row.segment) }.map(&:id).sort
      inserted = live.select { |row| row.transaction_from == @now }.map(&:segment)
      want_inserted = want - live_before.map(&:segment)
      unless closed == want_closed && inserted.sort_by(&:from) == want_inserted.sort_by(&:from)
        fail!("#{kind}:not_minimal",
          "closed #{closed} want #{want_closed}; inserted #{Format.timeline(inserted)} want #{Format.timeline(want_inserted)}#{context.()}")
      end

      if want_closed.empty? && want_inserted.empty?
        # Nothing to write: writes nothing, not even updated_at, and leaves self alone
        fail!("#{kind}:wrote_with_nothing_to_write", "history changed#{context.()}") unless after == before && after_raw == before_raw
        unless self_state(record) == self_before
          fail!("#{kind}:moved_self_with_nothing_to_write", "self changed: #{self_before[0]} -> #{record.swapped_id}#{context.()}")
        end
        return
      end

      check_self_after_operation(entity, live, kind, context)
    end

    # Self is left as reload would leave it, on the version ReferenceModel.self_version picks
    # at self's valid datetime (a forced valid_at! wins over it, a plain valid_at doesn't)
    def check_self_after_operation(entity, live, kind, context)
      record = entity.self_record
      at = (@wrap_forced ? @wrap_valid_datetime : (entity.self_valid_datetime || @wrap_valid_datetime)) || @now
      version = ReferenceModel.self_version(live.map(&:segment), at)
      unless version
        fail!("#{kind}:self_without_version",
          "no current version left, self on #{record.swapped_id} [#{Format.label(record[@valid_from])},#{Format.label(record[@valid_to])})#{context.()}")
      end

      row = live.find { |each| each.from == version.from && each.to == version.to }
      unless record.swapped_id == row.id
        fail!("#{kind}:self_version",
          "self on #{record.swapped_id} [#{Format.label(record[@valid_from])},#{Format.label(record[@valid_to])}) " \
          "want #{row.id} #{Format.segment(row.segment)} (at #{Format.label(at)})#{context.()}")
      end
      fresh = @model.unscoped.where(id: row.id).first
      unless record.attributes == fresh.attributes
        differ = record.attributes.reject { |key, value| fresh.attributes[key] == value }.keys
        fail!("#{kind}:self_attributes",
          "self's attributes differ from a fresh load in #{differ}: #{record.attributes.slice(*differ)} vs #{fresh.attributes.slice(*differ)}#{context.()}")
      end
      fail!("#{kind}:self_changed", "self.changed? after the operation: #{record.changes}#{context.()}") if record.changed?
      unless record.valid_datetime == entity.self_valid_datetime
        fail!("#{kind}:self_valid_datetime",
          "self.valid_datetime moved #{Format.label(entity.self_valid_datetime)} -> #{Format.label(record.valid_datetime)}#{context.()}")
      end
      fail!("#{kind}:self_not_persisted", "self not persisted#{context.()}") unless record.persisted?
      fail!("#{kind}:self_saved_changes", "self.saved_changes after the operation: #{record.saved_changes}#{context.()}") unless record.saved_changes.empty?
    end

    # self.update! on a self an operation left, inside its own range, behaves as on a freshly
    # loaded record. Upstream's own divergences on a fresh self are only counted.
    def check_self_update(entity, expected, error, after, context)
      return unless error || current(after[entity.id]).map(&:segment) != expected.timeline

      @stats["self_update_diverged_after:#{entity.self_source}"] += 1
      return unless entity.self_source == :operation

      fail!("self_update:after_operation",
        "self left by an operation (valid_datetime #{Format.label(entity.self_valid_datetime)}), " \
        "update! #{error ? "raised #{error.class}: #{error.message}" : 'wrote something else'}#{context.()}\n" \
        "  model:  #{Format.timeline(expected.timeline)}")
    end

    def check_upstream_write(step, entity, expected, error, before, after, context)
      kind = step.kind
      if error
        @stats["upstream_raise:#{kind}:#{error.class}"] += 1
        # Atomic: an upstream write that raises leaves no row behind
        fail!("#{kind}:raised_and_wrote", "upstream raised #{error.class} but wrote rows#{context.()}") unless after == before
        if expected&.timeline
          @divergences << "#{kind}: model expected #{Format.timeline(expected.timeline)}, upstream raised #{error.class}: #{error.message[0, 160]}#{context.()}"
        end
        return
      end
      return unless expected

      if expected.path == :unchanged
        @divergences << "#{kind}: model expected no write, upstream wrote#{context.()}" unless after == before
      elsif expected.error
        @divergences << "#{kind}: model expected #{expected.error}, upstream succeeded#{context.()}"
      elsif current(after[entity.id]).map(&:segment) != expected.timeline
        @divergences << "#{kind}: model expected #{Format.timeline(expected.timeline)}, upstream wrote#{context.()}"
      end
    end

    # Rows are only ever inserted at now, or closed at now, and only in the entity written to;
    # nothing else about a row changes
    def check_rows(entity, before, after, kind, context)
      @entities.each { |each_entity|
        before_by_id = before[each_entity.id].to_h { |row| [row.id, row] }
        missing = before_by_id.keys - after[each_entity.id].map(&:id)
        fail!("#{kind}:row_deleted", "rows physically deleted: #{missing}#{context.()}") if missing.any?

        after[each_entity.id].each { |row|
          previous = before_by_id[row.id]
          if previous
            next if previous == row

            closed_now = each_entity.equal?(entity) && previous.live? && row.transaction_to == @now &&
              (!@has_deleted_at || row.deleted_at == @now) &&
              [previous.transaction_from, previous.from, previous.to, previous.attrs, previous.created_at] ==
                [row.transaction_from, row.from, row.to, row.attrs, row.created_at]
            fail!("#{kind}:row_rewritten", "row #{row.id} rewritten: #{previous.to_a} -> #{row.to_a} (entity #{each_entity.id})#{context.()}") unless closed_now
            next
          end

          fail!("#{kind}:row_inserted_elsewhere", "row #{row.id} inserted into entity #{each_entity.id}#{context.()}") unless each_entity.equal?(entity)
          fail!("#{kind}:row_transaction_from", "new row #{row.id} transaction_from #{row.transaction_from}, now #{@now}#{context.()}") unless row.transaction_from == @now
          # Never a row closed in the transaction time it's written in
          fail!("#{kind}:row_inserted_closed", "new row #{row.id} #{Format.segment(row.segment)} transaction_to #{row.transaction_to}#{context.()}") unless row.live?
          fail!("#{kind}:row_created_at", "new row #{row.id} created_at #{row.created_at}, transaction_from #{row.transaction_from}#{context.()}") unless row.created_at == row.transaction_from
          fail!("#{kind}:row_deleted_at", "new row #{row.id} deleted_at #{row.deleted_at.inspect}#{context.()}") if @has_deleted_at && !row.deleted_at.nil?
          next if row.from < row.to
          next if row.from == row.to && @zero_length && !FORK_OPERATIONS.include?(kind)

          fail!("#{kind}:row_without_valid_time", "new row #{row.id} valid [#{Format.label(row.from)},#{Format.label(row.to)})#{context.()}")
        }
      }
    end

    # operation is the kind of the fork operation that just returned, if one did
    def check_current_timeline(entity, after, operation, context)
      live = current(after[entity.id])
      live.each { |row|
        next if row.from < row.to

        # After a fork operation returns, no zero-length row is current. Upstream writes leave
        # them only when the run allows it.
        fail!("#{operation}:zero_length_row_left", "zero-length current row #{row.id} #{Format.segment(row.segment)}#{context.()}") if operation
        fail!("current:zero_length_row", "current row #{row.id} #{Format.segment(row.segment)}#{context.()}") unless @zero_length && row.from == row.to

        @stats["zero_length_rows_seen"] += 1
      }
      live.each_cons(2) { |left, right|
        fail!("current:overlap", "overlap #{Format.segment(left.segment)} #{Format.segment(right.segment)}#{context.()}") if left.to > right.from
        if operation && left.to == right.from && left.attrs == right.attrs
          fail!("#{operation}:seam_left", "equal neighbours #{Format.segment(left.segment)} #{Format.segment(right.segment)}#{context.()}")
        end
      }
      # The gem's own view of current knowledge agrees
      via_scope = @model.ignore_valid_datetime.where(bitemporal_id: entity.id).order(@valid_from, @valid_to).map(&:swapped_id)
      fail!("current:default_scope", "default scope sees #{via_scope}, current rows are #{live.map(&:id)}#{context.()}") unless via_scope == live.map(&:id)
    end

    # The rows live at each snapshot's transaction time are the rows that snapshot recorded,
    # and the gem's transaction_at queries agree on a sample of snapshots and valid times
    def check_history(entity, rows, context)
      rows.each { |row|
        fail!("history:inverted", "row #{row.id} transaction_from #{row.transaction_from} > transaction_to #{row.transaction_to}#{context.()}") if row.transaction_from > row.transaction_to
      }
      entity.history.each_with_index { |snapshot, index|
        at_snapshot = rows.select { |row| row.transaction_from <= snapshot.recorded_at && snapshot.recorded_at < row.transaction_to }
          .sort_by { |row| [row.from, row.to] }.map { |row| [row.id, row.segment] }
        unless at_snapshot == snapshot.rows
          fail!("history:replay",
            "entity #{entity.id} at snapshot #{index} (#{snapshot.recorded_at}): rows #{at_snapshot.map(&:first)} want #{snapshot.rows.map(&:first)}#{context.()}")
        end
      }

      entity.history.sample(2, random: @check_rng).push(entity.history.last).uniq.each { |snapshot|
        ids = ActiveRecord::Bitemporal.transaction_at(snapshot.recorded_at) {
          @model.ignore_valid_datetime.where(bitemporal_id: entity.id).order(@valid_from, @valid_to).map(&:swapped_id)
        }
        unless ids == snapshot.rows.map(&:first)
          fail!("history:transaction_at", "transaction_at(#{snapshot.recorded_at}) sees #{ids} want #{snapshot.rows.map(&:first)}#{context.()}")
        end

        times = snapshot.segments.flat_map { |segment| [segment.from, segment.to - 1.second] }.reject { |time| time >= INF - 1.second }
        times.sample(2, random: @check_rng).each { |time|
          want = snapshot.rows.find { |_, segment| segment.covers?(time) }&.first
          found = ActiveRecord::Bitemporal.transaction_at(snapshot.recorded_at) { @model.find_at_time(time, entity.id)&.swapped_id }
          unless found == want
            fail!("history:find_at_time",
              "transaction_at(#{snapshot.recorded_at}) find_at_time(#{Format.label(time)}) found #{found.inspect} want #{want.inspect}#{context.()}")
          end
        }
      }
    end

    def check_predicates(entity)
      record = entity.self_record
      timeline = ReferenceModel.holding_a_time(entity.segments)
      terminated = timeline.any? && timeline.last.to < INF
      shifted = timeline.any? && timeline.first.from != entity.original_genesis
      unless record.terminated? == terminated
        fail!("predicate:terminated?", "terminated? #{record.terminated?.inspect} want #{terminated} for #{Format.timeline(entity.segments)}")
      end
      unless record.shifted_genesis? == shifted
        fail!("predicate:shifted_genesis?",
          "shifted_genesis? #{record.shifted_genesis?.inspect} want #{shifted} (original genesis #{Format.label(entity.original_genesis)}) for #{Format.timeline(entity.segments)}")
      end
    end

    def check_point_queries(entity)
      bounds = entity.segments.flat_map { |segment| [segment.from, segment.to] }.reject { |time| time == INF }
      (bounds + bounds.map { |time| time - 1.second } + [@now]).sample(3, random: @check_rng).each { |time|
        want = ReferenceModel.covering(entity.segments, time)
        found = @model.find_at_time(time, entity.id)
        found = found && Segment.new(found[@valid_from].in_time_zone, found[@valid_to].in_time_zone, business_attrs(found))
        unless found == want
          fail!("current:find_at_time", "find_at_time(#{Format.label(time)}) found #{found && Format.segment(found)} want #{want && Format.segment(want)}")
        end
      }
    end

    # ==== Rows and attributes

    def rows(bitemporal_id)
      columns = [:id, :transaction_from, :transaction_to, @valid_from, @valid_to, :created_at]
      columns << :deleted_at if @has_deleted_at
      @model.unscoped.where(bitemporal_id: bitemporal_id).order(:id).pluck(*columns, *@business).map { |values|
        fixed = values.first(columns.size)
        Row.new(
          fixed[0], fixed[1], fixed[2], fixed[3]&.in_time_zone, fixed[4]&.in_time_zone, fixed[5],
          @has_deleted_at ? fixed[6] : :none, @business.zip(values.drop(columns.size)).to_h
        )
      }
    end

    def current(rows)
      rows.select(&:live?).sort_by { |row| [row.from, row.to] }
    end

    def all_rows
      @entities.to_h { |entity| [entity.id, rows(entity.id)] }
    end

    # Every column of every row of every entity, to tell a write that changes nothing
    def raw_rows
      @model.unscoped.where(bitemporal_id: @entities.map(&:id)).order(:id).pluck(*@model.column_names)
    end

    def self_state(record)
      [record.swapped_id, record.attributes.dup, record.changed?, record.valid_datetime]
    end

    def cast(attrs)
      attrs.to_h { |key, value| [key.to_s, @model.type_for_attribute(key.to_s).cast(value)] }
    end

    def business_attrs(record)
      @business.to_h { |column| [column, record[column]] }
    end

    def full_attrs(attrs)
      @business.to_h { |column| [column, nil] }.merge(cast(attrs))
    end
  end

  # Runs one generated sequence in a transaction it rolls back. Returns [failure or nil, the
  # steps that ran, the runner].
  def self.run_sequence(model, seed, max_steps:, zero_length:, seams:, values:)
    sizes = Random.new(seed ^ 0x5eed)
    entities = sizes.rand < 0.4 ? 2 : 1
    steps = sizes.rand([12, max_steps].min..max_steps)
    runner = Runner.new(model, zero_length: zero_length, seams: seams, values: values, check_seed: seed)
    executed = rolled_back { runner.run_generated(Random.new(seed), steps: steps, entities: entities) }
    [nil, executed, runner]
  rescue Failure => failure
    [failure, failure.steps, runner]
  end

  # Replays steps in a transaction it rolls back. Returns [failure or nil, the runner]; the
  # runner's log tells what each step did. check_seed is the sequence's seed, so the sampled
  # checks sample what they sampled in the run that failed.
  def self.replay(model, steps, zero_length: false, check_seed: 0)
    runner = Runner.new(model, zero_length: zero_length, check_seed: check_seed)
    rolled_back { runner.run(steps) }
    [nil, runner]
  rescue Failure => failure
    [failure, runner]
  end

  def self.rolled_back
    result = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      result = yield
      raise ActiveRecord::Rollback
    end
    result
  end

  # Deletes steps, in halving chunks down to single steps, while the sequence still fails
  # with the same signature. Then simplifies each step left the same way: dt to 1 second, and
  # a fork operation's unsaved attributes, wrap and time format dropped.
  def self.shrink(model, steps, signature, zero_length: false, check_seed: 0)
    fails = ->(candidate) {
      failure, = replay(model, candidate, zero_length: zero_length, check_seed: check_seed)
      failure&.signature == signature
    }
    best = steps
    chunk = [best.size / 2, 1].max
    while chunk >= 1
      index = 0
      progressed = false
      while index < best.size
        candidate = best[0...index] + best[(index + chunk)..].to_a
        if fails.(candidate)
          best = candidate
          progressed = true
        else
          index += chunk
        end
      end
      chunk /= 2 unless progressed
    end

    best = simplify(best, fails) { |step| step.dup.tap { |simpler| simpler.dt = 1 } unless step.dt == 1 }
    %i[unsaved wrap time_format].each { |key|
      best = simplify(best, fails) { |step| step.dup.tap { |simpler| simpler.args = step.args.except(key) } if step.args.key?(key) }
    }
    best
  end

  def self.simplify(steps, fails)
    steps.each_index.reduce(steps) { |best, index|
      simpler = yield(best[index])
      next best unless simpler

      candidate = best.dup
      candidate[index] = simpler
      fails.(candidate) ? candidate : best
    }
  end

  # Generated sequences on one model: sequence i runs from seed first_seed + i, so any one of
  # them reruns alone from its seed. Collects stats, upstream divergences and the first
  # failure of each signature, shrunk.
  class Batch
    Result = Struct.new(:failures, :stats, :divergences, :sequences, :steps, :seconds)
    FailureCase = Struct.new(:seed, :failure, :log, :shrunk, :shrunk_failure, :shrunk_log, keyword_init: true)

    attr_reader :name, :model, :first_seed, :count, :max_steps, :zero_length, :seams

    def initialize(name:, model:, values:, first_seed:, count:, max_steps:, zero_length:, seams:)
      @name = name
      @model = model
      @values = values
      @first_seed = first_seed
      @count = count
      @max_steps = max_steps
      @zero_length = zero_length
      @seams = seams
    end

    def description
      "#{name}: #{count} sequences of up to #{max_steps} steps from seed #{first_seed}, " \
        "zero-length rows #{zero_length ? 'on' : 'off'}, seams #{seams ? 'on' : 'off'}"
    end

    def run(shrink: true, stop_on_failure: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      failures = {}
      stats = Hash.new(0)
      divergences = []
      sequences = steps = 0
      count.times { |index|
        seed = first_seed + index
        failure, executed, runner = ForkProperty.run_sequence(
          model, seed, max_steps: max_steps, zero_length: zero_length, seams: seams, values: @values
        )
        sequences += 1
        steps += executed.size
        runner.stats.each { |key, value| stats[key] += value }
        divergences.concat(runner.divergences.map { |divergence| "seed #{seed}: #{divergence}" })
        next unless failure

        stats["failures"] += 1
        stats["failure:#{failure.signature}"] += 1
        failures[failure.signature] ||= failure_case(seed, failure, executed, runner, shrink)
        break if stop_on_failure
      }
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Result.new(failures.values, stats, divergences, sequences, steps, seconds)
    end

    # The environment that reruns one sequence alone
    def rerun_command(seed)
      knobs = ["FORK_PROPERTY_MODEL=#{name}", "FORK_PROPERTY_SEED=#{seed}", "FORK_PROPERTY_STEPS=#{max_steps}"]
      knobs << "FORK_PROPERTY_ZERO_LENGTH=1" if zero_length
      knobs << "FORK_PROPERTY_SEAMS=1" if seams
      "#{knobs.join(' ')} bundle exec rspec spec/fork/property"
    end

    def failure_report(failure_case)
      text = +"=== #{failure_case.failure.signature} (seed #{failure_case.seed})\n#{failure_case.failure.message}\n"
      text << "-- last steps:\n#{failure_case.log.join("\n")}\n"
      if failure_case.shrunk
        text << "-- shrunk to #{failure_case.shrunk.size} steps:\n#{failure_case.shrunk_log.join("\n")}\n"
        text << "#{failure_case.shrunk_failure&.message}\n"
        text << "-- replay:\nForkProperty.replay(#{model.name}, #{Format.ruby(failure_case.shrunk)}, " \
                "zero_length: #{zero_length}, check_seed: #{failure_case.seed})\n"
      end
      text << "-- rerun: #{rerun_command(failure_case.seed)}\n"
    end

    def report(result, divergences: 6)
      text = +"#{description}\n"
      text << "#{result.sequences} sequences, #{result.steps} steps, #{result.seconds.round(1)}s\n"
      text << "stats=#{result.stats.sort.to_h}\n"
      text << "upstream_divergences=#{result.divergences.size}\n"
      result.divergences.first(divergences).each { |divergence| text << "  #{divergence.gsub("\n", "\n    ")}\n" }
      text << "failure_signatures=#{result.failures.size}\n\n"
      result.failures.each { |failure_case| text << failure_report(failure_case) << "\n" }
      text
    end

    private

    def failure_case(seed, failure, executed, runner, shrink)
      failure_case = FailureCase.new(seed: seed, failure: failure, log: runner.log.last(12))
      return failure_case unless shrink

      shrunk = ForkProperty.shrink(model, executed, failure.signature, zero_length: zero_length, check_seed: seed)
      shrunk_failure, shrunk_runner = ForkProperty.replay(model, shrunk, zero_length: zero_length, check_seed: seed)
      failure_case.shrunk = shrunk
      failure_case.shrunk_failure = shrunk_failure
      failure_case.shrunk_log = shrunk_runner.log
      failure_case
    end
  end
end
