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

  # Every row of the entity, each with its own key and every column
  def history(record)
    all_records(record)
      .map { |row| row.attributes.merge("swapped_id" => row.swapped_id) }
      .sort_by { |row| row["swapped_id"] }
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

    # Test 2.5: Forward shift preserves non-name attributes on trimmed segment
    context "forward shift preserves all attributes on trimmed segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) {
            @employee = Employee.create!(name: "Alice", emp_code: "E001")
          }
          ActiveRecord::Bitemporal.valid_at(_05_01) {
            @employee.update!(name: "Bob", emp_code: "E002")
          }
        end
      end

      # before: Alice/E001              Bob/E002
      #         |------------------------|----------->
      #         Jan                     May
      #
      # shift_genesis(new_valid_from: Mar)
      #                  ↓
      # after:  Alice/E001    Bob/E002
      #         |-------------|----------->
      #         Mar          May
      it "trimmed segment retains all original attributes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _03_01)
        end

        genesis_record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)
          .first

        expect(genesis_record.name).to eq("Alice")
        expect(genesis_record.emp_code).to eq("E001")
        expect(genesis_record.valid_from).to eq(_03_01)
        expect(genesis_record.valid_to).to eq(_05_01)
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

      it "returns true, no DB changes, same physical records" do
        employee = Employee.find(@employee.id)
        records_before = all_records(employee).count
        ids_before = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .pluck(:id).sort

        Timecop.freeze("2020/10/06") do
          result = employee.shift_genesis(new_valid_from: _03_01)
          expect(result).to eq(true)
        end

        expect(all_records(employee).count).to eq(records_before)

        ids_after = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .pluck(:id).sort
        expect(ids_after).to eq(ids_before)

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

      it "extends only the genesis segment, leaving no overlaps or gaps" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        timeline = current_timeline(employee)
        expect(timeline).to eq([
          [_01_01, _05_01, "A"],
          [_05_01, _07_01, "B"],
          [_07_01, infinity, "C"]
        ])
        expect(valid_timeline?(timeline)).to be true
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

      it "trims the timeline to start at the new genesis, leaving no overlaps or gaps" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.shift_genesis(new_valid_from: _04_01)
        end

        timeline = current_timeline(employee)
        expect(timeline).to eq([
          [_04_01, _05_01, "B"],
          [_05_01, _07_01, "C"],
          [_07_01, infinity, "D"]
        ])
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

        # Should have exactly 3 total records:
        # 1 original (closed at T1) + 1 from first shift (closed at T2) + 1 current from second shift
        total_records = all_records(employee).count
        expect(total_records).to eq(3)
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

        # The genesis is the date of whichever thread went last
        timeline = current_timeline(@employee)
        expect(timeline).to eq([[_03_01, infinity, "A"]]).or eq([[_01_01, infinity, "A"]])
        expect(no_overlaps?(timeline)).to be true
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

  # ==========================================================================
  # Category 9: Transaction & Record Accounting
  # ==========================================================================

  describe "transaction & record accounting" do

    # Test 9.1: Backward shift closes exactly 1 record, creates 1 new
    context "backward shift record accounting" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      it "closes exactly 1 record, creates 1 new, leaves untouched records alone" do
        employee = Employee.find(@employee.id)
        shift_time = "2020/10/06".in_time_zone

        Timecop.freeze(shift_time) do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        # Exactly 1 record closed at shift_time (the old genesis A)
        closed_by_shift = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: shift_time)
        expect(closed_by_shift.count).to eq(1)
        expect(closed_by_shift.first.name).to eq("A")

        # Current records: new A has transaction_from = shift_time, B is untouched
        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        new_a = current_records.find { |r| r.name == "A" }
        old_b = current_records.find { |r| r.name == "B" }

        expect(new_a.transaction_from).to eq(shift_time)
        expect(old_b.transaction_from).not_to eq(shift_time)  # B untouched
      end
    end

    # Test 9.2: Transaction rollback on failure
    context "rollback on failure" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
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
          employee.shift_genesis(new_valid_from: _01_01)
        }.to raise_error(ActiveRecord::RecordInvalid)

        # Timeline should be unchanged (transaction rolled back)
        expect(current_timeline(employee)).to eq(original_timeline)
      end
    end

    # Test 9.3: Multi-entity isolation
    context "multi-entity isolation" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee1 = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee2 = Employee.create!(name: "B") }
        end
      end

      it "only affects the targeted entity" do
        employee1 = Employee.find(@employee1.id)
        employee2_timeline_before = current_timeline(@employee2)

        Timecop.freeze("2020/10/06") do
          employee1.shift_genesis(new_valid_from: _01_01)
        end

        # Employee1 should be shifted
        expect(current_timeline(employee1)).to eq([
          [_01_01, infinity, "A"]
        ])

        # Employee2 should be unchanged
        expect(current_timeline(@employee2)).to eq(employee2_timeline_before)
      end
    end
  end

  # ==========================================================================
  # Category 10: Timestamp Behavior
  # ==========================================================================

  describe "timestamp behavior" do

    # Test 10.1: created_at on shift records
    context "created_at on shift records" do
      before do
        @creation_time = "2020/10/01 12:00:00".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "sets created_at to shift time, not inherited from original" do
        employee = Employee.find(@employee.id)
        @shift_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(@shift_time) do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        new_record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .first

        expect(new_record.created_at).to eq(@shift_time)
      end
    end

    # Test 10.2: updated_at on shift records
    context "updated_at on shift records" do
      before do
        @creation_time = "2020/10/01 12:00:00".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "sets updated_at to shift time on all current records" do
        employee = Employee.find(@employee.id)
        @shift_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(@shift_time) do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)

        current_records.each do |record|
          expect(record.updated_at).to eq(@shift_time)
        end
      end
    end
  end

  # ==========================================================================
  # Category 11: cancel_shift_genesis
  # ==========================================================================

  describe "cancel_shift_genesis" do

    # Test 11.1: Cancel after backward shift restores original genesis
    #
    #   t1: CREATE    |---A--->∞          genesis = Mar
    #   t2: SHIFT ←   |---A--->∞          genesis = Jan
    #   t3: CANCEL    |---A--->∞          genesis = Mar (restored)
    context "cancel after backward shift" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _01_01)
        end
      end

      it "restores original genesis" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/03") do
          employee.cancel_shift_genesis
        end

        expect(current_timeline(employee)).to eq([
          [_03_01, infinity, "A"]
        ])
      end
    end

    # Test 11.2: Cancel after forward shift recovers ALL removed segments
    #
    #   t1: CREATE    |---A---|---B---|---C--->∞    genesis = Jan
    #   t2: SHIFT →             |---B---|---C--->∞  genesis = Apr (A removed, B trimmed)
    #   t3: CANCEL    |---A---|---B---|---C--->∞    genesis = Jan (full restoration)
    context "cancel after forward shift" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/02") do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _04_01)
        end
      end

      it "recovers all removed segments" do
        employee = Employee.find(@employee.id)

        # Before cancel: A is gone, B trimmed to [Apr, May)
        expect(current_timeline(employee)).to eq([
          [_04_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])

        Timecop.freeze("2020/10/03") do
          employee.cancel_shift_genesis
        end

        # After cancel: full original timeline restored
        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])
      end
    end

    # Test 11.3: Cancel on never-shifted entity is no-op
    context "cancel on never-shifted entity" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "returns true without DB changes" do
        employee = Employee.find(@employee.id)
        records_before = all_records(employee).count

        Timecop.freeze("2020/10/02") do
          result = employee.cancel_shift_genesis
          expect(result).to eq(true)
        end

        expect(all_records(employee).count).to eq(records_before)
        expect(current_timeline(employee)).to eq([
          [_01_01, infinity, "A"]
        ])
      end
    end

    # Test 11.4: shift → cancel → shift → cancel round-trip
    context "shift → cancel → shift → cancel round-trip" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
        end
      end

      it "each cancel restores the original genesis" do
        employee = Employee.find(@employee.id)
        original_timeline = current_timeline(employee)

        # First shift
        Timecop.freeze("2020/10/02") do
          employee.shift_genesis(new_valid_from: _01_01)
        end
        expect(current_timeline(employee).first[0]).to eq(_01_01)

        # First cancel
        Timecop.freeze("2020/10/03") do
          employee.cancel_shift_genesis
        end
        expect(current_timeline(employee)).to eq(original_timeline)

        # Second shift (forward this time)
        Timecop.freeze("2020/10/04") do
          employee.shift_genesis(new_valid_from: _04_01)
        end
        expect(current_timeline(employee).first[0]).to eq(_04_01)

        # Second cancel
        Timecop.freeze("2020/10/05") do
          employee.cancel_shift_genesis
        end
        expect(current_timeline(employee)).to eq(original_timeline)
      end
    end

    # Test 11.5: shift → update → cancel (refuses, update kept)
    context "shift → update → cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "refuses, keeping the update made after the shift" do
        employee = Employee.find(@employee.id)

        # Shift forward (removes A, trims B)
        Timecop.freeze("2020/10/02") do
          employee.shift_genesis(new_valid_from: _02_01)
        end

        # Update after shift
        Timecop.freeze("2020/10/03") do
          ActiveRecord::Bitemporal.valid_at(_04_01) { employee.update!(name: "C") }
        end

        expect(current_timeline(employee)).to include(
          [_04_01, infinity, "C"]
        )

        # Cancel — refuses rather than discard the update (C)
        expect {
          Timecop.freeze("2020/10/04") do
            employee.cancel_shift_genesis
          end
        }.to raise_error(ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError)

        expect(current_timeline(employee)).to eq([
          [_02_01, _03_01, "A"],
          [_03_01, _04_01, "B"],
          [_04_01, infinity, "C"]
        ])
      end
    end

    # A cancel restores the timeline as it stood just before the genesis shift it undoes.
    # When anything was recorded for the entity after that shift, it refuses rather than
    # discard it: it raises RecordedSinceGenesisShiftError, which a rescue of
    # PreShiftGenesisStateNotFoundError catches, writes nothing, and leaves self as it was.
    describe "what was recorded after the shift" do
      let(:shifted_at) { "2020/10/02".in_time_zone }

      #   A |Jan, Mar)  B |Mar, ∞), genesis shifted forward to Feb:
      #   A |Feb, Mar)  B |Mar, ∞)
      let!(:employee_id) {
        id = Timecop.freeze("2020/10/01") {
          employee = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { employee.update!(name: "B") }
          employee.id
        }
        Timecop.freeze(shifted_at) { Employee.find_at_time(_03_01, id).shift_genesis(new_valid_from: _02_01) }
        id
      }
      let(:employee) { Employee.find_at_time(_02_01, employee_id) }

      subject(:cancel) { Timecop.freeze("2020/10/06") { employee.cancel_shift_genesis } }

      # Each write below happens on 10/03, between the shift and the cancel
      def record_after_shift(&block)
        Timecop.freeze("2020/10/03") { block.call(Employee.find_at_time(_02_01, employee_id)) }
      end

      shared_examples "a refused cancel" do
        it "raises RecordedSinceGenesisShiftError" do
          expect { cancel }.to raise_error(
            ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError,
            /recorded .* after its genesis shift; cancelling it would discard them/
          )
        end

        it "is caught by a rescue of PreShiftGenesisStateNotFoundError" do
          rescued = begin
            cancel
          rescue ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError => e
            e
          end

          expect(rescued).to be_a ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError
        end

        it "writes nothing" do
          history_before = history(employee)

          expect { cancel }.to raise_error(ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError)
          expect(history(employee)).to eq history_before
        end

        it "leaves self and its unsaved changes as they were" do
          employee.emp_code = "PENDING"
          attributes = employee.attributes
          swapped_id = employee.swapped_id

          expect { cancel }.to raise_error(ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError)
          expect(employee.attributes).to eq attributes
          expect(employee.swapped_id).to eq swapped_id
          expect(employee.changes).to eq("emp_code" => [nil, "PENDING"])
        end
      end

      context "when nothing was recorded" do
        it "restores the timeline as it stood before the shift" do
          expect(cancel).to be true
          expect(current_timeline(employee)).to eq [
            [_01_01, _03_01, "A"],
            [_03_01, infinity, "B"],
          ]
        end
      end

      context "when a correct changed the segment the shift trimmed" do
        before { record_after_shift { |e| e.correct(valid_from: _02_01, valid_to: _03_01, name: "X") } }

        it_behaves_like "a refused cancel"
      end

      context "when a correct changed a segment after the one the shift trimmed" do
        before { record_after_shift { |e| e.correct(valid_from: _04_01, valid_to: _05_01, name: "X") } }

        it_behaves_like "a refused cancel"
      end

      context "when an upstream update! changed it" do
        before {
          record_after_shift { |e|
            ActiveRecord::Bitemporal.valid_at(_04_01) { Employee.find(e.id).update!(name: "X") }
          }
        }

        it_behaves_like "a refused cancel"
      end

      # Cancelling would bring back the pre-shift timeline, which runs to infinity
      context "when a terminate ended it" do
        before { record_after_shift { |e| e.terminate(termination_time: _06_01) } }

        it_behaves_like "a refused cancel"
      end

      # Terminating at a segment boundary closes rows and inserts none
      context "when a terminate ended it at a segment boundary" do
        before { record_after_shift { |e| e.terminate(termination_time: _03_01) } }

        it_behaves_like "a refused cancel"
      end

      context "when a cancel and a second shift were recorded" do
        before {
          record_after_shift(&:cancel_shift_genesis)
          Timecop.freeze("2020/10/04") { Employee.find_at_time(_02_01, employee_id).shift_genesis(new_valid_from: _02_01) }
        }

        it "undoes the second shift" do
          expect(cancel).to be true
          expect(current_timeline(employee)).to eq [
            [_01_01, _03_01, "A"],
            [_03_01, infinity, "B"],
          ]
        end
      end

      # An upstream update! that sets the values the next segment already has leaves a seam:
      #   A |Jan, Mar)  B |Mar, May)  B |May, ∞)
      # Shifting genesis to Apr trims B |Mar, May) to B |Apr, May) and merges that with
      # B |May, ∞), so the shift closes all three rows and inserts B |Apr, ∞) at its own
      # transaction time.
      context "when the shift merged a seam" do
        let!(:employee_id) {
          id = Timecop.freeze("2020/10/01") {
            employee = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
            ActiveRecord::Bitemporal.valid_at(_05_01) { employee.update!(name: "B") }
            employee.id
          }
          Timecop.freeze("2020/10/01 12:00") {
            ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(id).update!(name: "B") }
          }
          Timecop.freeze(shifted_at) { Employee.find_at_time(_05_01, id).shift_genesis(new_valid_from: _04_01) }
          id
        }
        let(:employee) { Employee.find_at_time(_05_01, employee_id) }

        it "doesn't count the rows it wrote as recorded after it" do
          expect(all_records(employee).where(transaction_to: shifted_at).pluck(:valid_from, :valid_to)).to contain_exactly(
            [_01_01, _03_01],
            [_03_01, _05_01],
            [_05_01, infinity],
          )
          expect(all_records(employee).where(transaction_from: shifted_at).pluck(:valid_from, :valid_to, :transaction_to)).to eq [
            [_04_01, infinity, tt_infinity],
          ]

          expect(cancel).to be true
          # The cancel restores the seam merged, as every operation leaves a timeline
          expect(current_timeline(employee)).to eq [
            [_01_01, _03_01, "A"],
            [_03_01, infinity, "B"],
          ]
        end
      end
    end

    # A cancel restores the most recent timeline at the original genesis, as it stood just
    # before the genesis moved off it, as cancel_termination restores the most recent
    # unterminated one. A second shift is recorded after that, so the cancel refuses. Once the
    # genesis is the original one again, there's nothing to cancel.
    describe "the timeline it restores" do
      let(:_2019_12_01) { "2019/12/01".in_time_zone }

      #   A |Jan, Mar)  B |Mar, May)  C |May, ∞)   genesis Jan, recorded on 2020-10-01
      let!(:employee_id) {
        Timecop.freeze("2020/10/01") {
          employee = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { employee.update!(name: "C") }
          employee.id
        }
      }
      let(:employee) { Employee.find_at_time(_05_01, employee_id) }
      let(:original_timeline) { [[_01_01, _03_01, "A"], [_03_01, _05_01, "B"], [_05_01, infinity, "C"]] }

      subject(:cancel) { Timecop.freeze("2020/10/06") { employee.cancel_shift_genesis } }

      def shift_genesis_on(day, new_valid_from)
        Timecop.freeze(day) { Employee.find_at_time(_05_01, employee_id).shift_genesis(new_valid_from: new_valid_from) }
      end

      context "after one shift" do
        before { shift_genesis_on("2020/10/02", _04_01) }

        it "restores the original timeline" do
          expect(cancel).to be true
          expect(current_timeline(employee)).to eq original_timeline
        end

        it "leaves nothing for a second cancel to write" do
          cancel
          history_before = history(employee)

          expect(Timecop.freeze("2020/10/07") { employee.cancel_shift_genesis }).to be true
          expect(history(employee)).to eq history_before
          expect(current_timeline(employee)).to eq original_timeline
        end
      end

      context "after a backward shift" do
        before { shift_genesis_on("2020/10/02", _2019_12_01) }

        it "restores the original timeline, without the extension" do
          expect(current_timeline(employee).first).to eq [_2019_12_01, _03_01, "A"]

          expect(cancel).to be true
          expect(current_timeline(employee)).to eq original_timeline
        end
      end

      context "after two shifts" do
        before {
          shift_genesis_on("2020/10/02", _02_01)
          shift_genesis_on("2020/10/03", _04_01)
        }

        # The timeline at the original genesis ended with the first shift, and the second was
        # recorded after it
        it "refuses and writes nothing" do
          history_before = history(employee)

          expect { cancel }.to raise_error(ActiveRecord::Bitemporal::RecordedSinceGenesisShiftError)
          expect(history(employee)).to eq history_before
          expect(current_timeline(employee)).to eq [[_04_01, _05_01, "B"], [_05_01, infinity, "C"]]
        end
      end

      context "after a shift, its cancel and a second shift" do
        before {
          shift_genesis_on("2020/10/02", _02_01)
          Timecop.freeze("2020/10/03") { Employee.find_at_time(_05_01, employee_id).cancel_shift_genesis }
          shift_genesis_on("2020/10/04", _04_01)
        }

        it "restores the original timeline" do
          expect(cancel).to be true
          expect(current_timeline(employee)).to eq original_timeline
        end
      end

      # The backward shift extends B, the first segment left, back to Jan: A doesn't come back
      context "after a forward shift and a backward shift to the original genesis" do
        before {
          shift_genesis_on("2020/10/02", _04_01)
          shift_genesis_on("2020/10/03", _01_01)
        }

        it "finds the genesis not shifted and writes nothing" do
          history_before = history(employee)

          expect(employee.shifted_genesis?).to be false
          expect(cancel).to be true
          expect(history(employee)).to eq history_before
          expect(current_timeline(employee)).to eq [[_01_01, _05_01, "B"], [_05_01, infinity, "C"]]
        end
      end
    end

    # Test 11.6: Double cancel is no-op
    context "double cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _01_01)
        end
      end

      it "second cancel is no-op" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/03") do
          employee.cancel_shift_genesis
        end

        records_after_first_cancel = all_records(employee).count
        timeline_after_first_cancel = current_timeline(employee)

        Timecop.freeze("2020/10/04") do
          result = employee.cancel_shift_genesis
          expect(result).to eq(true)
        end

        # No additional records created
        expect(all_records(employee).count).to eq(records_after_first_cancel)
        expect(current_timeline(employee)).to eq(timeline_after_first_cancel)
      end
    end

    # Test 11.7: shifted_genesis? predicate
    context "shifted_genesis? predicate" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "returns false for never-shifted entity" do
        employee = Employee.find(@employee.id)
        expect(employee.shifted_genesis?).to be false
      end

      it "returns true after shift" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/02") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        expect(employee.shifted_genesis?).to be true
      end

      it "returns false after cancel" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/02") do
          employee.shift_genesis(new_valid_from: _01_01)
        end

        Timecop.freeze("2020/10/03") do
          employee.cancel_shift_genesis
        end

        expect(employee.shifted_genesis?).to be false
      end
    end

    # Test 11.8: Concurrent cancel_shift_genesis (locking serialization)
    context "concurrent cancel_shift_genesis", use_truncation: true do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _01_01)
        end
      end

      it "both succeed via locking serialization" do
        employee_id = @employee.bitemporal_id
        errors = []

        threads = 2.times.map do
          Thread.new do
            Employee.find(employee_id).cancel_shift_genesis
          rescue => e
            errors << e
          end
        end

        threads.each(&:join)
        expect(errors).to be_empty

        # The second cancel finds the original genesis already restored and does nothing
        timeline = current_timeline(@employee)
        expect(timeline).to eq([[_03_01, infinity, "A"]])
        expect(no_overlaps?(timeline)).to be true
      end
    end

    # Test 11.9: Audit trail after cancel
    context "audit trail after cancel" do
      before do
        @t0 = "2020/10/01".in_time_zone
        @t1 = "2020/10/02".in_time_zone
        @t2 = "2020/10/03".in_time_zone

        Timecop.freeze(@t0) do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze(@t1) do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _01_01)
        end
        Timecop.freeze(@t2) do
          Employee.find(@employee.id).cancel_shift_genesis
        end
      end

      it "preserves full history through transaction time" do
        employee = @employee

        # At t0: genesis = Mar
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.transaction_at(@t0) do
            ActiveRecord::Bitemporal.valid_at(_03_01) do
              expect(Employee.find(employee.id).name).to eq("A")
            end
          end
        end

        # At t1 (after shift): genesis = Jan
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.transaction_at(@t1) do
            ActiveRecord::Bitemporal.valid_at(_02_01) do
              expect(Employee.find(employee.id).name).to eq("A")
            end
          end
        end

        # At t2 (after cancel): genesis = Mar (restored)
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.valid_at(_02_01) do
            expect(Employee.find_at_time(_02_01, employee.id)).to be_nil
          end
          ActiveRecord::Bitemporal.valid_at(_03_01) do
            expect(Employee.find(employee.id).name).to eq("A")
          end
        end
      end
    end

    # Test 11.10: Timeline integrity after cancel
    context "timeline integrity after cancel" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/02") do
          Employee.find(@employee.id).shift_genesis(new_valid_from: _04_01)
        end
        Timecop.freeze("2020/10/03") do
          Employee.find(@employee.id).cancel_shift_genesis
        end
      end

      it "restores all three segments, leaving no overlaps or gaps" do
        timeline = current_timeline(@employee)
        expect(timeline).to eq([
          [_01_01, _03_01, "A"],
          [_03_01, _05_01, "B"],
          [_05_01, infinity, "C"]
        ])
        expect(valid_timeline?(timeline)).to be true
      end
    end
  end
end
