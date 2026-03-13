# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Cascade Correction (#correct method)" do
  # ==========================================================================
  # Test Helpers
  # ==========================================================================

  # Date helpers (Valid Time points)
  let(:_01_01) { "2020/01/01".in_time_zone }
  let(:_02_01) { "2020/02/01".in_time_zone }
  let(:_02_15) { "2020/02/15".in_time_zone }
  let(:_03_01) { "2020/03/01".in_time_zone }
  let(:_04_01) { "2020/04/01".in_time_zone }
  let(:_04_15) { "2020/04/15".in_time_zone }
  let(:_05_01) { "2020/05/01".in_time_zone }
  let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
  let(:tt_infinity) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }

  # Get current timeline (records with open transaction_to at current TT)
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

  # Timeline invariant helpers for validating bitemporal consistency
  # Returns true if no valid time periods overlap in the current timeline
  def no_overlaps?(timeline)
    return true if timeline.size <= 1
    timeline.each_cons(2).all? do |(_, valid_to_a, _), (valid_from_b, _, _)|
      valid_to_a <= valid_from_b
    end
  end

  # Returns true if there are no gaps in the current timeline
  def no_gaps?(timeline)
    return true if timeline.size <= 1
    timeline.each_cons(2).all? do |(_, valid_to_a, _), (valid_from_b, _, _)|
      valid_to_a == valid_from_b
    end
  end

  # Returns true if timeline is contiguous (no gaps) and non-overlapping
  def valid_timeline?(timeline)
    no_overlaps?(timeline) && no_gaps?(timeline)
  end

  # ==========================================================================
  # Test Category 1: Bounded Corrections (explicit valid_to)
  # ==========================================================================

  describe "#correct with explicit valid_to (bounded correction)" do

    # Test 1.1: Basic bounded correction spanning multiple records
    # -------------------------------------------------------------------------
    # This is the core cascade correction scenario from PROBLEM_ANALYSIS.md:
    # Correct a period that spans across multiple existing timeline segments.
    #
    # The correction should:
    # 1. Trim the first record that starts before valid_from
    # 2. Insert the correction record for [valid_from, valid_to)
    # 3. Trim records that overlap with valid_to
    # 4. Preserve records entirely after valid_to (CASCADE!)
    # -------------------------------------------------------------------------
    context "correction spans multiple existing records" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-May), C (May-∞)
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
      # correct(valid_from: Feb, valid_to: Apr, name: "X")
      #                  ↓
      # after:  A    X             B    C
      #         |----|-------------|----|--->
      #         Jan  Feb          Apr  May
      it "corrects the period while preserving future changes (CASCADE)" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
        end

        # Verify new timeline
        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Trimmed (was Jan-Mar, now Jan-Feb)
          [_02_01, _04_01, "X"],   # CORRECTION
          [_04_01, _05_01, "B"],   # Trimmed (was Mar-May, now Apr-May)
          [_05_01, infinity, "C"]  # PRESERVED (CASCADE)
        ])
      end

      # Verify transaction time is properly updated
      it "closes old records and creates new ones with current transaction time" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
        end

        # Records that were current before correction should now be closed at correction_time
        # Only records overlapping the correction range [Feb, Apr) are closed: A and B
        # C (May-∞) is fully after the correction and untouched
        closed_by_correction = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: correction_time)

        expect(closed_by_correction.count).to eq(2)

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        # Modified records have transaction_from = correction_time
        modified = current_records.select { |r| r.name != "C" }
        modified.each { |r| expect(r.transaction_from).to eq(correction_time) }

        # Untouched record C retains original transaction_from
        untouched_c = current_records.find { |r| r.name == "C" }
        expect(untouched_c.transaction_from).not_to eq(correction_time)
      end
    end

    # Test 1.2: Bounded correction entirely within single record
    # -------------------------------------------------------------------------
    # Correct a period that falls entirely within one existing record.
    # The original record should be split into three parts:
    # [before, correction_start) | [correction_start, correction_end) | [correction_end, original_end)
    # -------------------------------------------------------------------------
    context "correction falls entirely within single record" do
      before do
        # Create timeline: A (Jan-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # before: A
      #         |------------------------------------------->
      #         Jan
      #
      # correct(valid_from: Feb, valid_to: Mar, name: "X")
      #                  ↓
      # after:  A    X    A
      #         |----|----|------------------------------>
      #         Jan  Feb  Mar
      it "splits the record into three parts" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Before correction (split from original)
          [_02_01, _03_01, "X"],   # CORRECTION
          [_03_01, infinity, "A"]  # After correction (split from original)
        ])
      end
    end

    # Test 1.3: Bounded correction starting at exact record boundary
    # -------------------------------------------------------------------------
    # Correction's valid_from matches an existing record's valid_from exactly.
    # No trimming needed at start - just insert correction and trim the end.
    # -------------------------------------------------------------------------
    context "valid_from matches existing record boundary" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|--------------------------------->
      #         Jan          Mar
      #
      # correct(valid_from: Mar, valid_to: Apr, name: "X")
      #                  ↓
      # after:  A             X    B
      #         |-------------|----|---------------------------->
      #         Jan          Mar  Apr
      it "corrects at the boundary without trimming the preceding record" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, valid_to: _04_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],   # Preserved (unchanged)
          [_03_01, _04_01, "X"],   # CORRECTION (at exact boundary)
          [_04_01, infinity, "B"]  # Trimmed start (was Mar-∞, now Apr-∞)
        ])
      end
    end

    # Test 1.4: Bounded correction ending at exact record boundary
    # -------------------------------------------------------------------------
    # Correction's valid_to matches an existing record's valid_to exactly.
    # Trim the start, insert correction, preserve the next record as-is.
    # -------------------------------------------------------------------------
    context "valid_to matches existing record boundary" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|--------------------------------->
      #         Jan          Mar
      #
      # correct(valid_from: Feb, valid_to: Mar, name: "X")
      #                  ↓
      # after:  A    X        B
      #         |----|---------|---------------------------->
      #         Jan  Feb      Mar
      it "corrects up to the boundary without affecting the next record" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Trimmed (was Jan-Mar, now Jan-Feb)
          [_02_01, _03_01, "X"],   # CORRECTION
          [_03_01, infinity, "B"]  # Preserved (unchanged)
        ])
      end
    end

    # Test 1.5: Bounded correction completely replacing one record
    # -------------------------------------------------------------------------
    # Correction exactly replaces one record (same valid_from and valid_to).
    # This is essentially a "data correction" for that specific period.
    # -------------------------------------------------------------------------
    context "correction exactly replaces one record" do
      before do
        # Create timeline: A (Jan-Feb), B (Feb-Mar), C (Mar-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A", valid_to: _02_01) }
          Employee.create!(
            bitemporal_id: @employee.bitemporal_id,
            name: "B",
            valid_from: _02_01,
            valid_to: _03_01
          )
          Employee.create!(
            bitemporal_id: @employee.bitemporal_id,
            name: "C",
            valid_from: _03_01
          )
        end
      end

      # before: A    B    C
      #         |----|----|----------------------------------->
      #         Jan  Feb  Mar
      #
      # correct(valid_from: Feb, valid_to: Mar, name: "X")
      #                  ↓
      # after:  A    X    C
      #         |----|----|----------------------------------->
      #         Jan  Feb  Mar
      it "replaces the record entirely with the correction" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Preserved
          [_02_01, _03_01, "X"],   # CORRECTION (replaces B entirely)
          [_03_01, infinity, "C"]  # Preserved
        ])
      end
    end
  end

  # ==========================================================================
  # Test Category 2: Unbounded Corrections (no valid_to - cascade semantics)
  # ==========================================================================

  describe "#correct without valid_to (unbounded - cascade semantics)" do

    # Test 2.1: Unbounded correction in multi-record timeline
    # -------------------------------------------------------------------------
    # When valid_to is omitted, the correction should:
    # 1. Find the record containing valid_from
    # 2. Use that record's valid_to as the effective correction end
    # 3. Preserve ALL subsequent records unchanged (true CASCADE)
    #
    # This is the KEY semantic difference from bounded correction:
    # Future changes are FULLY preserved, not trimmed.
    # -------------------------------------------------------------------------
    context "multi-record timeline" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-May), C (May-∞)
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
      # correct(valid_from: Feb, name: "X")  # NO valid_to!
      # effective_valid_to = Mar (A's valid_to, the next change point)
      #                  ↓
      # after:  A    X        B             C
      #         |----|---------|-----------|--->
      #         Jan  Feb      Mar          May
      #
      # KEY: B and C are FULLY PRESERVED (not trimmed)
      it "corrects only to the next change point, preserving future changes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, name: "X")  # NO valid_to!
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Trimmed
          [_02_01, _03_01, "X"],   # CORRECTION (ends at Mar - next change point)
          [_03_01, _05_01, "B"],   # PRESERVED (not trimmed!)
          [_05_01, infinity, "C"]  # PRESERVED
        ])
      end
    end

    # Test 2.2: Unbounded correction on single-record timeline
    # -------------------------------------------------------------------------
    # When there's only one record and it has valid_to = ∞,
    # the unbounded correction extends to infinity.
    # -------------------------------------------------------------------------
    context "single-record timeline (no future changes)" do
      before do
        # Create timeline: A (Jan-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # before: A
      #         |------------------------------------------->
      #         Jan
      #
      # correct(valid_from: Feb, name: "X")  # NO valid_to!
      # effective_valid_to = ∞ (A's valid_to)
      #                  ↓
      # after:  A    X
      #         |----|------------------------------------------->
      #         Jan  Feb
      it "correction extends to infinity" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],   # Trimmed
          [_02_01, infinity, "X"]  # CORRECTION (to infinity)
        ])
      end
    end

    # Test 2.3: Unbounded correction at exact change point
    # -------------------------------------------------------------------------
    # When valid_from is exactly at a record boundary,
    # the correction applies to that record and uses its valid_to.
    # -------------------------------------------------------------------------
    context "valid_from at exact change point" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|--------------------------------->
      #         Jan          Mar
      #
      # correct(valid_from: Mar, name: "X")  # At exact boundary
      # effective_valid_to = ∞ (B's valid_to)
      #                  ↓
      # after:  A             X
      #         |-------------|--------------------------------->
      #         Jan          Mar
      it "corrects from the boundary to the record's end" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _03_01, "A"],   # Preserved
          [_03_01, infinity, "X"]  # CORRECTION (replaces B entirely)
        ])
      end
    end
  end

  # ==========================================================================
  # Test Category 3: Edge Cases
  # ==========================================================================

  describe "edge cases" do

    # Test 3.1: Correction at the very start of timeline
    # -------------------------------------------------------------------------
    # valid_from matches the first record's valid_from.
    # The first record is trimmed at valid_to (not completely replaced).
    # -------------------------------------------------------------------------
    context "correction at timeline start" do
      before do
        # Create timeline: A (Jan-Mar), B (Mar-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      # before: A             B
      #         |-------------|--------------------------------->
      #         Jan          Mar
      #
      # correct(valid_from: Jan, valid_to: Feb, name: "X")
      #                  ↓
      # after:  X    A        B
      #         |----|---------|---------------------------->
      #         Jan  Feb      Mar
      it "inserts correction at start, trimming the first record" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _01_01, valid_to: _02_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "X"],   # CORRECTION (at start)
          [_02_01, _03_01, "A"],   # Trimmed start (was Jan-Mar, now Feb-Mar)
          [_03_01, infinity, "B"]  # Preserved
        ])
      end
    end

    # Test 3.2: Multiple sequential corrections
    # -------------------------------------------------------------------------
    # Apply multiple corrections sequentially to build complex timeline.
    # Each correction should work on the current (corrected) timeline.
    # -------------------------------------------------------------------------
    context "multiple sequential corrections" do
      before do
        # Create timeline: A (Jan-∞)
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      # Step 1:
      # before: A
      #         |------------------------------------------->
      # after:  A    X    A
      #         |----|----|--------------------------------->
      #         Jan  Feb  Mar
      #
      # Step 2:
      # before: A    X    A
      #         |----|----|--------------------------------->
      # after:  A    X    A    Y    A
      #         |----|----|----|----|----------------------->
      #         Jan  Feb  Mar  Apr  May
      it "handles sequential corrections correctly" do
        employee = Employee.find(@employee.id)

        # First correction
        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, infinity, "A"]
        ])

        # Second correction (on the already-corrected timeline)
        Timecop.freeze("2020/10/07") do
          employee.correct(valid_from: _04_01, valid_to: _05_01, name: "Y")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, _04_01, "A"],
          [_04_01, _05_01, "Y"],
          [_05_01, infinity, "A"]
        ])
      end
    end

    # Test 3.3: Non-corrected attributes inherit from containing record
    # -------------------------------------------------------------------------
    # When correcting with only some attributes, the non-corrected attributes
    # should come from the record at valid_from, NOT from the current record.
    # -------------------------------------------------------------------------
    context "non-corrected attributes inherit from containing record" do
      before do
        Timecop.freeze("2020/10/01") do
          # Create timeline with multiple attribute changes
          ActiveRecord::Bitemporal.valid_at(_01_01) {
            @employee = Employee.create!(name: "Alice", emp_code: "E001")
          }
          ActiveRecord::Bitemporal.valid_at(_03_01) {
            @employee.update!(emp_code: "E002")  # emp_code changes at Mar
          }
          ActiveRecord::Bitemporal.valid_at(_05_01) {
            @employee.update!(name: "Bob")  # name changes at May
          }
        end
      end

      # Timeline:
      # Jan-Mar: name="Alice", emp_code="E001"
      # Mar-May: name="Alice", emp_code="E002"
      # May-∞:   name="Bob",   emp_code="E002"

      it "inherits from the record at valid_from, not current record" do
        employee = Employee.find(@employee.id)  # Returns current (Bob, E002)

        Timecop.freeze("2020/10/06") do
          # Correct name in Feb-Apr period
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "Charlie")
        end

        # The correction (Feb-Apr) should have:
        # - name="Charlie" (specified)
        # - emp_code="E001" (from Jan-Mar record, NOT "E002" from current)

        correction = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .find { |r| r.valid_from == _02_01 }

        expect(correction.name).to eq("Charlie")
        expect(correction.emp_code).to eq("E001")  # Key assertion!
      end
    end

    # Test 3.4: Zero-width correction window
    # -------------------------------------------------------------------------
    # When valid_from equals valid_to, this creates a zero-width period which
    # is invalid. The system should reject this with a clear error.
    # -------------------------------------------------------------------------
    context "valid_from equals valid_to (zero-width correction)" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "raises ArgumentError for zero-width correction" do
        employee = Employee.find(@employee.id)

        expect {
          employee.correct(valid_from: _02_01, valid_to: _02_01, name: "X")
        }.to raise_error(ArgumentError)
      end
    end

    # Test 3.5: Long timeline stress test
    # -------------------------------------------------------------------------
    # Test correction on a timeline with many records to verify algorithm
    # correctness at scale. Correction should properly trim and preserve
    # records across a 10-record timeline.
    # -------------------------------------------------------------------------
    context "correction on 10-record timeline" do
      let(:dates) do
        (1..12).map { |m| "2020/#{m.to_s.rjust(2, '0')}/01".in_time_zone }
      end

      before do
        # Create timeline: A(Jan), B(Feb), C(Mar), D(Apr), E(May), F(Jun),
        #                  G(Jul), H(Aug), I(Sep), J(Oct-∞)
        Timecop.freeze("2020/12/01") do
          ActiveRecord::Bitemporal.valid_at(dates[0]) { @employee = Employee.create!(name: "A") }
          ("B".."J").each_with_index do |name, idx|
            ActiveRecord::Bitemporal.valid_at(dates[idx + 1]) { @employee.update!(name: name) }
          end
        end
      end

      # before: A    B    C    D    E    F    G    H    I    J
      #         |----|----|----|----|----|----|----|----|----|---->
      #         Jan  Feb  Mar  Apr  May  Jun  Jul  Aug  Sep  Oct
      #
      # correct(valid_from: Mar 15, valid_to: Jul 15, name: "X")
      #                       ↓
      # after:  A    B    C  X                G    H    I    J
      #         |----|----|--|----------------|----|----|----|--->
      #         Jan  Feb  Mar               Jul   Aug  Sep  Oct
      #                    15               15
      it "correctly handles cascade across many records" do
        employee = Employee.find(@employee.id)
        mar_15 = "2020/03/15".in_time_zone
        jul_15 = "2020/07/15".in_time_zone

        Timecop.freeze("2020/12/06") do
          employee.correct(valid_from: mar_15, valid_to: jul_15, name: "X")
        end

        timeline = current_timeline(employee)

        # Verify timeline structure
        expect(timeline).to eq([
          [dates[0], dates[1], "A"],         # Jan-Feb: preserved
          [dates[1], dates[2], "B"],         # Feb-Mar: preserved
          [dates[2], mar_15, "C"],           # Mar-Mar15: trimmed
          [mar_15, jul_15, "X"],             # Mar15-Jul15: CORRECTION
          [jul_15, dates[7], "G"],           # Jul15-Aug: trimmed
          [dates[7], dates[8], "H"],         # Aug-Sep: preserved
          [dates[8], dates[9], "I"],         # Sep-Oct: preserved
          [dates[9], infinity, "J"]          # Oct-∞: preserved (CASCADE)
        ])

        # Also verify timeline invariants
        expect(valid_timeline?(timeline)).to be true
      end
    end

    # Test 3.6: Correction with NULL attribute inheritance
    # -------------------------------------------------------------------------
    # When the containing record has NULL for non-corrected attributes,
    # the correction should preserve NULL, not accidentally inherit a value.
    # -------------------------------------------------------------------------
    context "containing record has NULL attribute" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) {
            @employee = Employee.create!(name: "A", emp_code: nil)
          }
        end
      end

      it "preserves NULL in non-corrected attributes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, name: "X")
        end

        correction = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .find { |r| r.valid_from == _02_01 }

        expect(correction.name).to eq("X")
        expect(correction.emp_code).to be_nil  # Should preserve NULL
      end
    end

    # Test 3.7: Sequential corrections without reload
    # -------------------------------------------------------------------------
    # Multiple corrections on the same instance without reloading between them.
    # Tests that the instance state doesn't become stale.
    # -------------------------------------------------------------------------
    context "multiple corrections on same instance without reload" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "handles corrections without reloading between them" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
          # Intentionally NOT reloading employee here
          employee.correct(valid_from: _04_01, valid_to: _05_01, name: "Y")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, _04_01, "A"],
          [_04_01, _05_01, "Y"],
          [_05_01, infinity, "A"]
        ])
      end
    end
  end

  # ==========================================================================
  # Test Category 4: Historical Queries ("What We Knew When")
  # ==========================================================================

  describe "historical queries after correction" do
    before do
      # T0: Create A (Jan-∞)
      @t0 = "2020/10/01".in_time_zone
      Timecop.freeze(@t0) do
        ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
      end

      # T1: Update to B at Mar
      @t1 = "2020/10/04".in_time_zone
      Timecop.freeze(@t1) do
        ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
      end

      # T2: Correct Feb-Apr to X
      @t2 = "2020/10/06".in_time_zone
      Timecop.freeze(@t2) do
        @employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
      end
    end

    # Timeline evolution:
    # T0: A (Jan-∞)
    # T1: A (Jan-Mar), B (Mar-∞)
    # T2: A (Jan-Feb), X (Feb-Apr), B (Apr-∞)

    context "current knowledge (after correction)" do
      # Query: "What is the value at Feb 15, as we know it NOW?"
      # At T2 (current), we know Feb 15 has value "X"
      it "returns corrected value at Feb 15" do
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.valid_at(_02_15) do
            expect(Employee.find(@employee.id).name).to eq("X")
          end
        end
      end

      # Query: "What is the value at Apr 15, as we know it NOW?"
      # At T2 (current), we know Apr 15 has value "B"
      it "returns correct value at Apr 15" do
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.valid_at(_04_15) do
            expect(Employee.find(@employee.id).name).to eq("B")
          end
        end
      end
    end

    context "historical knowledge (before correction)" do
      # Query: "What did we think at T1 the value was at Feb 15?"
      # At T1, we thought Feb 15 had value "A" (before the correction)
      it "returns pre-correction value using transaction_at" do
        Timecop.freeze(@t2) do  # Query from T2, but ask about T1's knowledge
          ActiveRecord::Bitemporal.transaction_at(@t1) do
            ActiveRecord::Bitemporal.valid_at(_02_15) do
              expect(Employee.find(@employee.id).name).to eq("A")  # Old knowledge
            end
          end
        end
      end

      # Query: "What did we think at T1 the value was at Apr 15?"
      # At T1, we thought Apr 15 had value "B" (March change was known)
      it "returns value of already-known change at Apr 15" do
        Timecop.freeze(@t2) do
          ActiveRecord::Bitemporal.transaction_at(@t1) do
            ActiveRecord::Bitemporal.valid_at(_04_15) do
              expect(Employee.find(@employee.id).name).to eq("B")
            end
          end
        end
      end
    end
  end

  # ==========================================================================
  # Test Category 5: Error Conditions
  # ==========================================================================

  describe "error conditions" do

    # Test 5.1: No record at valid_from
    # -------------------------------------------------------------------------
    # If valid_from is before the timeline starts, raise error.
    # -------------------------------------------------------------------------
    context "valid_from before timeline starts" do
      before do
        # Create timeline: A (Mar-∞) - starts at March, not January
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "raises RecordNotFound" do
        employee = Employee.find(@employee.id)

        expect {
          employee.correct(valid_from: _02_01, name: "X")  # Feb is before timeline
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # Test 5.2: Invalid valid_from/valid_to ordering
    # -------------------------------------------------------------------------
    # If valid_to < valid_from, raise error.
    # -------------------------------------------------------------------------
    context "valid_to before valid_from" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "raises ArgumentError" do
        employee = Employee.find(@employee.id)

        expect {
          employee.correct(valid_from: _03_01, valid_to: _02_01, name: "X")  # Mar > Feb
        }.to raise_error(ArgumentError)
      end
    end

    # Test 5.3: Transaction rollback on failure
    # -------------------------------------------------------------------------
    # If correction fails partway through, all changes should be rolled back.
    # -------------------------------------------------------------------------
    context "failure mid-operation" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "rolls back all changes on failure" do
        employee = Employee.find(@employee.id)
        original_timeline = current_timeline(employee)

        # Force a failure by making save_without_bitemporal_callbacks! raise
        call_count = 0
        allow_any_instance_of(Employee).to receive(:save_without_bitemporal_callbacks!).and_wrap_original do |method, *args, **kwargs|
          call_count += 1
          # Fail on the second save (after the first new record is saved)
          if call_count >= 2
            raise ActiveRecord::RecordInvalid.new(Employee.new)
          end
          method.call(*args, **kwargs)
        end

        expect {
          employee.correct(valid_from: _02_01, name: "X")
        }.to raise_error(ActiveRecord::RecordInvalid)

        # Timeline should be unchanged (transaction rolled back)
        expect(current_timeline(employee)).to eq(original_timeline)
      end
    end

    # Test 5.4: Correction on soft-deleted entity
    # -------------------------------------------------------------------------
    # After an entity is destroyed (soft-delete), corrections on historical
    # periods should still work since we're correcting past valid time.
    # -------------------------------------------------------------------------
    context "entity has been destroyed (soft-deleted)" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        # Destroy at May - entity is now soft-deleted
        Timecop.freeze("2020/10/03") do
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.destroy }
        end
      end

      # Timeline after destroy:
      # A (Jan-Mar), B (Mar-May) - then destroyed at May
      #
      # Correction: fix Feb-Apr period to X
      # Expected: A (Jan-Feb), X (Feb-Apr), B (Apr-May) - still destroyed at May
      it "can still correct historical periods" do
        # Note: Employee.find won't find destroyed records by default,
        # so we need to use within_deleted or find via ignore_valid_datetime
        employee = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .first

        Timecop.freeze("2020/10/06") do
          expect {
            employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
          }.not_to raise_error
        end

        # Verify correction was applied to historical period
        timeline = Employee.ignore_valid_datetime.within_deleted
          .where(bitemporal_id: @employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)
          .pluck(:valid_from, :valid_to, :name)

        expect(timeline).to eq([
          [_01_01, _02_01, "A"],   # Trimmed
          [_02_01, _04_01, "X"],   # CORRECTION
          [_04_01, _05_01, "B"]    # Trimmed, still ends at May (destroyed)
        ])
      end
    end
  end

  # ==========================================================================
  # Test Category 6: Isolation and Concurrency
  # ==========================================================================

  describe "isolation and concurrency" do

    # Test 6.1: Corrections don't affect other entities
    # -------------------------------------------------------------------------
    # Correction on one bitemporal_id should not affect others.
    # -------------------------------------------------------------------------
    context "multiple entities" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) do
            @employee1 = Employee.create!(name: "A")
            @employee2 = Employee.create!(name: "B")
          end
        end
      end

      it "only affects the targeted entity" do
        employee1 = Employee.find(@employee1.id)
        employee2_timeline_before = current_timeline(@employee2)

        Timecop.freeze("2020/10/06") do
          employee1.correct(valid_from: _02_01, name: "X")
        end

        # Employee1 should be corrected
        expect(current_timeline(employee1)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, infinity, "X"]
        ])

        # Employee2 should be unchanged
        expect(current_timeline(@employee2)).to eq(employee2_timeline_before)
      end
    end

    # Test 6.2: Concurrent corrections on same entity
    # -------------------------------------------------------------------------
    # Two threads attempting to correct the same entity simultaneously.
    # The locking mechanism should serialize the operations to prevent
    # data corruption. Both should succeed, producing a consistent timeline.
    # -------------------------------------------------------------------------
    context "two threads correct same entity simultaneously", use_truncation: true do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "serializes via locking - both succeed with consistent timeline" do
        employee_id = @employee.bitemporal_id
        results = []
        errors = []

        threads = 2.times.map do |i|
          Thread.new do
            # Each thread corrects a different time period to avoid conflict
            valid_from = i == 0 ? _02_01 : _03_01
            valid_to = i == 0 ? _03_01 : _04_01
            Employee.find(employee_id).correct(
              valid_from: valid_from,
              valid_to: valid_to,
              name: "Thread#{i}"
            )
            results << i
          rescue => e
            errors << e
          end
        end

        threads.each(&:join)

        # Both threads should succeed (no errors)
        expect(errors).to be_empty

        # Final timeline should be consistent (no overlaps, no gaps)
        timeline = current_timeline(@employee)
        expect(valid_timeline?(timeline)).to be true

        # Should have both corrections in the timeline
        names = timeline.map { |_, _, name| name }
        expect(names).to include("Thread0", "Thread1")
      end
    end
  end

  # ==========================================================================
  # Test Category 7: Timestamp Behavior
  # ==========================================================================

  describe "timestamp behavior" do

    # Test 7.1: created_at behavior on correction records
    # -------------------------------------------------------------------------
    # Correction records should get new created_at timestamps (the time
    # of correction), not inherit from the source record.
    # -------------------------------------------------------------------------
    context "created_at on correction records" do
      before do
        @creation_time = "2020/10/01".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "sets new created_at on correction records" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, name: "X")
        end

        correction_record = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .find { |r| r.name == "X" }

        # Correction record should have correction_time as created_at
        expect(correction_record.created_at).to eq(correction_time)
      end
    end

    # Test 7.2: updated_at behavior on correction records
    # -------------------------------------------------------------------------
    # All new records created during correction should have updated_at
    # set to the correction time.
    # -------------------------------------------------------------------------
    context "updated_at on correction records" do
      before do
        @creation_time = "2020/10/01".in_time_zone
        Timecop.freeze(@creation_time) do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
        end
      end

      it "sets updated_at to correction time" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06 15:30:00".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        # All current timeline records should have updated_at = correction_time
        # (single-record scenario: all segments are newly created)
        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)

        current_records.each do |record|
          expect(record.updated_at).to eq(correction_time)
        end
      end
    end
  end

  # ==========================================================================
  # Test Category 8: Surgical Record Accounting
  # ==========================================================================
  # Verify that `correct` only closes and recreates records that overlap the
  # correction range. Records fully after the correction are left untouched.
  # ==========================================================================

  describe "surgical record accounting" do
    # Test 8.1: Bounded correction — only overlapping records are closed
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar], B[Mar-May], C[May-∞]
    # Action: correct(valid_from: Feb, valid_to: Apr, name: "X")
    # A and B overlap [Feb, Apr) and are closed. C is fully after and untouched.
    # -------------------------------------------------------------------------
    context "bounded correction only closes overlapping records" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      it "closes only A and B, leaves C untouched" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
        end

        closed_by_correction = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: correction_time)

        expect(closed_by_correction.count).to eq(2)

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        # A'[Jan-Feb], X[Feb-Apr], B'[Apr-May] have transaction_from = correction_time
        modified = current_records.select { |r| r.name != "C" }
        modified.each { |r| expect(r.transaction_from).to eq(correction_time) }

        # C retains original transaction_from (untouched)
        untouched_c = current_records.find { |r| r.name == "C" }
        expect(untouched_c.transaction_from).not_to eq(correction_time)
      end
    end

    # Test 8.2: Unbounded correction — only containing record is closed
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar], B[Mar-May], C[May-∞]
    # Action: correct(valid_from: Feb, name: "X") (no valid_to)
    # Unbounded correction ends at A's valid_to (Mar). Only A is closed.
    # -------------------------------------------------------------------------
    context "unbounded correction only closes containing record" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
      end

      it "closes only A, leaves B and C untouched" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, name: "X")
        end

        closed_by_correction = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: correction_time)

        expect(closed_by_correction.count).to eq(1)

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        # A'[Jan-Feb] and X[Feb-Mar] have transaction_from = correction_time
        modified = current_records.select { |r| r.transaction_from == correction_time }
        expect(modified.map(&:name)).to match_array(["A", "X"])

        # B and C retain original transaction_from (untouched)
        untouched = current_records.select { |r| r.transaction_from != correction_time }
        expect(untouched.map(&:name)).to match_array(["B", "C"])
      end
    end

    # Test 8.3: Consumed middle record — closed without replacement
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Feb], B[Feb-Apr], C[Apr-∞]
    # Action: correct(valid_from: Feb, valid_to: Apr, name: "X")
    # B is exactly consumed by the correction. A and C are untouched.
    # -------------------------------------------------------------------------
    context "consumed middle record is closed without replacement" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A", valid_to: _02_01) }
          Employee.create!(
            bitemporal_id: @employee.bitemporal_id,
            name: "B",
            valid_from: _02_01,
            valid_to: _04_01
          )
          Employee.create!(
            bitemporal_id: @employee.bitemporal_id,
            name: "C",
            valid_from: _04_01
          )
        end
      end

      it "closes only B, leaves A and C untouched" do
        employee = Employee.find(@employee.id)
        correction_time = "2020/10/06".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
        end

        closed_by_correction = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: correction_time)

        expect(closed_by_correction.count).to eq(1)

        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        # X[Feb-Apr] has transaction_from = correction_time
        expect(current_records.find { |r| r.name == "X" }.transaction_from).to eq(correction_time)

        # A and C retain original transaction_from (untouched)
        untouched = current_records.select { |r| ["A", "C"].include?(r.name) }
        untouched.each { |r| expect(r.transaction_from).not_to eq(correction_time) }
      end
    end
  end

  # ==========================================================================
  # Category 9: Seam Coalescing
  # ==========================================================================
  #
  # correct() can produce "cosmetic seams" — adjacent segments with identical
  # business attributes split at a boundary. Coalescing merges them into a
  # single segment.
  # ==========================================================================
  describe "Category 9: Seam Coalescing" do

    # Test 9.1: Cancel pattern coalesces into single segment
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # Action: correct(Mar, name: "X")
    # Without coalescing: A[Jan-Mar, "X"], C[Mar-∞, "X"] — cosmetic seam
    # With coalescing: merged[Jan-∞, "X"] — one segment
    # -------------------------------------------------------------------------
    context "cancel pattern coalesces into single segment" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
        end
      end

      it "merges adjacent identical segments into one" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "X")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(1)
        expect(timeline).to eq([
          [_01_01, infinity, "X"]
        ])
      end
    end

    # Test 9.2: Bounded correction with chain coalescing (triple merge)
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-May, "Y"], C[May-∞, "X"]
    # Action: correct(Mar, May, name: "X")
    # Without coalescing: A[Jan-Mar], X[Mar-May], C[May-∞] — all "X"
    # With coalescing: merged[Jan-∞, "X"] — triple merge
    # -------------------------------------------------------------------------
    context "bounded correction with chain coalescing (triple merge)" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "X") }
        end
      end

      it "merges three identical adjacent segments into one" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, valid_to: _05_01, name: "X")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(1)
        expect(timeline).to eq([
          [_01_01, infinity, "X"]
        ])
      end
    end

    # Test 9.3: Left boundary no-op correction coalesces
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # Action: correct(Feb, Mar, name: "X")
    # Without coalescing: A'[Jan-Feb, "X"], X[Feb-Mar, "X"], B[Mar-∞, "Y"]
    # With coalescing: merged[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # -------------------------------------------------------------------------
    context "left boundary no-op correction coalesces" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
        end
      end

      it "merges seam between split halves with same attributes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _02_01, valid_to: _03_01, name: "X")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(2)
        expect(timeline).to eq([
          [_01_01, _03_01, "X"],
          [_03_01, infinity, "Y"]
        ])
      end
    end

    # Test 9.4: Different attributes — no coalescing (control)
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # Action: correct(Mar, name: "Z")
    # Result: A[Jan-Mar, "X"], Z[Mar-∞, "Z"] — different, no merge
    # -------------------------------------------------------------------------
    context "different attributes — no coalescing" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
        end
      end

      it "does not merge segments with different attributes" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "Z")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(2)
        expect(timeline).to eq([
          [_01_01, _03_01, "X"],
          [_03_01, infinity, "Z"]
        ])
      end
    end

    # Test 9.5: Audit trail preserved after coalescing
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # Action: correct(Mar, name: "X") at T1
    # Assert:
    #   - At transaction_at(before T1): see A[Jan-Mar] and B[Mar-∞] (original state)
    #   - At transaction_at(T1): see merged[Jan-∞, "X"] (post-coalesce)
    # -------------------------------------------------------------------------
    context "audit trail preserved after coalescing" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
        end
      end

      it "preserves historical view before correction" do
        employee = Employee.find(@employee.id)
        before_correction = "2020/10/05".in_time_zone
        correction_time = "2020/10/06".in_time_zone

        Timecop.freeze(correction_time) do
          employee.correct(valid_from: _03_01, name: "X")
        end

        # Historical view: before correction, see original A and B
        ActiveRecord::Bitemporal.transaction_at(before_correction) do
          old_at_jan = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.find(employee.id) }
          expect(old_at_jan.name).to eq("X")

          old_at_mar = ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(employee.id) }
          expect(old_at_mar.name).to eq("Y")
        end

        # Current view: after correction, see merged single segment
        ActiveRecord::Bitemporal.transaction_at(correction_time) do
          new_at_jan = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.find(employee.id) }
          expect(new_at_jan.name).to eq("X")

          new_at_mar = ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(employee.id) }
          expect(new_at_mar.name).to eq("X")
        end
      end
    end

    # Test 9.6: NULL attributes coalesce correctly
    # -------------------------------------------------------------------------
    # Adjacent records with matching nil values should be coalesced.
    # -------------------------------------------------------------------------
    context "NULL attributes coalesce correctly" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X", emp_code: nil) }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y", emp_code: nil) }
        end
      end

      it "coalesces records with matching nil values" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "X")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(1)
        expect(timeline).to eq([
          [_01_01, infinity, "X"]
        ])
      end
    end

    # Test 9.7: Single-column difference prevents coalescing
    # -------------------------------------------------------------------------
    # Adjacent records identical except one column (emp_code).
    # -------------------------------------------------------------------------
    context "single-column difference prevents coalescing" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X", emp_code: "E001") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y", emp_code: "E002") }
        end
      end

      it "does not coalesce when emp_code differs" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "X", emp_code: "E002")
        end

        timeline = current_timeline(employee)

        # name matches ("X" and "X") but emp_code differs ("E001" vs "E002")
        expect(timeline.size).to eq(2)

        records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)
          .order(:valid_from)

        expect(records.first.emp_code).to eq("E001")
        expect(records.last.emp_code).to eq("E002")
      end
    end

    # Test 9.8: Non-adjacent identical segments are NOT coalesced
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-May, "Y"], C[May-∞, "X"]
    # Action: correct(Mar, May, name: "Z")
    # Result: A[Jan-Mar, "X"], Z[Mar-May, "Z"], C[May-∞, "X"]
    # A and C have identical attributes but are separated by Z — no coalescing.
    # -------------------------------------------------------------------------
    context "non-adjacent identical segments are not coalesced" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "X") }
        end
      end

      it "keeps three segments when middle differs" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, valid_to: _05_01, name: "Z")
        end

        timeline = current_timeline(employee)

        expect(timeline.size).to eq(3)
        expect(timeline).to eq([
          [_01_01, _03_01, "X"],
          [_03_01, _05_01, "Z"],
          [_05_01, infinity, "X"]
        ])
      end
    end

    # Test 9.9: self state is correct after coalescing
    # -------------------------------------------------------------------------
    # Setup: A[Jan-Mar, "X"], B[Mar-∞, "Y"]
    # Action: correct(Mar, name: "X") — coalesces A and correction into one
    # Assert: employee (self) points to the merged record
    # -------------------------------------------------------------------------
    context "self state is correct after coalescing" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "X") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "Y") }
        end
      end

      it "updates self to point to the merged record" do
        employee = Employee.find(@employee.id)

        Timecop.freeze("2020/10/06") do
          employee.correct(valid_from: _03_01, name: "X")
        end

        # self's temporal fields should reflect the merged single-segment state
        expect(employee[Employee.valid_from_key]).to eq(_01_01)
        expect(employee[Employee.valid_to_key]).to eq(infinity)

        # After reload, business attributes match the merged record
        employee.reload
        expect(employee.name).to eq("X")
        expect(employee[Employee.valid_from_key]).to eq(_01_01)
        expect(employee[Employee.valid_to_key]).to eq(infinity)
      end
    end
  end

  # ==========================================================================
  # Category 13: Correction Guard — Cannot Extend Past Timeline End
  # ==========================================================================

  # Helper to find a terminated employee (whose valid_to is in the past)
  def find_ignoring_valid_time(record)
    Employee.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .order(:valid_from)
      .first
  end

  describe "correction guard against extending past timeline end" do

    # Test 13.1: Bounded correction past termination raises ValidDatetimeRangeError
    #
    #   Timeline:  |---A---|---B---|  (terminated at May)
    #   Correction:        |---X-------->|  ← valid_to past May — REJECTED
    context "bounded correction with valid_to past terminated timeline" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      it "raises ValidDatetimeRangeError" do
        employee = find_ignoring_valid_time(@employee)

        expect {
          Timecop.freeze("2020/10/03") do
            employee.correct(valid_from: _02_01, valid_to: "2020/07/01".in_time_zone, name: "X")
          end
        }.to raise_error(
          ActiveRecord::Bitemporal::ValidDatetimeRangeError,
          /exceeds timeline end/
        )
      end

      it "does not modify the timeline" do
        employee = find_ignoring_valid_time(@employee)
        timeline_before = current_timeline(employee)

        begin
          Timecop.freeze("2020/10/03") do
            employee.correct(valid_from: _02_01, valid_to: "2020/07/01".in_time_zone, name: "X")
          end
        rescue ActiveRecord::Bitemporal::ValidDatetimeRangeError
          # expected
        end

        expect(current_timeline(employee)).to eq(timeline_before)
      end
    end

    # Test 13.2: Unbounded correction on terminated entity stays within range
    #
    #   Timeline:  |---A---|---B---|  (terminated at May)
    #   Correction:   |---X---|         ← unbounded, inherits B's valid_to (May) — OK
    context "unbounded correction on terminated entity" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      it "succeeds and respects the terminated boundary" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/03") do
          employee.correct(valid_from: _02_01, name: "X")
        end

        timeline = current_timeline(employee)

        # Correction replaces A from Feb to Mar (next change point), everything else intact
        expect(timeline).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _03_01, "X"],
          [_03_01, _05_01, "B"]
        ])

        # Crucially: timeline still ends at May (termination preserved)
        expect(timeline.last[1]).to eq(_05_01)
      end
    end

    # Test 13.3: Bounded correction exactly at timeline end (edge case — should pass)
    context "bounded correction with valid_to exactly at timeline end" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
        Timecop.freeze("2020/10/02") do
          find_ignoring_valid_time(@employee).terminate(termination_time: _05_01)
        end
      end

      it "succeeds because valid_to equals timeline end (not exceeds)" do
        employee = find_ignoring_valid_time(@employee)

        Timecop.freeze("2020/10/03") do
          employee.correct(valid_from: _02_01, valid_to: _05_01, name: "X")
        end

        timeline = current_timeline(employee)
        expect(timeline.last[1]).to eq(_05_01)
      end
    end

    # Test 13.4: Correction on non-terminated entity (no guard triggered)
    context "bounded correction on non-terminated entity" do
      before do
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
        end
      end

      it "succeeds normally — guard only applies when valid_to exceeds infinity" do
        employee = Employee.find(@employee.id)

        # This sets valid_to to Apr, which is < infinity — no guard triggered
        Timecop.freeze("2020/10/03") do
          employee.correct(valid_from: _02_01, valid_to: _04_01, name: "X")
        end

        expect(current_timeline(employee)).to eq([
          [_01_01, _02_01, "A"],
          [_02_01, _04_01, "X"],
          [_04_01, infinity, "B"]
        ])
      end
    end
  end
end
