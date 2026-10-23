# frozen_string_literal: true

require 'spec_helper'

# timeline_dup and timeline_close mirror upstream's refinements in bitemporal.rb:
# the `dup` refined on ActiveRecord::Base and the `update_transaction_to` refined on
# Persistence. Refinements are active only inside that file, so the fork's timeline
# operations carry their own copies.
#
# Keep them in sync: on every upstream merge, diff upstream's refinements block
# (`using Module.new { refine Persistence do ... }`) and mirror any change into
# lib/activerecord-bitemporal/timeline_operations.rb and these examples.
RSpec.describe ActiveRecord::Bitemporal::TimelineOperations do
  let(:tt_infinity) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }

  # All rows (every valid and transaction time) of one entity
  def all_rows(klass, bitemporal_id)
    klass.ignore_valid_datetime.within_deleted.where(bitemporal_id: bitemporal_id)
  end

  # Fetches the open row the way the timeline operations do: id is the row's own key
  def current_row(record)
    record.class.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .order(:valid_from)
      .first
      .tap { |row|
        row.id = row.swapped_id
        row.clear_changes_information
      }
  end

  describe "#timeline_dup (mirrors upstream's refined ActiveRecord::Base#dup)" do
    let(:employee) {
      Employee.create!(name: "Jane", valid_from: "2020/01/01").tap { |it|
        # Leaves all three internal ivars set: swapped id, previous swapped id, force-updated flag
        it.force_update { it.update!(name: "Jane2") }
      }
    }

    it "starts from a record that carries bitemporal internal state" do
      expect(employee.swapped_id).not_to be_nil
      expect(employee.swapped_id_previously_was).not_to be_nil
      expect(employee.previously_force_updated?).to be true
    end

    it "is needed because plain #dup copies that state" do
      plain = employee.dup

      expect(plain.instance_variable_get(:@_swapped_id)).to eq employee.swapped_id
      expect(plain.swapped_id_previously_was).to eq employee.swapped_id_previously_was
      expect(plain.previously_force_updated?).to be true
    end

    it "resets the swapped ids to nil and the force-updated flag to false" do
      copy = employee.send(:timeline_dup, employee)

      expect(copy.instance_variable_get(:@_swapped_id)).to be_nil
      expect(copy.swapped_id_previously_was).to be_nil
      expect(copy.instance_variable_get(:@previously_force_updated)).to be false
      expect(copy.swapped_id).to be_nil
    end

    it "keeps the business attributes and the bitemporal_id" do
      copy = employee.send(:timeline_dup, employee)

      expect(copy.name).to eq "Jane2"
      expect(copy.bitemporal_id).to eq employee.bitemporal_id
      expect(copy).to be_new_record
    end

    it "saves as a new row, leaving the source row untouched" do
      source = Employee.create!(name: "Jane", valid_from: "2020/01/01", valid_to: "2020/06/01")
      row = current_row(source)

      copy = source.send(:timeline_dup, row)
      copy.id = nil
      copy.valid_from = "2020/06/01".in_time_zone
      copy.valid_to = ActiveRecord::Bitemporal::DEFAULT_VALID_TO
      copy.transaction_from = Time.current
      copy.transaction_to = tt_infinity

      expect { copy.save_without_bitemporal_callbacks!(validate: false) }
        .to change { all_rows(Employee, source.bitemporal_id).count }.from(1).to(2)
      expect(copy.swapped_id).not_to eq row.swapped_id
      expect(all_rows(Employee, source.bitemporal_id).order(:valid_from).pluck(:id, :valid_to)).to eq [
        [row.swapped_id, "2020/06/01".in_time_zone],
        [copy.swapped_id, ActiveRecord::Bitemporal::DEFAULT_VALID_TO]
      ]
    end
  end

  describe "#timeline_close (mirrors upstream's refined Persistence#update_transaction_to)" do
    let(:closed_at) { Time.current.change(usec: 0) }

    context "when the model has a deleted_at column (Employee)" do
      it "sets transaction_to and deleted_at" do
        employee = Employee.create!(name: "Jane", valid_from: "2020/01/01")
        row = current_row(employee)

        employee.send(:timeline_close, row, closed_at)

        expect(row.transaction_to).to eq closed_at
        expect(row.deleted_at).to eq closed_at
        expect(all_rows(Employee, employee.bitemporal_id).pluck(:transaction_to, :deleted_at))
          .to eq [[closed_at, closed_at]]
      end
    end

    context "when the model has no deleted_at column (Department)" do
      it "sets transaction_to only" do
        department = Department.create!(name: "Dev", valid_from: "2020/01/01")
        row = current_row(department)

        expect(Department.column_names).not_to include "deleted_at"

        department.send(:timeline_close, row, closed_at)

        expect(row.transaction_to).to eq closed_at
        expect(all_rows(Department, department.bitemporal_id).pluck(:transaction_to)).to eq [closed_at]
      end
    end
  end

  # Characterizes where self points after an op when no segment covers now. This is
  # today's behaviour, kept unchanged by extracting the shared skeleton
  # (perform_timeline_operation's repoint_fallback); it's expected to change once
  # repointing self is fixed.
  describe "repointing self when no segment covers now" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_03_01) { "2020/03/01".in_time_zone }
    let(:_06_01) { "2020/06/01".in_time_zone }

    #   A |01-01, 03-01)  B |03-01, ∞)   then terminated at 06-01, so nothing covers now (Oct)
    let!(:employee_id) {
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A") }
      end
      Timecop.freeze("2020/10/02") do
        ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
      end
      @employee.id
    }

    it "falls back to the last segment, except cancel_shift_genesis which falls back to the first" do
      employee = Employee.find(employee_id)

      Timecop.freeze("2020/10/03") { employee.terminate(termination_time: _06_01) }
      expect([employee.valid_from, employee.valid_to]).to eq [_03_01, _06_01]

      Timecop.freeze("2020/10/04") { employee.shift_genesis(new_valid_from: _02_01) }
      expect([employee.valid_from, employee.valid_to]).to eq [_03_01, _06_01]

      Timecop.freeze("2020/10/05") { employee.cancel_shift_genesis }
      expect([employee.valid_from, employee.valid_to]).to eq [_01_01, _03_01]

      Timecop.freeze("2020/10/06") { employee.correct(valid_from: _01_01, name: "A2") }
      expect([employee.valid_from, employee.valid_to]).to eq [_03_01, _06_01]
    end

    context "with a future-dated timeline" do
      #   A |2021-01-01, 2021-03-01)  B |2021-03-01, ∞)   while now is 2020-10
      let(:_2021_01_01) { "2021/01/01".in_time_zone }
      let(:_2021_03_01) { "2021/03/01".in_time_zone }
      let(:_2021_06_01) { "2021/06/01".in_time_zone }
      let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }

      let!(:employee_id) {
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_2021_01_01) { @employee = Employee.create!(name: "A") }
        end
        Timecop.freeze("2020/10/02") do
          ActiveRecord::Bitemporal.valid_at(_2021_03_01) { @employee.update!(name: "B") }
        end
        @employee.id
      }

      it "cancel_termination falls back to the last segment" do
        employee = Employee.ignore_valid_datetime.find_by!(bitemporal_id: employee_id, valid_from: _2021_01_01)

        Timecop.freeze("2020/10/03") { employee.terminate(termination_time: _2021_06_01) }
        Timecop.freeze("2020/10/04") { employee.cancel_termination }

        expect([employee.valid_from, employee.valid_to]).to eq [_2021_03_01, infinity]
      end
    end
  end

  describe "locking the timeline" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }

    # The app-side lock_family! helper, copied verbatim apart from taking the
    # model and key as arguments. The timeline operations must take this same lock.
    def app_lock_family!(model, bitemporal_id)
      keys = [model.table_name, bitemporal_id].map do |value|
        Arel::Nodes::NamedFunction.new("hashtext", [Arel::Nodes.build_quoted(value)])
      end
      lock = Arel::Nodes::NamedFunction.new("pg_advisory_xact_lock", keys)
      model.connection.execute(Arel::SelectManager.new.project(lock).to_sql)
    end

    # Every SQL statement the block runs, in order
    def statements_during(&block)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end

    describe "in each operation" do
      let!(:employee) {
        Timecop.freeze("2020/10/01") do
          ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
        end
      }

      {
        "correct" => [nil, ->(e) { e.correct(valid_from: "2020/02/01".in_time_zone, name: "X") }],
        "shift_genesis" => [nil, ->(e) { e.shift_genesis(new_valid_from: "2020/02/01".in_time_zone) }],
        "cancel_shift_genesis" => [->(e) { e.shift_genesis(new_valid_from: "2020/02/01".in_time_zone) }, :cancel_shift_genesis.to_proc],
        "terminate" => [nil, ->(e) { e.terminate(termination_time: "2020/03/01".in_time_zone) }],
        "cancel_termination" => [->(e) { e.terminate(termination_time: "2020/03/01".in_time_zone) }, :cancel_termination.to_proc],
      }.each do |name, (setup, operation)|
        it "#{name} takes lock_family!'s advisory lock, then row-locks the timeline, before it writes" do
          Timecop.freeze("2020/10/02") { setup&.call(employee) }
          statements = Timecop.freeze("2020/10/03") { statements_during { operation.call(employee) } }

          expected_lock = "SELECT pg_advisory_xact_lock(hashtext('employees'), hashtext('#{employee.bitemporal_id}'))"
          advisory_lock = statements.index(expected_lock)
          row_lock = statements.index { |sql| sql.include?("FOR UPDATE") }
          first_write = statements.index { |sql| sql.match?(/\A\s*(INSERT|UPDATE)\b/i) }

          expect([advisory_lock, row_lock, first_write]).to all(be_an(Integer))
          expect(advisory_lock).to be < row_lock
          expect(row_lock).to be < first_write
        end
      end
    end

    it "re-enters the lock when the caller already holds lock_family!" do
      employee = Timecop.freeze("2020/10/01") {
        ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
      }

      Employee.transaction do
        app_lock_family!(Employee, employee.bitemporal_id.to_s)
        expect(Timecop.freeze("2020/10/02") { employee.correct(valid_from: _02_01, name: "X") }).to be true
      end
    end

    context "across connections", use_truncation: true do
      # Nothing is valid now, so a lock on the row valid now would cover nothing
      let(:start) { 1.year.from_now.beginning_of_day }
      let!(:employee) { ActiveRecord::Bitemporal.valid_at(start) { Employee.create!(name: "A") } }

      def in_thread(&block)
        Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
      end

      def current_timeline(employee)
        Employee.ignore_valid_datetime
          .where(bitemporal_id: employee.bitemporal_id, transaction_to: tt_infinity)
          .order(:valid_from)
          .pluck(:valid_from, :valid_to, :name)
      end

      it "waits for app code holding lock_family!, then builds on what that code committed" do
        locked = Queue.new
        release = Queue.new
        app = in_thread {
          Employee.transaction do
            app_lock_family!(Employee, employee.bitemporal_id.to_s)
            record = Employee.find_at_time(start, employee.id)
            record.valid_at(start + 60.days) { record.update!(name: "U") }
            locked << true
            release.pop
          end
        }
        locked.pop

        # Loaded before the app's write commits, as a caller's copy often is
        stale = Employee.find_at_time(start, employee.id)
        operation = in_thread { stale.correct(valid_from: start + 30.days, name: "X") }
        begin
          expect(operation.join(0.5)).to be_nil
        ensure
          release << true
          app.join
        end
        operation.join

        expect(current_timeline(employee)).to eq [
          [start, start + 30.days, "A"],
          [start + 30.days, start + 60.days, "X"],
          [start + 60.days, ActiveRecord::Bitemporal::DEFAULT_VALID_TO, "U"],
        ]
        expect(all_rows(Employee, employee.bitemporal_id).where("transaction_to < transaction_from")).to be_empty
      end

      it "row-locks every current row, including rows valid only in the future" do
        paused = Queue.new
        resume = Queue.new
        record = Employee.find_at_time(start, employee.id)
        # Holds the operation right after it has taken its locks
        allow(record).to receive(:find_affected_records_for_correction).and_wrap_original { |original, *args|
          paused << true
          resume.pop
          original.call(*args)
        }
        operation = in_thread { record.correct(valid_from: start + 30.days, name: "X") }
        paused.pop

        begin
          expect {
            Employee.ignore_valid_datetime.where(bitemporal_id: employee.bitemporal_id).lock("FOR UPDATE NOWAIT").to_a
          }.to raise_error(ActiveRecord::LockWaitTimeout)
        ensure
          resume << true
          operation.join
        end
      end
    end
  end
end
