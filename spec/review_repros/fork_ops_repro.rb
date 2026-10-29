# frozen_string_literal: true

require 'spec_helper'

# Removed once fixed and covered by real specs:
# - F3, bounded correct flattening other attributes and filling gaps (D2;
#   cascade_correction_spec.rb, "patch semantics")
# - F5 for correct, zero-length rows from coalescing its own inserts (D2 merges before
#   inserting; same spec). That repro's last zero-length row came from its setup: an
#   upstream update! at the same frozen time as the create!.
# - F4, self left stale and dirty after an op (D5; timeline_operations_spec.rb, "self after
#   an operation")
# - F8, op times compared unlike the column stores them, e.g. a Date column outside UTC
#   (the ops cast them on entry; "times the valid-time column stores differently" in
#   cascade_correction_spec.rb, terminate_spec.rb and shift_genesis_spec.rb)
# - cancel_shift_genesis after two shifts, whose second cancel brought back the shift the first
#   undid (a cancel after two shifts now refuses; shift_genesis_spec.rb, "the timeline it
#   restores")
RSpec.describe "Fork review repros" do
  let(:jan) { "2020/01/01".in_time_zone }
  let(:feb) { "2020/02/01".in_time_zone }
  let(:mar) { "2020/03/01".in_time_zone }
  let(:apr) { "2020/04/01".in_time_zone }
  let(:may) { "2020/05/01".in_time_zone }
  let(:jun) { "2020/06/01".in_time_zone }
  let(:inf) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
  let(:tt_inf) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }

  def timeline(klass, id, *cols)
    klass.ignore_valid_datetime.where(bitemporal_id: id).where(transaction_to: tt_inf)
      .order(:valid_from).pluck(:valid_from, :valid_to, *cols)
  end

  describe "provenance" do
    before do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "Alice", emp_code: "E001") }
        ActiveRecord::Bitemporal.valid_at(mar) { @e.update!(emp_code: "E002") }
        ActiveRecord::Bitemporal.valid_at(may) { @e.update!(name: "Bob") }
      end
    end

    it "unbounded: correction segment takes non-corrected attrs from containing record, not self" do
      e = Employee.find(@e.id) # current = Bob/E002
      Timecop.freeze("2020/10/06") { e.correct(valid_from: feb, name: "X") }
      expect(timeline(Employee, e.id, :name, :emp_code)).to eq([
        [jan, feb, "Alice", "E001"],
        [feb, mar, "X", "E001"],
        [mar, may, "Alice", "E002"],
        [may, inf, "Bob", "E002"],
      ])
    end
  end

  describe "cancel_shift_genesis after an upstream update! before the genesis" do
    before do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A") }
      end
    end

    it "shifted_genesis? is true after a plain upstream update before genesis; cancel_shift_genesis reverts that update" do
      e = Employee.find(@e.id)
      Timecop.freeze("2020/10/02") do
        rec = Employee.find(e.id)
        rec.valid_at("2019/06/01") { rec.update!(name: "Pre") }
      end
      tl = timeline(Employee, e.id, :name)
      puts "\n[upstream pre-genesis update] #{tl.map { |a, b, n| "#{a.to_date}..#{b.to_date} #{n}" }.join(' | ')} shifted_genesis?=#{e.shifted_genesis?}"
      Timecop.freeze("2020/10/03") { e.cancel_shift_genesis }
      tl2 = timeline(Employee, e.id, :name)
      puts "[after cancel_shift_genesis] #{tl2.map { |a, b, n| "#{a.to_date}..#{b.to_date} #{n}" }.join(' | ')}"
    end
  end

  describe "gaps" do
    before do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A") }
        ActiveRecord::Bitemporal.valid_at(may) { @e.update!(name: "C") }
      end
      # upstream destroy at Mar closes only the record valid at Mar -> gap [Mar, May)
      Timecop.freeze("2020/10/02") { Employee.find_at_time(mar, @e.id).destroy }
    end

    it "terminate inside a gap ends timeline at gap start, not at requested time" do
      Timecop.freeze("2020/10/03") { Employee.find_at_time(feb, @e.id).terminate(termination_time: apr) }
      puts "\n[terminate in gap] last valid_to=#{timeline(Employee, @e.id).last[1].to_date} (requested 2020-04-01)"
    end
  end

  describe "validations are bypassed" do
    let(:klass) {
      Class.new(Employee) {
        def self.name; "ValidatedEmployee"; end
        validates :emp_code, uniqueness: true
        validates :name, presence: true
      }
    }

    it "correct writes a uniqueness-violating emp_code and a blank name" do
      a = b = nil
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) {
          a = klass.create!(name: "A", emp_code: "E1")
          b = klass.create!(name: "B", emp_code: "E2")
        }
      end
      # Same change through normal update is rejected:
      expect { ActiveRecord::Bitemporal.valid_at(feb) { klass.find(b.id).update!(emp_code: "E1") } }.to raise_error(ActiveRecord::RecordInvalid)
      expect { klass.find(b.id).correct(valid_from: feb, emp_code: "E1") }.not_to raise_error
      expect { klass.find(a.id).correct(valid_from: feb, name: nil) }.not_to raise_error
      dup_count = ActiveRecord::Bitemporal.valid_at("2020/03/01") { klass.where(emp_code: "E1").count }
      puts "\n[uniqueness bypass] entities with emp_code E1 valid at 2020-03-01: #{dup_count}"
      expect(dup_count).to eq(2)
    end
  end

  describe "callbacks" do
    it "fires after_save once per inserted row, never bitemporal_update" do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A") }
        ActiveRecord::Bitemporal.valid_at(mar) { @e.update!(name: "B") }
        ActiveRecord::Bitemporal.valid_at(may) { @e.update!(name: "C") }
      end
      before = Employee.call_after_save_count
      Employee.find(@e.id).correct(valid_from: feb, valid_to: apr, name: "X")
      puts "\n[callbacks] after_save fired #{Employee.call_after_save_count - before} times for one correct()"
    end
  end
end
