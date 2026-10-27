# frozen_string_literal: true

require 'spec_helper'

module ReviewInjectBeforeTxn
  def transaction(*args, **kw, &blk)
    if (inj = Thread.current[:review_inject])
      Thread.current[:review_inject] = nil
      inj.call
    end
    super
  end
end
ActiveRecord::Base.singleton_class.prepend(ReviewInjectBeforeTxn)

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

  it "current_time is taken before the lock: a write that lands in between gets closed with transaction_to < transaction_from, and as-of queries see overlapping history" do
    jan = "2020/01/01".in_time_zone
    feb = "2020/02/01".in_time_zone
    e = ActiveRecord::Bitemporal.valid_at(jan) { Employee.create!(name: "A") }
    sleep 0.01
    ec = Employee.find(e.id)
    eu = Employee.find(e.id)
    # Simulates: correct() computes current_time, then another writer (plain update) acquires the lock first.
    Thread.current[:review_inject] = -> { sleep 0.01; eu.update!(name: "U"); sleep 0.01 }
    ec.correct(valid_from: feb, name: "X")

    all = Employee.ignore_valid_datetime.within_deleted.where(bitemporal_id: e.id).order(:transaction_from, :valid_from)
      .pluck(:valid_from, :valid_to, :name, :transaction_from, :transaction_to)
    puts "\n[ts-before-lock] all rows:\n    #{fmt(all)}"
    inverted = all.select { |*_, tf, tt| tf > tt }
    t1 = all.find { |r| r[2] == "X" }[3]
    t2 = all.find { |r| r[2] == "U" }[3]
    tq = t1 + (t2 - t1) / 2
    as_of = ActiveRecord::Bitemporal.transaction_at(tq) {
      Employee.ignore_valid_datetime.where(bitemporal_id: e.id).order(:valid_from).pluck(:valid_from, :valid_to, :name)
    }
    puts "[ts-before-lock] as known at #{tq.strftime('%H:%M:%S.%6N')}: #{as_of.map { |a, b, n| "#{a.to_date}..#{b.year == 9999 ? 'inf' : b.to_date} #{n}" }.join(' | ')}"
    overlap = as_of.each_cons(2).any? { |(_, vt, _), (vf, _, _)| vt > vf }
    expect(inverted).to be_empty
    expect(overlap).to be false
  end

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
