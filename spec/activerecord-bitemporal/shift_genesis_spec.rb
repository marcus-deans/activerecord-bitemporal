# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Shift Genesis (#shift_genesis method)" do
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
  # Category 1: Backward Shift
  # ==========================================================================

  describe "backward shift (extending timeline earlier)" do

    # Test 1.1: Single segment backward shift
    context "single segment timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # before: A
      #         |----------------------------------------->
      #         Mar
      #
      # shift_genesis(new_valid_from: Jan)
      #                  ↓
      # after:  A
      #         |----------------------------------------->
      #         Jan
      it "extends valid_from backward, preserving attributes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, infinity, "A"]
        ])
      end
    end

    # Test 1.2: Multi-segment backward shift
    context "multi-segment timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|----------->
      #         Mar          May
      #
      # shift_genesis(new_valid_from: Jan)
      #                  ↓
      # after:  A                   B
      #         |-------------------|----------->
      #         Jan                May
      it "only changes genesis, future segments untouched" do
        employee = Employee.find(@employee.id)
        b_record_before = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "B").first

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _05_01, "A"],
          [_05_01, infinity, "B"]
        ])

        # Verify B's transaction_from is unchanged (it wasn't touched)
        b_record_after = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "B").first
        expect(b_record_after.transaction_from).to eq(b_record_before.transaction_from)
      end
    end

    # Test 1.3: Timeline with prior corrections
    context "timeline with prior corrections" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/03") do
          Employee.find(@employee.id).correct(valid_from: _04_01, valid_to: _05_01, name: "X")
        end
      end

      # before: A        X    B
      #         |--------|----|--->
      #         Mar     Apr  May
      #
      # shift_genesis(new_valid_from: Jan)
      #                  ↓
      # after:  A              X    B
      #         |--------------|----|--->
      #         Jan           Apr  May
      it "extends genesis, corrections untouched" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _04_01, "A"],
          [_04_01, _05_01, "X"],
          [_05_01, infinity, "B"]
        ])
      end
    end

    # Test 1.4: Many stacked changes
    context "many stacked changes" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_04_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
          ActiveRecord::Bitemporal.valid_at(_06_01) { @employee.update!(name: "D") }
        end
      end

      it "only changes genesis, all others untouched" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _04_01, "A"],
          [_04_01, _05_01, "B"],
          [_05_01, _06_01, "C"],
          [_06_01, infinity, "D"]
        ])
      end
    end

    # Test 1.5: Bounded timeline (finite valid_to)
    context "bounded timeline with finite valid_to" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.destroy }
        end
      end

      # before: A
      #         |------------|
      #         Mar         May
      #
      # shift_genesis(new_valid_from: Jan)
      #                  ↓
      # after:  A
      #         |----------------------|
      #         Jan                   May
      it "preserves finite valid_to" do
        employee = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .first

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        timeline = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)
          .pluck(:valid_from, :valid_to, :name)

        expect(timeline).to eq([
          [_01_01, _05_01, "A"]
        ])
      end
    end
  end

  # ==========================================================================
  # Category 2: Forward Shift
  # ==========================================================================

  describe "forward shift (trimming timeline start)" do

    # Test 2.1: Forward within genesis segment
    context "forward within genesis segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      # before: A                   B
      #         |-------------------|----------->
      #         Jan                May
      #
      # shift_genesis(new_valid_from: Feb)
      #                  ↓
      # after:  A              B
      #         |--------------|----------->
      #         Feb           May
      it "trims genesis, future segments untouched" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _02_01)
        end

        expect(current_timeline(employee)).to eq([
          [_02_01, _05_01, "A"],
          [_05_01, infinity, "B"]
        ])
      end
    end

    # Test 2.2: Forward past one change point
    context "forward past one change point" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May
      #
      # shift_genesis(new_valid_from: Apr)
      #                  ↓
      # after:       B    C
      #              |----|----------->
      #             Apr  May
      it "closes genesis, trims spanning segment" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _04_01)
        end

        expect(current_timeline(employee)).to eq([
          [_04_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])
      end
    end

    # Test 2.3: Forward to exact segment boundary (Edge 8)
    context "forward to exact segment boundary" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May
      #
      # shift_genesis(new_valid_from: Mar)
      #                  ↓
      # after:  B             C
      #         |-------------|----------->
      #         Mar          May
      it "B becomes genesis untouched, verify transaction_from unchanged" do
        employee = Employee.find(@employee.id)
        b_record_before = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "B").first

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_03_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])

        # Verify B was NOT closed and re-created (transaction_from unchanged)
        b_record_after = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .where(name: "B").first
        expect(b_record_after.transaction_from).to eq(b_record_before.transaction_from)
      end
    end

    # Test 2.4: Forward past multiple change points
    context "forward past multiple change points" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
          ActiveRecord::Bitemporal.valid_at(_07_01) { @employee.update!(name: "D") }
        end
      end

      # before: A       B       C       D
      #         |-------|-------|-------|-------->
      #         Jan    Mar     May     Jul
      #
      # shift_genesis(new_valid_from: Jun)
      #                  ↓
      # after:      C  D
      #             |--|-------->
      #            Jun Jul
      it "closes multiple segments, trims spanning one" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _06_01)
        end

        expect(current_timeline(employee)).to eq([
          [_06_01, _07_01, "C"],
          [_07_01, infinity, "D"]
        ])
      end
    end

    # Test 2.5: Forward to intermediate boundary
    context "forward to intermediate segment boundary" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May
      #
      # shift_genesis(new_valid_from: Mar)
      #                  ↓
      # after:  B             C
      #         |-------------|----------->
      #         Mar          May
      it "A closed, B untouched becomes genesis" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_03_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])
      end
    end

    # Test 2.6: Forward to last segment boundary
    context "forward to last segment boundary" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      # before: A             B             C
      #         |-------------|-------------|----------->
      #         Jan          Mar           May
      #
      # shift_genesis(new_valid_from: May)
      #                  ↓
      # after:  C
      #         |----------->
      #         May
      it "A,B closed, C untouched becomes genesis" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _05_01)
        end

        expect(current_timeline(employee)).to eq([
          [_05_01, infinity, "C"]
        ])
      end
    end

    # Test 2.7: Forward on single segment
    context "forward on single segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # before: A
      #         |------------------------------------------->
      #         Jan
      #
      # shift_genesis(new_valid_from: Mar)
      #                  ↓
      # after:  A
      #         |------------------------------>
      #         Mar
      it "trims within single segment" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_03_01, infinity, "A"]
        ])
      end
    end
  end

  # ==========================================================================
  # Category 3: No-op and Errors
  # ==========================================================================

  describe "no-op and error cases" do

    # Test 3.1: Shift to current genesis date (no-op)
    context "shift to current genesis date" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "returns true, no DB changes" do
        employee = Employee.find(@employee.id)
        records_before = all_records(employee).count

        Timecop.freeze("2020/10/06") do
          result = employee.shift_genesis(new_valid_from: _03_01)
          expect(result).to eq(true)
        end

        expect(all_records(employee).count).to eq(records_before)
        expect(current_timeline(employee)).to eq([
          [_03_01, infinity, "A"]
        ])
      end
    end

    # Test 3.2: Entity with no current-knowledge records
    context "entity with no current-knowledge records" do
      it "raises RecordNotFound" do
        # Build an employee instance with a bitemporal_id that has no DB records
        employee = Employee.new(name: "ghost", bitemporal_id: 99999)

        expect {
          employee.shift_genesis(new_valid_from: _01_01)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # Test 3.3: Shift past all segments on bounded timeline
    context "shift past all segments" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.destroy }
        end
      end

      it "raises ArgumentError, no DB changes" do
        employee = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .first

        original_timeline = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)
          .pluck(:valid_from, :valid_to, :name)

        expect {
          employee.shift_genesis(new_valid_from: _05_01)
        }.to raise_error(ArgumentError, /erase all segments/)

        # Verify no changes
        after_timeline = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)
          .pluck(:valid_from, :valid_to, :name)

        expect(after_timeline).to eq(original_timeline)
      end
    end

    # Test 3.4: Attributes unchanged (purely temporal)
    context "attributes unchanged" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) {
            @employee = Employee.create!(name: "Alice", emp_code: "E001")
          }
        end
      end

      it "preserves all attributes exactly" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .first

        expect(record.name).to eq("Alice")
        expect(record.emp_code).to eq("E001")
        expect(record.valid_from).to eq(_01_01)
      end
    end
  end

  # ==========================================================================
  # Category 4: Audit Trail
  # ==========================================================================

  describe "audit trail" do

    # Test 4.1: Backward shift creates proper audit trail
    context "backward shift audit trail" do
      before do
        @t0 = "2020/10/01".in_time_zone
        Timecop.freeze(@t0) do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "old knowledge sees no record before genesis, new knowledge sees record" do
        employee = Employee.find(@employee.id)
        @t1 = "2020/10/06".in_time_zone

        Timecop.freeze(@t1) do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        # At T0 (before shift): valid_at(Feb) should return nil (before genesis)
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.transaction_at(@t0) do
            ActiveRecord::Bitemporal.valid_at(_02_01) do
              expect(Employee.find_at_time(_02_01, employee.id)).to be_nil
            end
          end
        end

        # At T1 (after shift): valid_at(Feb) should return the record
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.valid_at(_02_01) do
            expect(Employee.find(employee.id).name).to eq("A")
          end
        end
      end
    end

    # Test 4.2: Forward shift creates proper audit trail
    context "forward shift audit trail" do
      before do
        @t0 = "2020/10/01".in_time_zone
        Timecop.freeze(@t0) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "old knowledge sees record in removed period, new knowledge does not" do
        employee = Employee.find(@employee.id)
        @t1 = "2020/10/06".in_time_zone

        Timecop.freeze(@t1) do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        # At T0 (before shift): valid_at(Feb) should return the record
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.transaction_at(@t0) do
            ActiveRecord::Bitemporal.valid_at(_02_01) do
              expect(Employee.find(employee.id).name).to eq("A")
            end
          end
        end

        # At T1 (after shift): valid_at(Feb) should return nil
        Timecop.freeze(@t1) do
          ActiveRecord::Bitemporal.valid_at(_02_01) do
            expect(Employee.find_at_time(_02_01, employee.id)).to be_nil
          end
        end
      end
    end
  end

  # ==========================================================================
  # Category 5: Timeline Integrity
  # ==========================================================================

  describe "timeline integrity" do

    # Test 5.1: No overlaps after backward shift on multi-segment timeline
    context "backward shift on multi-segment timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_07_01) { @employee.update!(name: "C") }
        end
      end

      it "maintains no overlaps and no gaps" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        timeline = current_timeline(employee)
        expect(valid_timeline?(timeline)).to be true
        expect(timeline.size).to eq(3)
      end
    end

    # Test 5.2: No overlaps or gaps after forward shift past multiple segments
    context "forward shift past multiple segments" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
          ActiveRecord::Bitemporal.valid_at(_07_01) { @employee.update!(name: "D") }
        end
      end

      it "maintains no overlaps and no gaps" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _04_01)
        end

        timeline = current_timeline(employee)
        expect(valid_timeline?(timeline)).to be true
      end
    end
  end

  # ==========================================================================
  # Category 6: Composition with correct()
  # ==========================================================================

  describe "composition with correct()" do

    # Test 6.1: Backdate then correct in extended range
    context "backdate then correct in extended range" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "allows correction in newly extended range" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        Timecop.freeze("2020/10/07") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, infinity, "A"]
        ])
      end
    end

    # Test 6.2: Correct then backdate
    context "correct then backdate" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      it "correction untouched by subsequent backdate" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _04_01, valid_to: _05_01, name: "X")
        end

        Timecop.freeze("2020/10/07") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _04_01, "A"],
          [_04_01, _05_01, "X"],
          [_05_01, infinity, "B"]
        ])
      end
    end

    # Test 6.3: Forward shift then correct outside new range
    context "forward shift then correct outside new range" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      it "raises RecordNotFound for correction before new genesis" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        expect {
          Timecop.freeze("2020/10/07") do
            employee.correct(valid_from: _02_01, name: "X")
          end
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # Test 6.4: Sequential backward shifts
    context "sequential backward shifts" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "each creates audit trail entry" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        expect(current_timeline(employee)).to eq([
          [_03_01, infinity, "A"]
        ])

        Timecop.freeze("2020/10/07") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, infinity, "A"]
        ])

        # Should have historical records from each shift
        total_records = all_records(employee).count
        expect(total_records).to be >= 3  # original + 2 shifts = at least 3 closed + 1 current
      end
    end
  end

  # ==========================================================================
  # Category 7: Concurrency
  # ==========================================================================

  describe "concurrency" do

    # Test 7.1: Two threads shift same entity
    context "two threads shift same entity simultaneously", use_truncation: true do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "both succeed via locking serialization" do
        employee_id = @employee.bitemporal_id
        errors = []

        threads = 2.times.map do |i|
          Thread.new do
            new_date = i == 0 ? _03_01 : _01_01
            Employee.find(employee_id).shift_genesis(new_valid_from: new_date)
          rescue => e
            errors << e
          end
        end

        threads.each(&:join)

        expect(errors).to be_empty

        # Timeline should be consistent
        timeline = current_timeline(@employee)
        expect(no_overlaps?(timeline)).to be true
        expect(timeline.size).to eq(1)
      end
    end
  end

  # ==========================================================================
  # Category 8: Self-update
  # ==========================================================================

  describe "self-update after shift" do

    # Test 8.1: self.valid_from updated after backward shift
    context "backward shift" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "updates self.valid_from" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(employee.valid_from).to eq(_01_01)
      end
    end

    # Test 8.2: self.valid_from updated after forward shift to exact boundary
    context "forward shift to exact boundary (untouched record)" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "updates self to point at untouched record" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        # self should now point at B (which starts at Mar and is the current record)
        expect(employee.valid_from).to eq(_03_01)
      end
    end
  end
end
