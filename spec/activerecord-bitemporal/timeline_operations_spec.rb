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

  # [valid_from, valid_to, name, row id] for every current-knowledge row, zero-length ones too
  def rows(record)
    record.class.ignore_valid_datetime
      .where(bitemporal_id: record.bitemporal_id)
      .where(transaction_to: tt_infinity)
      .order(:valid_from, :valid_to)
      .pluck(:valid_from, :valid_to, :name, :id)
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

    describe "#correct" do
      subject(:correct) { Timecop.freeze("2020/10/05") { employee.correct(**correction) } }

      let(:employee) { Employee.find(employee_id) }
      let(:correction) { { valid_from: _05_01, name: "X" } }

      it "refreshes every attribute and leaves nothing to save" do
        correct

        expect(employee.name).to eq "X"
        expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
        expect(employee.changed?).to be false
      end

      it "lets a later update! build on the operation" do
        correct
        Timecop.freeze("2020/10/06") { employee.update!(emp_code: "C2") }

        # update! applies from its own time on, so look at the version valid after it
        expect(Employee.find(employee_id).attributes.slice("name", "emp_code")).to eq("name" => "X", "emp_code" => "C2")
      end

      it "discards unsaved changes, as reload does" do
        employee.emp_code = "PENDING"

        correct

        expect(employee.emp_code).to eq "C1"
        expect(employee.changed?).to be false
      end

      it "keeps the row self pointed at before as swapped_id_previously_was" do
        before = employee.swapped_id

        correct

        expect(employee.swapped_id).not_to eq before
        expect(employee.swapped_id_previously_was).to eq before
      end

      context "when self was loaded at an earlier valid time" do
        let(:employee) { Employee.find_at_time(_02_01, employee_id) }
        let(:correction) { { valid_from: _01_01, valid_to: _05_01, name: "A2" } }

        it "stays at the valid time self was loaded at" do
          correct

          expect(employee.swapped_id).to eq version_at(_02_01).swapped_id
          expect([*span(employee), employee.name]).to eq [_01_01, _05_01, "A2"]
          expect(employee.changed?).to be false
        end

        context "when self was also loaded at an earlier transaction time" do
          let(:employee) {
            ActiveRecord::Bitemporal.transaction_at("2020/10/01 12:00".in_time_zone) {
              Employee.find_at_time(_02_01, employee_id)
            }
          }

          it "reloads current knowledge" do
            correct

            expect(employee.swapped_id).to eq version_at(_02_01).swapped_id
            expect(employee.name).to eq "A2"
          end
        end
      end

      context "with a model that overrides reload" do
        let(:reload_counting_class) {
          Class.new(Employee) {
            def self.name; "ReloadCountingEmployee"; end
            attr_reader :reloads
            def reload(*)
              super.tap { @reloads = (@reloads || 0) + 1 }
            end
          }
        }
        let(:employee) { reload_counting_class.find(employee_id) }

        it "runs the model's reload hooks" do
          correct

          expect(employee.reloads).to eq 1
        end
      end

      context "with a strict-loading record" do
        let(:employee) { Employee.strict_loading.includes(:company).find(employee_id) }
        let(:correction) { { valid_from: _01_01, valid_to: _02_01, name: "A2" } }

        #   C-old |01-01, 06-01)  C-new |06-01, ∞)
        before do
          company = Timecop.freeze("2020/09/01") {
            ActiveRecord::Bitemporal.valid_at(_01_01) { Company.create!(name: "C-old") }
          }
          Timecop.freeze("2020/09/02") {
            ActiveRecord::Bitemporal.valid_at(_06_01) { Company.find(company.id).update!(name: "C-new") }
          }
          Employee.unscoped.where(bitemporal_id: employee_id).update_all(company_id: company.id)
        end

        it "brings its preloaded associations back at the time self was loaded at" do
          correct

          expect(employee.company.name).to eq "C-new"
        end
      end

      context "with ignore_* options stored on self" do
        before { employee.bitemporal_option_merge!(ignore_transaction_datetime: true) }

        it "is not moved by them" do
          correct

          expect(employee.name).to eq "X"
          expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
        end
      end

      context "when the caller's scopes hide rows" do
        context "with a default scope" do
          let(:unarchived_employee_class) {
            Class.new(Employee) {
              def self.name; "UnarchivedEmployee"; end
              default_scope { where(archived_at: nil) }
            }
          }
          let(:employee) { unarchived_employee_class.find(employee_id) }

          context "when it hides the version after the operation" do
            let(:correction) { { valid_from: _05_01, archived_at: Time.current } }

            it "finds that version" do
              correct

              expect(employee.name).to eq "B"
              expect(employee.archived_at).to be_present
            end
          end

          context "when it hides every version after the operation" do
            let(:correction) {
              { valid_from: _01_01, valid_to: ActiveRecord::Bitemporal::DEFAULT_VALID_TO, archived_at: Time.current }
            }

            it "still finds a version" do
              correct

              expect(unarchived_employee_class.where(bitemporal_id: employee_id)).not_to exist
              expect(employee.name).to eq "B"
              expect(employee.archived_at).to be_present
            end
          end
        end

        context "when the caller wraps the operation in a block" do
          # Loaded before the block, as the caller's record is
          let!(:employee) { Employee.find(employee_id) }

          it "is not held to a scoping(all_queries: true) block built before the operation" do
            scope = Timecop.freeze("2020/10/04") { Employee.where(emp_code: "C1") }

            scope.scoping(all_queries: true) { correct }

            expect(employee.name).to eq "X"
            expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
          end

          it "reads current knowledge inside a global transaction_at" do
            ActiveRecord::Bitemporal.transaction_at("2020/10/03".in_time_zone) { correct }

            expect(employee.name).to eq "X"
            expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
          end
        end
      end

      # Ruby compares a Date with a Time as midnight UTC, while the database casts the time to a
      # date in Time.zone, so outside UTC the two disagree near a boundary
      context "with a date valid time outside UTC" do
        subject(:correct) {
          Timecop.freeze(corrected_at) {
            department.correct(valid_from: Date.new(2020, 1, 15), valid_to: Date.new(2020, 2, 1), name: "A2")
          }
        }

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
        let(:corrected_at) { Time.zone.local(2020, 10, 1) }
        # Loaded when the operation runs
        let(:department) { Timecop.freeze(corrected_at) { Department.find(department_id) } }

        context "east of UTC" do
          around { |example| Time.use_zone("Tokyo", &example) }

          context "when self was loaded at a date" do
            let(:department) { Department.find_at_time(Date.new(2020, 5, 1), department_id) }

            it "stays on the version valid on that date" do
              correct

              expect([department.valid_from, department.name]).to eq [Date.new(2020, 5, 1), "B"]
            end
          end

          context "when the operation runs early on a boundary day, while UTC is still on the day before" do
            let(:corrected_at) { Time.zone.local(2020, 5, 1, 5) } # 2020-04-30 20:00 UTC

            it "stays on today's version" do
              correct

              expect([department.valid_from, department.name]).to eq [Date.new(2020, 5, 1), "B"]
            end
          end

          context "when the operation runs early on the day the timeline ends, while UTC is still on the day before" do
            let(:corrected_at) { Time.zone.local(2020, 5, 1, 5) } # 2020-04-30 20:00 UTC
            let(:department) {
              Timecop.freeze(Time.zone.local(2020, 4, 30, 12)) {
                Department.create!(name: "A", valid_from: Date.new(2020, 1, 1), valid_to: Date.new(2020, 5, 1))
              }
            }

            it "takes the last version" do
              correct

              expect([department.valid_from, department.valid_to, department.name])
                .to eq [Date.new(2020, 2, 1), Date.new(2020, 5, 1), "A"]
            end
          end
        end

        context "west of UTC" do
          around { |example| Time.use_zone("America/New_York", &example) }

          context "when the operation runs late on the day before a boundary" do
            let(:corrected_at) { Time.zone.local(2020, 4, 30, 22) } # 2020-05-01 02:00 UTC

            it "stays on today's version" do
              correct

              expect([department.valid_from, department.name]).to eq [Date.new(2020, 2, 1), "A"]
            end
          end
        end
      end
    end

    it "refuses a frozen receiver before writing, as update! does" do
      employee = Employee.find(employee_id).freeze

      expect {
        Timecop.freeze("2020/10/05") { employee.terminate(termination_time: _06_01) }
      }.to raise_error(FrozenError)
      expect(employee).to be_frozen
      expect(version_at(_06_01).valid_to).to eq ActiveRecord::Bitemporal::DEFAULT_VALID_TO
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

  # A date column stores a day, and datetime(6) a time to the microsecond. Each operation takes
  # its times as the column stores them, the way upstream's valid_at reads a time, so it
  # compares them with the stored boundaries it would write.
  describe "times the valid-time column stores differently" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_03_01) { "2020/03/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }

    shared_context "a department over days" do
      let(:_01_01) { Date.new(2020, 1, 1) }
      let(:_02_01) { Date.new(2020, 2, 1) }
      let(:_03_01) { Date.new(2020, 3, 1) }
      let(:_06_01) { Date.new(2020, 6, 1) }
      let(:infinity) { Date.new(9999, 12, 31) }
      let(:timeline_end) { infinity }

      # [Jan, Mar) A, [Mar, timeline_end) B
      let!(:record) {
        Timecop.freeze("2020/10/01") do
          department = Department.create!(name: "A", valid_from: _01_01, valid_to: timeline_end)
          ActiveRecord::Bitemporal.valid_at(_03_01) { department.update!(name: "B") }
          Department.find_at_time(_01_01, department.id)
        end
      }
    end

    shared_context "an employee changed at a fraction of a microsecond" do
      # A time as Time.current can return it, and as the column stores it
      let(:now) { "2020/03/01 09:30:00.123456789".in_time_zone }
      let(:stored_now) { "2020/03/01 09:30:00.123456".in_time_zone }

      # [Jan, now) A, [now, ∞) B: an upstream update! at now
      let!(:record) {
        Timecop.freeze("2020/10/01") do
          built = ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(now) { built.update!(name: "B") }
          Employee.find_at_time(_01_01, built.id)
        end
      }
    end

    describe "#correct" do
      subject(:correct) {
        Timecop.freeze("2020/10/06") { record.correct(valid_from: valid_from, valid_to: valid_to, name: "X") }
      }

      let(:valid_to) { nil }

      %w[Tokyo America/New_York].each do |zone|
        context "with a date column in #{zone}" do
          include_context "a department over days"
          around { |example| Time.use_zone(zone, &example) }

          context "when valid_from is the timeline's first day" do
            let(:valid_from) { _01_01 }
            let(:valid_to) { _02_01 }

            it "corrects from that day" do
              b = rows(record).last

              correct

              expect(rows(record)).to match [
                [_01_01, _02_01, "X", Integer],
                [_02_01, _03_01, "A", Integer],
                b,
              ]
            end
          end

          context "when valid_from is a segment boundary" do
            let(:valid_from) { _03_01 }

            it "corrects from it without zero-length rows" do
              a = rows(record).first

              correct

              expect(rows(record)).to match [a, [_03_01, infinity, "X", Integer]]
            end
          end

          context "when valid_to is a segment boundary" do
            let(:valid_from) { _02_01 }
            let(:valid_to) { _03_01 }

            it "corrects up to it and leaves the next segment's row alone" do
              b = rows(record).last

              correct

              expect(rows(record)).to match [
                [_01_01, _02_01, "A", Integer],
                [_02_01, _03_01, "X", Integer],
                b,
              ]
            end
          end

          context "when valid_to is the timeline's end" do
            let(:timeline_end) { _06_01 }
            let(:valid_from) { _02_01 }
            let(:valid_to) { _06_01 }

            it "accepts the span" do
              correct

              expect(rows(record)).to match [
                [_01_01, _02_01, "A", Integer],
                [_02_01, _06_01, "X", Integer],
              ]
            end
          end

          # DEFAULT_VALID_TO is midnight UTC, the day before in a zone behind UTC
          context "when valid_to is DEFAULT_VALID_TO" do
            let(:valid_from) { _02_01 }
            let(:valid_to) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }

            it "takes it as the timeline's end" do
              correct

              expect(rows(record)).to match [
                [_01_01, _02_01, "A", Integer],
                [_02_01, infinity, "X", Integer],
              ]
            end
          end
        end
      end

      context "with a time of day for a date column" do
        include_context "a department over days"

        context "when valid_from is midday on a segment boundary" do
          let(:valid_from) { "2020/03/01 12:00".in_time_zone }

          it "takes the day of valid_from" do
            a = rows(record).first

            correct

            expect(rows(record)).to match [a, [_03_01, infinity, "X", Integer]]
          end
        end

        context "when valid_to is midday on a segment boundary" do
          let(:valid_from) { "2020/02/01 12:00".in_time_zone }
          let(:valid_to) { "2020/03/01 12:00".in_time_zone }

          it "takes the day of valid_to" do
            b = rows(record).last

            correct

            expect(rows(record)).to match [
              [_01_01, _02_01, "A", Integer],
              [_02_01, _03_01, "X", Integer],
              b,
            ]
          end
        end

        context "when valid_from and valid_to fall on the same day" do
          let(:valid_from) { "2020/02/01 09:00".in_time_zone }
          let(:valid_to) { "2020/02/01 18:00".in_time_zone }

          it "raises ArgumentError and writes nothing" do
            before_correction = rows(record)

            expect { correct }.to raise_error(ArgumentError, /must be greater than/)
            expect(rows(record)).to eq before_correction
          end
        end
      end

      context "with a String or Date for a datetime column outside UTC" do
        around { |example| Time.use_zone("Tokyo", &example) }

        # [Jan, Mar) A, [Mar, ∞) B, Mar being midnight in Tokyo as upstream's valid_at reads it
        let!(:record) {
          Timecop.freeze("2020/10/01") do
            built = ActiveRecord::Bitemporal.valid_at("2020/01/01") { Employee.create!(name: "A") }
            ActiveRecord::Bitemporal.valid_at("2020/03/01") { built.update!(name: "B") }
            Employee.find_at_time(_01_01, built.id)
          end
        }

        ["2020/03/01", Date.new(2020, 3, 1)].each do |time|
          context "with valid_from as a #{time.class}" do
            let(:valid_from) { time }

            it "reads it in Time.zone, as upstream's valid_at does" do
              a = rows(record).first

              correct

              expect(rows(record)).to match [a, [_03_01, infinity, "X", Integer]]
            end
          end
        end
      end

      context "with a fraction of a microsecond for a datetime(6) column" do
        include_context "an employee changed at a fraction of a microsecond"

        context "when valid_from is the boundary an upstream update! left at the same time" do
          let(:valid_from) { now }

          it "corrects from it" do
            a = rows(record).first

            correct

            expect(rows(record)).to match [a, [stored_now, infinity, "X", Integer]]
          end
        end

        context "when valid_to is that boundary" do
          let(:valid_from) { _02_01 }
          let(:valid_to) { now }

          it "corrects up to it and leaves the next segment's row alone" do
            b = rows(record).last

            correct

            expect(rows(record)).to match [
              [_01_01, _02_01, "A", Integer],
              [_02_01, stored_now, "X", Integer],
              b,
            ]
          end
        end

        context "when valid_to is a timeline end stored at the same time" do
          # [Jan, now) A
          let!(:record) {
            Timecop.freeze("2020/10/01") { Employee.create!(name: "A", valid_from: _01_01, valid_to: now) }
          }
          let(:valid_from) { _02_01 }
          let(:valid_to) { now }

          it "accepts the span" do
            correct

            expect(rows(record)).to match [
              [_01_01, _02_01, "A", Integer],
              [_02_01, stored_now, "X", Integer],
            ]
          end
        end
      end
    end

    describe "#terminate" do
      subject(:terminate) {
        Timecop.freeze("2020/10/06") { record.terminate(termination_time: termination_time) }
      }

      %w[Tokyo America/New_York].each do |zone|
        context "with a date column in #{zone}" do
          include_context "a department over days"
          around { |example| Time.use_zone(zone, &example) }

          context "when termination_time is a segment boundary" do
            let(:termination_time) { _03_01 }

            it "terminates there without zero-length rows" do
              a = rows(record).first

              terminate

              expect(rows(record)).to match [a]
            end
          end

          context "when termination_time is the timeline's end" do
            let(:timeline_end) { _06_01 }
            let(:termination_time) { _06_01 }

            it "is a no-op" do
              expect { terminate }.not_to change { rows(record) }
            end
          end

          # DEFAULT_VALID_TO is midnight UTC, the day before in a zone behind UTC
          context "when termination_time is DEFAULT_VALID_TO" do
            let(:termination_time) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }

            it "is a no-op" do
              expect { terminate }.not_to change { rows(record) }
            end
          end
        end
      end

      context "with a time of day for a date column" do
        include_context "a department over days"

        context "when termination_time is midday on a segment boundary" do
          let(:termination_time) { "2020/03/01 12:00".in_time_zone }

          it "takes the day of termination_time" do
            a = rows(record).first

            terminate

            expect(rows(record)).to match [a]
          end
        end

        context "when termination_time is midday on the day the timeline ends" do
          let(:timeline_end) { _06_01 }
          let(:termination_time) { "2020/06/01 12:00".in_time_zone }

          it "is a no-op" do
            expect { terminate }.not_to change { rows(record) }
          end
        end
      end

      context "with a fraction of a microsecond for a datetime(6) column" do
        include_context "an employee changed at a fraction of a microsecond"
        let(:termination_time) { now }

        it "terminates at a boundary an upstream update! left at the same time" do
          a = rows(record).first

          terminate

          expect(rows(record)).to match [a]
        end

        context "with a timeline end stored at the same time" do
          # [Jan, now) A
          let!(:record) {
            Timecop.freeze("2020/10/01") { Employee.create!(name: "A", valid_from: _01_01, valid_to: now) }
          }

          it "is a no-op" do
            expect { terminate }.not_to change { rows(record) }
          end
        end
      end
    end

    describe "#shift_genesis" do
      subject(:shift_genesis) {
        Timecop.freeze("2020/10/06") { record.shift_genesis(new_valid_from: new_valid_from) }
      }

      %w[Tokyo America/New_York].each do |zone|
        context "with a date column in #{zone}" do
          include_context "a department over days"
          around { |example| Time.use_zone(zone, &example) }

          context "when new_valid_from is the current genesis" do
            let(:new_valid_from) { _01_01 }

            it "is a no-op" do
              expect { shift_genesis }.not_to change { rows(record) }
            end
          end

          context "when new_valid_from is a segment boundary" do
            let(:new_valid_from) { _03_01 }

            it "shifts there without zero-length rows and leaves that segment's row alone" do
              b = rows(record).last

              shift_genesis

              expect(rows(record)).to match [b]
            end
          end

          context "when new_valid_from is the timeline's end" do
            let(:timeline_end) { _06_01 }
            let(:new_valid_from) { _06_01 }

            it "raises ArgumentError and writes nothing" do
              before_shift = rows(record)

              expect { shift_genesis }.to raise_error(ArgumentError, /erase all segments/)
              expect(rows(record)).to eq before_shift
            end
          end
        end
      end

      context "with a time of day for a date column" do
        include_context "a department over days"

        context "when new_valid_from is midday on the current genesis" do
          let(:new_valid_from) { "2020/01/01 12:00".in_time_zone }

          it "is a no-op" do
            expect { shift_genesis }.not_to change { rows(record) }
          end
        end

        context "when new_valid_from is midday on a segment boundary" do
          let(:new_valid_from) { "2020/03/01 12:00".in_time_zone }

          it "takes the day of new_valid_from" do
            b = rows(record).last

            shift_genesis

            expect(rows(record)).to match [b]
          end
        end
      end

      context "with a fraction of a microsecond for a datetime(6) column" do
        include_context "an employee changed at a fraction of a microsecond"
        let(:new_valid_from) { now }

        it "shifts to a boundary an upstream update! left at the same time and leaves that segment's row alone" do
          b = rows(record).last

          shift_genesis

          expect(rows(record)).to match [b]
        end

        context "with a genesis an upstream create! stored at the same time" do
          # [now, ∞) A
          let!(:record) {
            Timecop.freeze("2020/10/01") { ActiveRecord::Bitemporal.valid_at(now) { Employee.create!(name: "A") } }
          }

          it "is a no-op" do
            expect { shift_genesis }.not_to change { rows(record) }
          end
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

    # Holds the advisory lock as a caller does, by the key lock_timeline! documents:
    # pg_advisory_xact_lock(hashtext(<table_name>), hashtext(<bitemporal_id as text>)).
    # The timeline operations must take this same lock.
    def hold_advisory_lock!(model, bitemporal_id)
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
        it "#{name} takes the advisory lock, then save!'s lock on the row valid now, then row-locks the timeline, before it writes" do
          Timecop.freeze("2020/10/02") { setup&.call(employee) }
          # The row lock upstream's save! takes before it writes
          save_lock = Timecop.freeze("2020/10/03") { statements_during { employee.save! } }.find { |sql| sql.include?("FOR UPDATE") }
          statements = Timecop.freeze("2020/10/03") { statements_during { operation.call(employee) } }

          expected_lock = "SELECT pg_advisory_xact_lock(hashtext('employees'), hashtext('#{employee.bitemporal_id}'))"
          advisory_lock = statements.index(expected_lock)
          now_row_lock = statements.index(save_lock)
          all_rows_lock = statements.index { |sql| sql.include?("FOR UPDATE") && sql != save_lock }
          first_write = statements.index { |sql| sql.match?(/\A\s*(INSERT|UPDATE)\b/i) }

          expect([advisory_lock, now_row_lock, all_rows_lock, first_write]).to all(be_an(Integer))
          expect(advisory_lock).to be < now_row_lock
          expect(now_row_lock).to be < all_rows_lock
          expect(all_rows_lock).to be < first_write
        end
      end
    end

    it "re-enters the advisory lock when the caller already holds it" do
      employee = Timecop.freeze("2020/10/01") {
        ActiveRecord::Bitemporal.valid_at(_01_01) { Employee.create!(name: "A") }
      }

      Employee.transaction do
        hold_advisory_lock!(Employee, employee.bitemporal_id.to_s)
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

      it "waits for a caller holding the advisory lock, then builds on what that caller committed" do
        locked = Queue.new
        release = Queue.new
        holder = in_thread {
          Employee.transaction do
            hold_advisory_lock!(Employee, employee.bitemporal_id.to_s)
            record = Employee.find_at_time(start, employee.id)
            record.valid_at(start + 60.days) { record.update!(name: "U") }
            locked << true
            release.pop
          end
        }
        locked.pop

        # Loaded before that write commits, as a caller's copy often is
        stale = Employee.find_at_time(start, employee.id)
        operation = in_thread { stale.correct(valid_from: start + 30.days, name: "X") }
        begin
          expect(operation.join(0.5)).to be_nil
        ensure
          release << true
          holder.join
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

      context "when the row valid now is stored after a future row" do
        let(:today) { Time.current.beginning_of_day }
        let(:start) { today - 100.days }

        # The past update! writes the rows valid now after the future row, so a lock
        # taking rows in storage order would take the future row first
        before do
          [[today + 30.days, "F"], [today - 50.days, "P"]].each do |time, name|
            record = Employee.find_at_time(time, employee.id)
            record.valid_at(time) { record.update!(name: name) }
          end
        end

        it "waits for an upstream update! of a future version without deadlocking, then builds on it" do
          locked = Queue.new
          release = Queue.new
          paused_employee_class = Class.new(Employee) {
            def self.name; "PausedEmployee"; end
            # Runs inside save!, after its lock on the row valid now and before it writes
            before_update { locked << true; release.pop }
          }
          writer = in_thread {
            record = paused_employee_class.find_at_time(today + 35.days, employee.id)
            record.valid_at(today + 35.days) { record.update!(name: "U") }
          }
          locked.pop

          operation = in_thread { Employee.find(employee.id).correct(valid_from: today + 40.days, name: "X") }
          begin
            expect(operation.join(0.5)).to be_nil
          ensure
            release << true
            writer.join
          end
          operation.join

          expect(current_timeline(employee)).to eq [
            [start, today - 50.days, "A"],
            [today - 50.days, today + 30.days, "P"],
            [today + 30.days, today + 35.days, "F"],
            [today + 35.days, today + 40.days, "U"],
            [today + 40.days, ActiveRecord::Bitemporal::DEFAULT_VALID_TO, "X"],
          ]
        end
      end
    end
  end
end
