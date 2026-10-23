# frozen_string_literal: true

require 'spec_helper'

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

    it "bounded across segments: emp_code in [Mar,Apr) silently rewritten E002 -> E001 although only name was corrected" do
      e = Employee.find(@e.id)
      Timecop.freeze("2020/10/06") { e.correct(valid_from: feb, valid_to: apr, name: "X") }
      tl = timeline(Employee, e.id, :name, :emp_code)
      puts "\n[bounded multi-segment] #{tl.map { |a, b, n, c| "#{a.to_date}..#{b.to_date} #{n}/#{c}" }.join(' | ')}"
      at_mid_march = ActiveRecord::Bitemporal.valid_at("2020/03/15") { Employee.find(e.id) }
      expect(at_mid_march.emp_code).to eq("E002") # what a user correcting only `name` would expect
    end
  end

  describe "stale self after correct" do
    before do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A", emp_code: "C1") }
      end
    end

    it "self keeps pre-correction attributes and is dirty; a later update! reverts the correction" do
      e = Employee.find(@e.id)
      e.correct(valid_from: feb, name: "X") # unbounded -> [Feb, inf)
      puts "\n[stale self] e.name=#{e.name.inspect} changed?=#{e.changed?} changes=#{e.changes.keys}"
      expect(Employee.find(e.id).name).to eq("X")
      e.update!(emp_code: "C2")
      expect(Employee.find(e.id).name).to eq("X") # FAILS: correction reverted for [now, inf)
    end
  end

  describe "cancel_shift_genesis after two shifts" do
    before do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A") }
      end
    end

    it "second cancel re-applies the shift it just cancelled instead of reaching the original genesis" do
      e = Employee.find(@e.id)
      Timecop.freeze("2020/10/02") { e.shift_genesis(new_valid_from: mar) }
      Timecop.freeze("2020/10/03") { e.shift_genesis(new_valid_from: may) }
      Timecop.freeze("2020/10/04") { e.cancel_shift_genesis }
      g1 = timeline(Employee, e.id).first.first
      Timecop.freeze("2020/10/05") { e.cancel_shift_genesis }
      g2 = timeline(Employee, e.id).first.first
      puts "\n[cancel x2] after 1st cancel genesis=#{g1.to_date}, after 2nd cancel genesis=#{g2.to_date}, shifted_genesis?=#{e.shifted_genesis?}"
      expect(g2).to eq(jan)
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

    it "bounded correct across a gap silently fills it (fabricates existence)" do
      before_tl = timeline(Employee, @e.id, :name)
      Timecop.freeze("2020/10/03") { Employee.find_at_time(feb, @e.id).correct(valid_from: feb, valid_to: jun, name: "X") }
      after_tl = timeline(Employee, @e.id, :name)
      fmt = ->(tl) { tl.map { |a, b, n| "#{a.to_date}..#{b == inf ? 'inf' : b.to_date} #{n}" }.join(' | ') }
      puts "\n[gap] before: #{fmt.(before_tl)}\n[gap] after:  #{fmt.(after_tl)}"
      expect(ActiveRecord::Bitemporal.valid_at("2020/04/01") { Employee.find_by(bitemporal_id: @e.id) }).to be_nil
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

  describe "coalesce" do
    it "leaves zero-length transaction rows that fail the model's own validation" do
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(jan) { @e = Employee.create!(name: "A") }
        ActiveRecord::Bitemporal.valid_at(mar) { @e.update!(name: "B") }
      end
      Timecop.freeze("2020/10/06") { Employee.find(@e.id).correct(valid_from: mar, name: "A") }
      zero = Employee.ignore_valid_datetime.within_deleted.where(bitemporal_id: @e.id)
        .where("transaction_from = transaction_to").to_a
      puts "\n[coalesce] zero-length tx rows: #{zero.size}; valid? => #{zero.map(&:valid?).inspect}; errors=#{zero.first&.errors&.full_messages.inspect}"
      expect(zero).to be_empty
    end
  end

  describe "date-typed valid time in non-UTC zone (Department)" do
    %w[Tokyo America/New_York].each do |zone|
      it "correct at an exact segment boundary (#{zone})" do
        Time.use_zone(zone) do
          d = nil
          Timecop.freeze("2020/10/01") do
            ActiveRecord::Bitemporal.valid_at("2020/01/01") { d = Department.create!(name: "A") }
            ActiveRecord::Bitemporal.valid_at("2020/03/01") { d.update!(name: "B") }
          end
          Timecop.freeze("2020/10/06") { Department.find(d.id).correct(valid_from: Date.new(2020, 3, 1), name: "X") }
          tl = Department.ignore_valid_datetime.where(bitemporal_id: d.id).where(transaction_to: ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO).order(:valid_from, :valid_to).pluck(:valid_from, :valid_to, :name)
          puts "\n[date/#{zone}] #{tl.map { |a, b, n| "#{a}..#{b} #{n}" }.join(' | ')}"
          expect(tl).to eq([[Date.new(2020, 1, 1), Date.new(2020, 3, 1), "A"], [Date.new(2020, 3, 1), Date.new(9999, 12, 31), "X"]])
        end
      end
    end
  end
end
