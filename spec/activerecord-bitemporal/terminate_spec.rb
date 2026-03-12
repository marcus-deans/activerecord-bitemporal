# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Timeline Termination (#terminate, #cancel_termination, #terminated?)" do
  # ==========================================================================
  # Test Helpers
  # ==========================================================================

  # Date helpers (Valid Time points)
  let(:_01_01) { "2020/01/01".in_time_zone }
  let(:_02_01) { "2020/02/01".in_time_zone }
  let(:_03_01) { "2020/03/01".in_time_zone }
  let(:_04_01) { "2020/04/01".in_time_zone }
  let(:_05_01) { "2020/05/01".in_time_zone }
  let(:_06_01) { "2020/06/01".in_time_zone }
  let(:_07_01) { "2020/07/01".in_time_zone }
  let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
  let(:tt_infinity) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }

  # Get current timeline (records with open transaction_to)
  # Returns array of [valid_from, valid_to, name] tuples
  def current_timeline(record)
    Employee.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .order(:valid_from)
      .pluck(:valid_from, :valid_to, :name)
  end

  # Get count of current timeline records
  def timeline_count(record)
    Employee.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .count
  end

  # Get all historical records (including closed transaction times)
  def all_records(record)
    Employee.ignore_valid_datetime
      .within_deleted
      .where(bitemporal_id: record.bitemporal_id)
      .order(:transaction_from, :valid_from)
  end

  # Find an employee by bitemporal_id, even if terminated (ignores valid time scoping)
  def find_ignoring_valid_time(record)
    Employee.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .order(:valid_from)
      .first
  end

  # Timeline invariant helpers
  def no_overlaps?(timeline)
    return true if timeline.size <= 1
    timeline.each_cons(2).all? do |(_, valid_to_a, _), (valid_from_b, _, _)|
      valid_to_a <= valid_from_b
    end
  end

  def no_gaps?(timeline)
    return true if timeline.size <= 1
    timeline.each_cons(2).all? do |(_, valid_to_a, _), (valid_from_b, _, _)|
      valid_to_a == valid_from_b
    end
  end

  def valid_timeline?(timeline)
    no_overlaps?(timeline) && no_gaps?(timeline)
  end

  # ==========================================================================
  # Category 1: Basic Termination
  # ==========================================================================

  describe "basic termination" do

    # Test 1.1: Single segment, mid-segment termination
    context "single segment, mid-segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # before: A
      #         |----------------------------------------->
      #         Jan                                       ∞
      #
      # terminate(termination_time: Mar)
      #                  ↓
      # after:  A
      #         |--------|
      #         Jan     Mar
      it "truncates timeline at termination point" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          result = employee.terminate(termination_time: _03_01)
          expect(result).to eq(true)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"]
        ])
      end
    end

    # Test 1.2: Multi-segment, mid-segment (earlier segments untouched)
    context "multi-segment, terminate in last segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|----------------------------------------->
      #         Jan          Mar                                        ∞
      #
      # terminate(termination_time: May)
      #                  ↓
      # after:  A             B
      #         |-------------|------|
      #         Jan          Mar    May
      it "truncates last segment, earlier segments untouched" do
        employee = Employee.find(@employee.id)
        a_record_before = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "A").first

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _05_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _05_01, "B"]
        ])

        # Verify A's transaction_from is unchanged (it wasn't touched)
        a_record_after = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "A").first
        expect(a_record_after.transaction_from).to eq(a_record_before.transaction_from)
      end
    end

    # Test 1.3: Multi-segment, removes future segments
    context "multi-segment, termination removes future segments" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May          ∞
      #
      # terminate(termination_time: Feb)
      #                  ↓
      # after:  A
      #         |----|
      #         Jan  Feb
      it "removes all segments after termination, truncates spanning one" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _02_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"]
        ])
      end
    end

    # Test 1.4: At exact segment boundary
    context "termination at exact segment boundary" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May          ∞
      #
      # terminate(termination_time: Mar)
      #                  ↓
      # after:  A
      #         |-------------|
      #         Jan          Mar
      it "closes segments at/after boundary, no truncated copy needed" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"]
        ])
      end
    end

    # Test 1.5: Three segments, terminate in second
    context "three segments, terminate mid-second" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May          ∞
      #
      # terminate(termination_time: Apr)
      #                  ↓
      # after:  A             B
      #         |-------------|-----|
      #         Jan          Mar   Apr
      it "truncates second segment, removes third" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _04_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _04_01, "B"]
        ])
      end
    end
  end

  # ==========================================================================
  # Category 2: Guards and Errors
  # ==========================================================================

  describe "guards and errors" do

    # Test 2.1: No current-knowledge records
    context "no current-knowledge records" do
      it "raises RecordNotFound" do
        employee = Employee.new(name: "ghost", bitemporal_id: 99999)

        expect {
          employee.terminate(termination_time: _03_01)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # Test 2.2: termination_time <= first valid_from
    context "termination_time <= first valid_from" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "raises ArgumentError for time before genesis" do
        employee = Employee.find(@employee.id)

        expect {
          employee.terminate(termination_time: _01_01)
        }.to raise_error(ArgumentError, /must be greater than/)
      end

      it "raises ArgumentError for time equal to genesis" do
        employee = Employee.find(@employee.id)

        expect {
          employee.terminate(termination_time: _03_01)
        }.to raise_error(ArgumentError, /must be greater than/)
      end
    end

    # Test 2.3: termination_time > last valid_to (bounded timeline)
    context "termination_time > last valid_to on bounded timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "raises ArgumentError for extending past termination" do
        employee = find_ignoring_valid_time(@employee)

        expect {
          Timecop.freeze("2020/10/06") do
            employee.terminate(termination_time: _05_01)
          end
        }.to raise_error(ArgumentError)
      end
    end

    # Test 2.4: Already terminated at same time (no-op)
    context "already terminated at same time" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "returns true without DB changes" do
        employee = find_ignoring_valid_time(@employee)
        records_before = all_records(employee).count

        Timecop.freeze("2020/10/06") do
          result = employee.terminate(termination_time: _03_01)
          expect(result).to eq(true)
        end

        expect(all_records(employee).count).to eq(records_before)
      end
    end
  end

  # ==========================================================================
  # Category 3: Re-Termination
  # ==========================================================================

  describe "re-termination" do

    # Test 3.1: Re-terminate earlier (further truncation)
    context "re-terminate earlier" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      # before (terminated):
      #         A             B
      #         |-------------|------|
      #         Jan          Mar    May
      #
      # re-terminate(termination_time: Feb)
      #                  ↓
      # after:  A
      #         |----|
      #         Jan  Feb
      it "further truncates the already-terminated timeline" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _02_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"]
        ])
      end
    end

    # Test 3.2: Re-terminate later → error
    context "re-terminate later" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "raises ArgumentError" do
        employee = find_ignoring_valid_time(@employee)

        expect {
          Timecop.freeze("2020/10/06") do
            employee.terminate(termination_time: _05_01)
          end
        }.to raise_error(ArgumentError)
      end
    end
  end

  # ==========================================================================
  # Category 4: Cancel Termination
  # ==========================================================================

  describe "cancel_termination" do

    # Test 4.1: Cancel single-segment termination
    context "cancel single-segment termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      # before (terminated):
      #         A
      #         |--------|
      #         Jan     Mar
      #
      # cancel_termination
      #         ↓
      # after:  A
      #         |----------------------------------------->
      #         Jan                                       ∞
      it "restores timeline to infinity" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          result = employee.cancel_termination
          expect(result).to eq(true)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, infinity, "A"]
        ])
      end
    end

    # Test 4.2: Cancel multi-segment termination (recovers removed segments)
    context "cancel multi-segment termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _02_01)
        end
      end

      # before (terminated):
      #         A
      #         |----|
      #         Jan  Feb
      #
      # cancel_termination
      #         ↓
      # after:  A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May          ∞
      it "recovers all removed segments from transaction history" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.cancel_termination
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])
      end
    end

    # Test 4.3: Cancel on non-terminated entity (no-op)
    context "non-terminated entity" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "returns true without DB changes" do
        employee = Employee.find(@employee.id)
        records_before = all_records(employee).count

        Timecop.freeze("2020/10/06") do
          result = employee.cancel_termination
          expect(result).to eq(true)
        end

        expect(all_records(employee).count).to eq(records_before)
      end
    end

    # Test 4.4: Terminate → cancel → terminate round-trip
    context "terminate → cancel → terminate round-trip" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "supports full round-trip" do
        employee = Employee.find(@employee.id)

        # Step 1: Terminate at Feb
        Timecop.freeze("2020/10/02") do
          employee.terminate(termination_time: _02_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"]
        ])

        # Step 2: Cancel termination
        Timecop.freeze("2020/10/03") do
          employee.cancel_termination
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, infinity, "B"]
        ])

        # Step 3: Re-terminate at a different point (Apr)
        Timecop.freeze("2020/10/04") do
          employee.terminate(termination_time: _04_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _04_01, "B"]
        ])
      end
    end
  end

  # ==========================================================================
  # Category 5: Audit Trail
  # ==========================================================================

  describe "audit trail" do

    # Test 5.1: After termination: old segments remain in history
    context "termination audit trail" do
      before do
        @t0 = "2020/10/01".in_time_zone
        Timecop.freeze(@t0) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "old knowledge sees full timeline, new knowledge sees truncated" do
        employee = Employee.find(@employee.id)
        @t1 = "2020/10/06".in_time_zone

        Timecop.freeze(@t1) do
          employee.terminate(termination_time: _02_01)
        end

        # At T0 (before termination): should see B at May
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.transaction_at(@t0) do
            ActiveRecord::Bitemporal.valid_at(_05_01) do
              expect(Employee.find(employee.id).name).to eq("B")
            end
          end
        end

        # At T1 (after termination): should NOT find record at May
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.valid_at(_05_01) do
            expect(Employee.find_at_time(_05_01, employee.id)).to be_nil
          end
        end
      end
    end

    # Test 5.2: After cancel: both states in history
    context "cancel termination audit trail" do
      before do
        @t0 = "2020/10/01".in_time_zone
        Timecop.freeze(@t0) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        @t1 = "2020/10/02".in_time_zone
        Timecop.freeze(@t1) do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "after cancel, current knowledge extends to infinity again" do
        employee = find_ignoring_valid_time(@employee)
        @t2 = "2020/10/06".in_time_zone

        Timecop.freeze(@t2) do
          employee.cancel_termination
        end

        # At T1 (terminated state): valid_at(May) should NOT find record
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.transaction_at(@t1) do
            ActiveRecord::Bitemporal.valid_at(_05_01) do
              expect(Employee.find_at_time(_05_01, employee.id)).to be_nil
            end
          end
        end

        # At T2 (after cancel): valid_at(May) should find record
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.valid_at(_05_01) do
            expect(Employee.find(employee.id).name).to eq("A")
          end
        end
      end
    end
  end

  # ==========================================================================
  # Category 6: Timeline Integrity
  # ==========================================================================

  describe "timeline integrity" do

    # Test 6.1: After terminate: no overlaps, no gaps
    context "after termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      it "maintains no overlaps and no gaps in surviving timeline" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _04_01)
        end

        timeline = current_timeline(employee)
        expect(valid_timeline?(timeline)).to be true
      end
    end

    # Test 6.2: After cancel: no overlaps, no gaps
    context "after cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _02_01)
        end
      end

      it "maintains no overlaps and no gaps in restored timeline" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.cancel_termination
        end

        timeline = current_timeline(employee)
        expect(valid_timeline?(timeline)).to be true
        expect(timeline.size).to eq(3)
        expect(timeline.last[1]).to eq(infinity)
      end
    end
  end

  # ==========================================================================
  # Category 7: Composition
  # ==========================================================================

  describe "composition with other operations" do

    # Test 7.1: correct within range after termination
    context "correct within terminated range" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      # terminated: A             B
      #             |-------------|------|
      #             Jan          Mar    May
      #
      # correct(valid_from: Feb, valid_to: Mar, name: "X")
      #                  ↓
      # after:  A    X   B
      #         |----|----|------|
      #         Jan Feb  Mar   May
      it "works within surviving range" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, _05_01, "B"]
        ])
      end
    end

    # Test 7.2: correct beyond termination → RecordNotFound
    context "correct beyond termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "raises RecordNotFound for correction past termination" do
        employee = find_ignoring_valid_time(@employee)

        expect {
          Timecop.freeze("2020/10/06") do
            employee.correct(valid_from: _05_01, name: "X")
          end
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # Test 7.3: shift_genesis backward after termination
    context "shift_genesis backward after termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      # terminated: A
      #             |--------|
      #             Mar     May
      #
      # shift_genesis(new_valid_from: Jan)
      #                  ↓
      # after:  A
      #         |----------------|
      #         Jan             May
      it "extends genesis while preserving termination date" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _05_01, "A"]
        ])
      end
    end

    # Test 7.4: shift_genesis forward past termination → ArgumentError
    context "shift_genesis forward past termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "raises ArgumentError (would erase all segments)" do
        employee = find_ignoring_valid_time(@employee)

        expect {
          Timecop.freeze("2020/10/06") do
            employee.shift_genesis(new_valid_from: _05_01)
          end
        }.to raise_error(ArgumentError, /erase all segments/)
      end
    end
  end

  # ==========================================================================
  # Category 8: Self-Update
  # ==========================================================================

  describe "self-update after operation" do

    # Test 8.1: After terminate: self reflects terminated state
    context "after terminate" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "self temporal attrs point to the last surviving segment" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _02_01)
        end

        # Temporal attrs are updated (business attrs like name require reload)
        expect(employee.valid_from).to eq(_01_01)
        expect(employee.valid_to).to eq(_02_01)
      end
    end

    # Test 8.2: After cancel: self reflects restored state
    context "after cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _02_01)
        end
      end

      it "self points to currently-valid segment after cancel" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.cancel_termination
        end

        # After cancel, timeline extends to infinity again
        timeline = current_timeline(employee)
        expect(timeline.last[1]).to eq(infinity)
      end
    end
  end

  # ==========================================================================
  # Category 9: terminated? Predicate
  # ==========================================================================

  describe "#terminated?" do

    # Test 9.1: Non-terminated → false
    context "non-terminated entity" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "returns false" do
        employee = Employee.find(@employee.id)
        expect(employee.terminated?).to be false
      end
    end

    # Test 9.2: After termination → true
    context "after termination" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "returns true" do
        employee = find_ignoring_valid_time(@employee)
        expect(employee.terminated?).to be true
      end
    end

    # Test 9.3: After cancel → false
    context "after cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
        Timecop.freeze("2020/10/03") do
          find_ignoring_valid_time(@employee).cancel_termination
        end
      end

      it "returns false" do
        employee = Employee.find(@employee.id)
        expect(employee.terminated?).to be false
      end
    end

    # Test 9.4: When self is not the last segment → still correct
    context "when self is early in a multi-segment timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "returns false regardless of which segment self references" do
        # Get employee pointing to first segment
        employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.find(@employee.id) }
        expect(employee.terminated?).to be false
      end
    end
  end

  # ==========================================================================
  # Category 10: Coalescing
  # ==========================================================================

  describe "coalescing" do

    # Test 10.1: Termination at boundary removes differentiating segment
    context "termination causes adjacent identical segments to merge" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "A") }
        end
      end

      # before: A             B             A
      #         |-------------|-------------|----------->
      #         Jan          Mar           May          ∞
      #
      # terminate(termination_time: Mar) → removes B and A(May)
      it "leaves single segment when termination removes all others" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.terminate(termination_time: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"]
        ])
      end
    end

    # Test 10.2: Cancel termination triggers coalesce
    context "cancel termination restores and coalesces" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "restored timeline is valid after cancel" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/06") do
          employee.cancel_termination
        end

        timeline = current_timeline(employee)
        expect(valid_timeline?(timeline)).to be true
        expect(timeline.last[1]).to eq(infinity)
      end
    end
  end

  # ==========================================================================
  # Category 11: Concurrency
  # ==========================================================================

  describe "concurrency" do

    # Test 11.1: Two threads terminate same entity at same time
    context "two threads terminate same entity simultaneously", use_truncation: true do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "both succeed via locking serialization" do
        employee_id = @employee.bitemporal_id
        errors = []

        threads = 2.times.map do
          Thread.new do
            # Both threads terminate at the same point — the second thread
            # will see the already-terminated state and no-op.
            Employee.find(employee_id).terminate(termination_time: _05_01)
          rescue => e
            errors << e
          end
        end

        threads.each(&:join)

        expect(errors).to be_empty

        # Timeline should be consistent
        timeline = current_timeline(@employee)
        expect(valid_timeline?(timeline)).to be true
        expect(timeline.last[1]).to eq(_05_01)
      end
    end
  end

  # ==========================================================================
  # Category 12: Transaction & Record Accounting
  # ==========================================================================

  describe "transaction & record accounting" do

    # Test 12.1: Termination closes only affected records, creates truncated copy
    context "termination record accounting" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      it "closes affected records, leaves earlier untouched" do
        employee = Employee.find(@employee.id)
        termination_time = "2020/10/06".in_time_zone

        Timecop.freeze(termination_time) do
          employee.terminate(termination_time: _04_01)
        end

        # Records closed at termination_time: B (spans termination) and C (fully after)
        closed_by_termination = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: termination_time)
        expect(closed_by_termination.count).to eq(2)
        closed_names = closed_by_termination.pluck(:name).sort
        expect(closed_names).to eq(["B", "C"])

        # A record should be untouched (transaction_from unchanged)
        a_record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "A").first
        expect(a_record.transaction_from).not_to eq(termination_time)
      end
    end

    # Test 12.2: Transaction rollback on failure
    context "rollback on failure" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "rolls back all changes on failure" do
        employee = Employee.find(@employee.id)
        original_timeline = current_timeline(employee)

        # Force a failure by making save_without_bitemporal_callbacks! raise
        call_count = 0
        allow_any_instance_of(Employee).to receive(:save_without_bitemporal_callbacks!).and_wrap_original do |method, *args, **kwargs|
          call_count += 1
          if call_count >= 1
            raise ActiveRecord::RecordInvalid.new(Employee.new)
          end
          method.call(*args, **kwargs)
        end

        expect {
          employee.terminate(termination_time: _02_01)
        }.to raise_error(ActiveRecord::RecordInvalid)

        # Timeline should be unchanged (transaction rolled back)
        expect(current_timeline(employee)).to eq(original_timeline)
      end
    end

    # Test 12.3: Multi-entity isolation
    context "multi-entity isolation" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee1 = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee2 = Employee.create!(name: "B") }
        end
      end

      it "only affects the targeted entity" do
        employee1 = Employee.find(@employee1.id)
        employee2_timeline_before = current_timeline(@employee2)

        Timecop.freeze("2020/10/06") do
          employee1.terminate(termination_time: _03_01)
        end

        # Employee1 should be terminated
        expect(current_timeline(employee1)).to eq([
          [_01_01, _03_01, "A"]
        ])

        # Employee2 should be unchanged
        expect(current_timeline(@employee2)).to eq(employee2_timeline_before)
      end
    end
  end

  # ==========================================================================
  # Category 13: Timestamp Behavior
  # ==========================================================================

  describe "timestamp behavior" do

    # Test 13.1: created_at on termination records
    context "created_at on termination records" do
      before do
        @creation_time = "2020/10/01 12:00:00".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "sets created_at to termination time on truncated record" do
        employee = Employee.find(@employee.id)
        @termination_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(@termination_time) do
          employee.terminate(termination_time: _03_01)
        end

        # The truncated record (new copy with valid_to = Mar) should have
        # created_at = termination_time
        truncated_record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(valid_to: _03_01)
          .first

        expect(truncated_record.created_at).to eq(@termination_time)
      end
    end

    # Test 13.2: updated_at on cancel records
    context "updated_at on cancel records" do
      before do
        @creation_time = "2020/10/01 12:00:00".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
        @termination_time = "2020/10/02 12:00:00".in_time_zone
        Timecop.freeze(@termination_time) do
          find_ignoring_valid_time(@employee).terminate(termination_time: _03_01)
        end
      end

      it "sets updated_at to cancel time on restored records" do
        employee = find_ignoring_valid_time(@employee)
        @cancel_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(@cancel_time) do
          employee.cancel_termination
        end

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)

        current_records.each do |record|
          expect(record.updated_at).to eq(@cancel_time)
        end
      end
    end
  end
end
