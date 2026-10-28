# frozen_string_literal: true

require 'spec_helper'

ActiveRecord::Schema.define(version: 1) do
  create_table :precisionless_employees, force: true do |t|
    t.string :name

    t.integer :bitemporal_id
    t.datetime :valid_from, precision: nil
    t.datetime :valid_to, precision: nil
    t.datetime :transaction_from, precision: 6
    t.datetime :transaction_to, precision: 6

    t.timestamps
  end
end

class PrecisionlessEmployee < ActiveRecord::Base
  include ActiveRecord::Bitemporal
end

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

  # After an operation self is what reload gives: the current version valid at the time
  # self was loaded at (now when it has none), every attribute fresh. When no version is
  # valid then, it's the latest version starting before that time, else the first one.
  describe "self after an operation" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_05_01) { "2020/05/01".in_time_zone }
    let(:_06_01) { "2020/06/01".in_time_zone }

    #   A |01-01, 05-01)  B |05-01, ∞)   and now is 2020-10
    let!(:employee_id) {
      Timecop.freeze("2020/10/01") do
        ActiveRecord::Bitemporal.valid_at(_01_01) { @employee = Employee.create!(name: "A", emp_code: "C1") }
      end
      Timecop.freeze("2020/10/02") do
        ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
      end
      @employee.id
    }

    def version_at(time)
      Employee.find_at_time(time, employee_id)
    end

    def span(record)
      [record.valid_from, record.valid_to]
    end

    it "refreshes every attribute and leaves nothing to save" do
      employee = Employee.find(employee_id)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }

      expect(employee.name).to eq "X"
      expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
      expect(employee.changed?).to be false
    end

    it "lets a later update! build on the operation" do
      employee = Employee.find(employee_id)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }
      Timecop.freeze("2020/10/06") { employee.update!(emp_code: "C2") }

      # update! applies from its own time on, so look at the version valid after it
      expect(Employee.find(employee_id).attributes.slice("name", "emp_code")).to eq("name" => "X", "emp_code" => "C2")
    end

    it "stays at the valid time self was loaded at" do
      employee = Employee.find_at_time(_02_01, employee_id)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _01_01, valid_to: _05_01, name: "A2") }

      expect(employee.swapped_id).to eq version_at(_02_01).swapped_id
      expect([*span(employee), employee.name]).to eq [_01_01, _05_01, "A2"]
      expect(employee.changed?).to be false
    end

    it "reloads current knowledge when self was loaded at an earlier transaction time" do
      employee = ActiveRecord::Bitemporal.transaction_at("2020/10/01 12:00".in_time_zone) {
        Employee.find_at_time(_02_01, employee_id)
      }

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _01_01, valid_to: _05_01, name: "A2") }

      expect(employee.swapped_id).to eq version_at(_02_01).swapped_id
      expect(employee.name).to eq "A2"
    end

    it "discards unsaved changes, as reload does" do
      employee = Employee.find(employee_id)
      employee.emp_code = "PENDING"

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }

      expect(employee.emp_code).to eq "C1"
      expect(employee.changed?).to be false
    end

    it "runs the model's reload hooks" do
      reload_counting_class = Class.new(Employee) {
        def self.name; "ReloadCountingEmployee"; end
        attr_reader :reloads
        def reload(*)
          super.tap { @reloads = (@reloads || 0) + 1 }
        end
      }
      employee = reload_counting_class.find(employee_id)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }

      expect(employee.reloads).to eq 1
    end

    it "keeps the row self pointed at before as swapped_id_previously_was" do
      employee = Employee.find(employee_id)
      before = employee.swapped_id

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }

      expect(employee.swapped_id).not_to eq before
      expect(employee.swapped_id_previously_was).to eq before
    end

    it "brings a strict-loading record's preloaded associations back at the time self was loaded at" do
      #   C-old |01-01, 06-01)  C-new |06-01, ∞)
      company = Timecop.freeze("2020/09/01") {
        ActiveRecord::Bitemporal.valid_at(_01_01) { Company.create!(name: "C-old") }
      }
      Timecop.freeze("2020/09/02") {
        ActiveRecord::Bitemporal.valid_at(_06_01) { Company.find(company.id).update!(name: "C-new") }
      }
      Employee.unscoped.where(bitemporal_id: employee_id).update_all(company_id: company.id)
      employee = Employee.strict_loading.includes(:company).find(employee_id)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _01_01, valid_to: _02_01, name: "A2") }

      expect(employee.company.name).to eq "C-new"
    end

    it "is not moved by ignore_* options stored on self" do
      employee = Employee.find(employee_id)
      employee.bitemporal_option_merge!(ignore_transaction_datetime: true)

      Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }

      expect(employee.name).to eq "X"
      expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
    end

    it "refuses a frozen receiver before writing, as update! does" do
      employee = Employee.find(employee_id).freeze

      expect {
        Timecop.freeze("2020/10/05") { employee.terminate(termination_time: _06_01) }
      }.to raise_error(FrozenError)
      expect(employee).to be_frozen
      expect(version_at(_06_01).valid_to).to eq ActiveRecord::Bitemporal::DEFAULT_VALID_TO
    end

    context "when the caller's scopes hide rows" do
      let(:unarchived_employee_class) {
        Class.new(Employee) {
          def self.name; "UnarchivedEmployee"; end
          default_scope { where(archived_at: nil) }
        }
      }

      it "finds the version a default scope hides after the operation" do
        employee = unarchived_employee_class.find(employee_id)

        Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, archived_at: Time.current) }

        expect(employee.name).to eq "B"
        expect(employee.archived_at).to be_present
      end

      it "finds a version when a default scope hides all of them after the operation" do
        employee = unarchived_employee_class.find(employee_id)

        Timecop.freeze("2020/10/05") {
          employee.correct(valid_from: _01_01, valid_to: ActiveRecord::Bitemporal::DEFAULT_VALID_TO, archived_at: Time.current)
        }

        expect(unarchived_employee_class.where(bitemporal_id: employee_id)).not_to exist
        expect(employee.name).to eq "B"
        expect(employee.archived_at).to be_present
      end

      it "is not held to a scoping(all_queries: true) block built before the operation" do
        employee = Employee.find(employee_id)
        scope = Timecop.freeze("2020/10/04") { Employee.where(emp_code: "C1") }

        scope.scoping(all_queries: true) {
          Timecop.freeze("2020/10/05") { employee.correct(valid_from: _05_01, name: "X") }
        }

        expect(employee.name).to eq "X"
        expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
      end

      it "reads current knowledge inside a global transaction_at" do
        employee = Employee.find(employee_id)

        Timecop.freeze("2020/10/05") do
          ActiveRecord::Bitemporal.transaction_at("2020/10/03".in_time_zone) {
            employee.correct(valid_from: _05_01, name: "X")
          }
        end

        expect(employee.name).to eq "X"
        expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
      end
    end

    # Ruby compares a Date with a Time as midnight UTC, while the database casts the time to a
    # date in Time.zone, so outside UTC the two disagree near a boundary
    context "with a date valid time outside UTC" do
      #   A |2020-01-01, 2020-05-01)  B |2020-05-01, ∞)
      let!(:department_id) {
        Timecop.freeze("2019/12/01") do
          ActiveRecord::Bitemporal.valid_at(Date.new(2020, 1, 1)) { @department = Department.create!(name: "A") }
        end
        Timecop.freeze("2019/12/02") do
          ActiveRecord::Bitemporal.valid_at(Date.new(2020, 5, 1)) { @department.update!(name: "B") }
        end
        @department.id
      }

      def correct_inside_a(department)
        department.correct(valid_from: Date.new(2020, 1, 15), valid_to: Date.new(2020, 2, 1), name: "A2")
      end

      context "east of UTC" do
        around { |example| Time.use_zone("Tokyo", &example) }

        it "stays on the version valid on the date self was loaded at" do
          department = Department.find_at_time(Date.new(2020, 5, 1), department_id)

          Timecop.freeze("2020/10/01") { correct_inside_a(department) }

          expect([department.valid_from, department.name]).to eq [Date.new(2020, 5, 1), "B"]
        end

        it "stays on today's version early on a boundary day, while UTC is still on the day before" do
          Timecop.freeze(Time.zone.local(2020, 5, 1, 5)) do # 2020-04-30 20:00 UTC
            department = Department.find(department_id)

            correct_inside_a(department)

            expect([department.valid_from, department.name]).to eq [Date.new(2020, 5, 1), "B"]
          end
        end

        it "takes the last version on the day the timeline ends, while UTC is still on the day before" do
          department = Timecop.freeze(Time.zone.local(2020, 4, 30, 12)) {
            Department.create!(name: "A", valid_from: Date.new(2020, 1, 1), valid_to: Date.new(2020, 5, 1))
          }

          Timecop.freeze(Time.zone.local(2020, 5, 1, 5)) { correct_inside_a(department) } # 2020-04-30 20:00 UTC

          expect([department.valid_from, department.valid_to, department.name])
            .to eq [Date.new(2020, 2, 1), Date.new(2020, 5, 1), "A"]
        end
      end

      context "west of UTC" do
        around { |example| Time.use_zone("America/New_York", &example) }

        it "stays on today's version late on the day before a boundary" do
          Timecop.freeze(Time.zone.local(2020, 4, 30, 22)) do # 2020-05-01 02:00 UTC
            department = Department.find(department_id)

            correct_inside_a(department)

            expect([department.valid_from, department.name]).to eq [Date.new(2020, 2, 1), "A"]
          end
        end
      end
    end

    context "when no version is valid at that time" do
      it "points at the latest version starting before it, for every operation" do
        employee = Employee.find(employee_id)

        Timecop.freeze("2020/10/05") { employee.terminate(termination_time: _06_01) }
        expect(span(employee)).to eq [_05_01, _06_01]

        Timecop.freeze("2020/10/06") { employee.shift_genesis(new_valid_from: _02_01) }
        expect(span(employee)).to eq [_05_01, _06_01]

        Timecop.freeze("2020/10/07") { employee.cancel_shift_genesis }
        expect(span(employee)).to eq [_05_01, _06_01]

        Timecop.freeze("2020/10/08") { employee.correct(valid_from: _01_01, name: "A2") }
        expect(span(employee)).to eq [_05_01, _06_01]
        expect(employee.name).to eq "B"
        expect(employee.changed?).to be false
      end

      context "with a future-dated timeline" do
        #   A |2021-01-01, 2021-03-01)  B |2021-03-01, ∞)   while now is 2020-10
        let(:_2021_01_01) { "2021/01/01".in_time_zone }
        let(:_2021_03_01) { "2021/03/01".in_time_zone }
        let(:_2021_06_01) { "2021/06/01".in_time_zone }

        let!(:employee_id) {
          Timecop.freeze("2020/10/01") do
            ActiveRecord::Bitemporal.valid_at(_2021_01_01) { @employee = Employee.create!(name: "A") }
          end
          Timecop.freeze("2020/10/02") do
            ActiveRecord::Bitemporal.valid_at(_2021_03_01) { @employee.update!(name: "B") }
          end
          @employee.id
        }

        it "points at the first version" do
          employee = Employee.ignore_valid_datetime.find_by!(bitemporal_id: employee_id, valid_from: _2021_03_01)

          Timecop.freeze("2020/10/03") { employee.terminate(termination_time: _2021_06_01) }
          Timecop.freeze("2020/10/04") { employee.cancel_termination }

          expect([*span(employee), employee.name]).to eq [_2021_01_01, _2021_03_01, "A"]
        end
      end
    end
  end

  # A datetime column declared without a precision, as schemas from before Rails 7 declared
  # them, holds microseconds like datetime(6), but its type doesn't cut a time to them: the
  # connection does, when it writes. The operations still take a time as the column stores it.
  describe "a valid-time column without a declared precision" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
    # A time as Time.current can return it, and as the column stores it
    let(:now) { "2020/03/01 09:30:00.123456789".in_time_zone }
    let(:stored_now) { "2020/03/01 09:30:00.123456".in_time_zone }

    # [Jan, now) A, [now, ∞) B: an upstream update! at now
    let!(:employee) {
      Timecop.freeze("2020/10/01") do
        built = ActiveRecord::Bitemporal.valid_at(_01_01) { PrecisionlessEmployee.create!(name: "A") }
        ActiveRecord::Bitemporal.valid_at(now) { built.update!(name: "B") }
        PrecisionlessEmployee.find_at_time(_01_01, built.id)
      end
    }

    # [valid_from, valid_to, name, row id] for every current-knowledge row, zero-length ones too
    def rows(record)
      record.class.ignore_valid_datetime
        .where(bitemporal_id: record.bitemporal_id)
        .where(transaction_to: tt_infinity)
        .order(:valid_from, :valid_to)
        .pluck(:valid_from, :valid_to, :name, :id)
    end

    it "has a type that keeps the fraction of a microsecond" do
      expect(PrecisionlessEmployee.type_for_attribute(:valid_from).precision).to be_nil
      expect(PrecisionlessEmployee.type_for_attribute(:valid_from).cast(now)).to eq now
      expect(rows(employee).last.first).to eq stored_now
    end

    it "lets correct start at a boundary an upstream update! left at the same time" do
      a = rows(employee).first

      Timecop.freeze("2020/10/06") { employee.correct(valid_from: now, name: "X") }

      expect(rows(employee)).to match [a, [stored_now, infinity, "X", Integer]]
    end

    it "lets terminate end there" do
      a = rows(employee).first

      Timecop.freeze("2020/10/06") { employee.terminate(termination_time: now) }

      expect(rows(employee)).to match [a]
    end

    it "lets shift_genesis start there" do
      b = rows(employee).last

      Timecop.freeze("2020/10/06") { employee.shift_genesis(new_valid_from: now) }

      expect(rows(employee)).to match [b]
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
        # Holds the operation right after it has taken its locks, at its first read
        first_read = true
        allow(record).to receive(:find_all_current_knowledge_segments).and_wrap_original { |original, *args|
          if first_read
            first_read = false
            paused << true
            resume.pop
          end
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
