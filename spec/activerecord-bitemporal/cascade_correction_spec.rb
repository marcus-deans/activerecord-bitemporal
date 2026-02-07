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
        # NOTE: Need within_deleted to see records with closed transaction_to
        # Filter to records that were created before correction (transaction_from < correction_time)
        # and closed at correction time (transaction_to = correction_time)
        closed_by_correction = Employee.ignore_valid_datetime
          .within_deleted
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: correction_time)

        # Should have closed exactly 3 records (the A, B, C records from setup)
        expect(closed_by_correction.count).to eq(3)

        # New records should have transaction_from = correction_time
        current_records = Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id)
          .where(transaction_to: tt_infinity)

        expect(current_records.pluck(:transaction_from).uniq).to eq([correction_time])
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
  end
end
