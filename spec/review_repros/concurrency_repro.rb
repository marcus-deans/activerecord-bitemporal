# frozen_string_literal: true

require 'spec_helper'

module ReviewPauseBeforeValidate
  def validate_cascade_correction_timeline!
    if (hook = Thread.current[:review_pause])
      Thread.current[:review_pause] = nil
      hook.call
    end
    super
  end
end
Employee.prepend(ReviewPauseBeforeValidate)

RSpec.describe "Fork review concurrency repros" do
  let(:tt_inf) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }

  def fmt(rows)
    rows.map { |vf, vt, n, tf, tt| "#{vf.to_date}..#{vt.year == 9999 ? 'inf' : vt.to_date} #{n} tx[#{tf.strftime('%H:%M:%S.%6N')}, #{tt.year == 9999 ? 'inf' : tt.strftime('%H:%M:%S.%6N')})" }.join("\n    ")
  end

  # F1/F2 (lock scope, timestamp read before the lock) are fixed by D1 and covered by
  # timeline_operations_spec.rb ("locking the timeline"); their repros were removed.
  #
  # Stays red after D1 by design: the racing write is upstream's plain update!, whose own
  # lock covers no rows here and which never takes the advisory lock. dsptch-api closes this
  # by wrapping such writes in lock_family! (see FIX_PLAN.md, D1). The same race with the
  # app's lock held is covered in timeline_operations_spec.rb ("locking the timeline").
  context "future-dated entity (no row valid now -> lock covers zero rows)", use_truncation: true do
    it "correct() racing a plain update produces overlapping current-knowledge rows" do
      start = 1.year.from_now.beginning_of_day
      e = ActiveRecord::Bitemporal.valid_at(start) { Employee.create!(name: "A") }

      c_written = Queue.new
      u_started = Queue.new
      errors = []

      tc = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:review_pause] = -> { c_written << true; u_started.pop; sleep 0.5 }
          Employee.find_at_time(start, e.id).correct(valid_from: start + 30.days, name: "X")
        end
      rescue => ex
        errors << [:correct, ex]
      end

      tu = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          c_written.pop
          rec = Employee.find_at_time(start, e.id)
          u_started << true
          rec.valid_at(start + 60.days) { rec.update!(name: "U") }
        end
      rescue => ex
        errors << [:update, ex]
      end
      [tc, tu].each(&:join)

      cur = Employee.ignore_valid_datetime.where(bitemporal_id: e.id).where(transaction_to: tt_inf).order(:valid_from)
        .pluck(:valid_from, :valid_to, :name, :transaction_from, :transaction_to)
      puts "\n[race] errors=#{errors.map { |w, ex| "#{w}: #{ex.class} #{ex.message[0, 80]}" }}"
      puts "[race] current knowledge:\n    #{fmt(cur)}"
      overlap = cur.each_cons(2).any? { |a, b| a[1] > b[0] }
      expect(overlap).to be false
    end
  end
end
