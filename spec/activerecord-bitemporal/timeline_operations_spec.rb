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

          it "lands on the version valid at a global valid_at's time, which self's own valid time reads" do
            ActiveRecord::Bitemporal.valid_at(_02_01) { correct }

            expect(employee.name).to eq "A"
            expect(employee.swapped_id).to eq version_at(_02_01).swapped_id
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

    describe "#reopen" do
      subject(:reopen) { Timecop.freeze("2020/10/05") { employee.reopen } }

      # Terminated at Jun on 2020-10-03, so self is loaded at May, a time a version covers
      before { Timecop.freeze("2020/10/03") { Employee.find(employee_id).terminate(termination_time: _06_01) } }

      let(:employee) { version_at(_05_01) }

      it "lands on the reopened version and leaves nothing to save" do
        reopen

        expect([*span(employee), employee.name]).to eq [_05_01, ActiveRecord::Bitemporal::DEFAULT_VALID_TO, "B"]
        expect(employee.swapped_id).to eq version_at(_06_01).swapped_id
        expect(employee.changed?).to be false
      end

      it "discards unsaved changes, as reload does" do
        employee.emp_code = "PENDING"

        reopen

        expect(employee.emp_code).to eq "C1"
        expect(employee.changed?).to be false
      end

      it "keeps the row self pointed at before as swapped_id_previously_was" do
        before = employee.swapped_id

        reopen

        expect(employee.swapped_id).not_to eq before
        expect(employee.swapped_id_previously_was).to eq before
      end

      it "refuses a frozen receiver before writing" do
        employee.freeze

        expect { reopen }.to raise_error(FrozenError)
        expect(version_at(_05_01).valid_to).to eq _06_01
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

  # Every operation leaves the current timeline with no seam (two adjacent segments with
  # equal business attributes, as an upstream update! that sets the next segment's values
  # leaves) and no zero-length row (as an upstream destroy at a segment's exact start leaves),
  # however it found it. Rows whose range and values don't change keep their rows, and a call
  # that changes nothing writes nothing.
  describe "a timeline with a seam or a zero-length row" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_03_01) { "2020/03/01".in_time_zone }
    let(:_04_01) { "2020/04/01".in_time_zone }
    let(:_05_01) { "2020/05/01".in_time_zone }
    let(:_07_01) { "2020/07/01".in_time_zone }
    let(:_08_01) { "2020/08/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
    let(:operated_at) { "2020/10/05".in_time_zone }

    let(:employee) { Employee.find_at_time(_02_01, employee_id) }

    # The current rows before the operation (after any setup it builds on)
    let!(:rows_before) { rows(employee) }

    #   A |Feb, Mar)  B |Mar, Jul)  C |Jul, ∞)   recorded on 2020-10-01
    def create_employee
      Timecop.freeze("2020/10/01") {
        id = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", emp_code: "E1") }.id
        ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(id).update!(name: "B") }
        ActiveRecord::Bitemporal.valid_at(_07_01) { Employee.find(id).update!(name: "C") }
        id
      }
    end

    # A current row Q |at, at), recorded on 2020-10-02
    def insert_zero_length_row(employee_id, at)
      Timecop.freeze("2020/10/02") {
        Employee.unscoped.insert_all!([{
          bitemporal_id: employee_id, name: "Q", emp_code: "E1", valid_from: at, valid_to: at,
          transaction_from: Time.current, transaction_to: tt_infinity, created_at: Time.current, updated_at: Time.current,
        }])
      }
    end

    # The id of the current row over [from, to) before the operation
    def row_id(from, to)
      rows_before.find { |row_from, row_to, *| row_from == from && row_to == to }.last
    end

    def an_inserted_row
      satisfy("be the id of a row the operation inserted") { |id| rows_before.none? { |*, row_id| row_id == id } }
    end

    def history
      all_rows(Employee, employee_id).order(:id).pluck(*Employee.column_names)
    end

    shared_context "a normalized timeline" do
      let!(:employee_id) { create_employee }
    end

    # An upstream update! that sets the values the next segment already has leaves a seam:
    #   A |Feb, Mar)  B |Mar, May)  B |May, Jul)  C |Jul, ∞)
    shared_context "a seam" do
      let!(:employee_id) {
        id = Timecop.freeze("2020/10/01") {
          employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", emp_code: "E1") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { Employee.find(employee.id).update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_07_01) { Employee.find(employee.id).update!(name: "C") }
          employee.id
        }
        Timecop.freeze("2020/10/02") {
          ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(id).update!(name: "B") }
        }
        id
      }
    end

    # A current row of zero length, as an upstream destroy at a segment's exact start leaves:
    #   A |Feb, Mar)  B |Mar, Jul)  Q |Jul, Jul)  C |Jul, ∞)
    shared_context "a zero-length row" do
      let!(:employee_id) { create_employee.tap { |id| insert_zero_length_row(id, _07_01) } }
      let(:zero_length_closed_at) { operated_at }
    end

    shared_examples "writing no row it closes again" do
      it "writes no row it closes again" do
        subject

        expect(all_rows(Employee, employee_id).where(transaction_from: operated_at, transaction_to: operated_at)).to be_empty
      end
    end

    shared_examples "closing the zero-length row" do
      it "closes the zero-length row and writes none" do
        subject

        expect(all_rows(Employee, employee_id).where("valid_from = valid_to").pluck(:name, :transaction_to)).to eq [
          ["Q", zero_length_closed_at],
        ]
      end
    end

    shared_examples "a call that changes nothing" do
      it "writes nothing and leaves self alone, unsaved changes included" do
        employee.emp_code = "PENDING"
        history_before = history
        attributes = employee.attributes
        swapped_id = employee.swapped_id

        expect(subject).to be true
        expect(history).to eq history_before
        expect(employee.attributes).to eq attributes
        expect(employee.swapped_id).to eq swapped_id
        expect(employee.changes).to eq("emp_code" => ["E1", "PENDING"])
      end
    end

    describe "#correct" do
      subject(:correct) { Timecop.freeze(operated_at) { employee.correct(**correction) } }

      let(:correction) { { valid_from: _02_01, valid_to: _03_01, name: "X" } }

      context "with a seam" do
        include_context "a seam"

        it "merges it while correcting another part of the timeline" do
          correct

          expect(rows(employee)).to match [
            [_02_01, _03_01, "X", an_inserted_row],
            [_03_01, _07_01, "B", an_inserted_row],
            [_07_01, infinity, "C", row_id(_07_01, infinity)],
          ]
        end

        it_behaves_like "writing no row it closes again"

        context "when the correction changes nothing" do
          let(:correction) { { valid_from: _02_01, name: "A" } }

          it "merges it" do
            expect(correct).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        include_context "a zero-length row"

        it "corrects the timeline and keeps the rows it doesn't change" do
          correct

          expect(rows(employee)).to match [
            [_02_01, _03_01, "X", an_inserted_row],
            [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
            [_07_01, infinity, "C", row_id(_07_01, infinity)],
          ]
        end

        it_behaves_like "closing the zero-length row"
        it_behaves_like "writing no row it closes again"

        # A patch of the zero-length row would be a zero-length piece
        context "when the correction spans it" do
          let(:correction) { { valid_from: _05_01, valid_to: _08_01, emp_code: "E2" } }

          it "patches the segments on either side" do
            correct

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _05_01, "B", an_inserted_row],
              [_05_01, _07_01, "B", an_inserted_row],
              [_07_01, _08_01, "C", an_inserted_row],
              [_08_01, infinity, "C", an_inserted_row],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_to: tt_infinity).order(:valid_from).pluck(:emp_code)).to eq %w[
              E1 E1 E2 E2 E1
            ]
          end

          it_behaves_like "closing the zero-length row"
        end

        context "when the correction changes nothing" do
          let(:correction) { { valid_from: _02_01, name: "A" } }

          it "keeps every other row" do
            expect(correct).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when the correction changes nothing" do
          let(:correction) { { valid_from: _02_01, name: "A" } }

          it_behaves_like "a call that changes nothing"
        end
      end
    end

    describe "#terminate" do
      subject(:terminate) { Timecop.freeze(operated_at) { employee.terminate(termination_time: termination_time) } }

      let(:termination_time) { _08_01 }

      context "with a seam" do
        include_context "a seam"

        it "merges it while ending the timeline" do
          terminate

          expect(rows(employee)).to match [
            [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
            [_03_01, _07_01, "B", an_inserted_row],
            [_07_01, _08_01, "C", an_inserted_row],
          ]
        end

        it_behaves_like "writing no row it closes again"

        context "when it terminates at the current end" do
          let(:termination_time) { infinity }

          it "merges it" do
            expect(terminate).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        include_context "a zero-length row"

        it "ends the timeline and keeps the rows it doesn't change" do
          terminate

          expect(rows(employee)).to match [
            [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
            [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
            [_07_01, _08_01, "C", an_inserted_row],
          ]
        end

        it_behaves_like "closing the zero-length row"
        it_behaves_like "writing no row it closes again"

        context "when it terminates at the current end" do
          let(:termination_time) { infinity }

          it "keeps every other row" do
            expect(terminate).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when it terminates at the current end" do
          let(:termination_time) { infinity }

          it_behaves_like "a call that changes nothing"
        end
      end
    end

    describe "#shift_genesis" do
      subject(:shift_genesis) { Timecop.freeze(operated_at) { employee.shift_genesis(new_valid_from: new_valid_from) } }

      context "with a seam" do
        include_context "a seam"

        context "when it shifts backward" do
          let(:new_valid_from) { _01_01 }

          it "merges it while extending the first segment" do
            shift_genesis

            expect(rows(employee)).to match [
              [_01_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end

        context "when it shifts forward into it" do
          let(:new_valid_from) { _04_01 }

          it "merges the trimmed segment with the one after it" do
            shift_genesis

            expect(rows(employee)).to match [
              [_04_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end

        context "when it shifts to the current genesis" do
          let(:new_valid_from) { _02_01 }

          it "merges it" do
            expect(shift_genesis).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        include_context "a zero-length row"

        context "when it shifts backward" do
          let(:new_valid_from) { _01_01 }

          it "extends the first segment and keeps the rows it doesn't change" do
            shift_genesis

            expect(rows(employee)).to match [
              [_01_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
          it_behaves_like "writing no row it closes again"
        end

        context "when it shifts forward" do
          let(:new_valid_from) { _04_01 }

          it "trims the timeline and keeps the rows it doesn't change" do
            shift_genesis

            expect(rows(employee)).to match [
              [_04_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
          it_behaves_like "writing no row it closes again"
        end

        context "when it shifts to the current genesis" do
          let(:new_valid_from) { _02_01 }

          it "keeps every other row" do
            expect(shift_genesis).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end

        #   Q |Feb, Feb)  A |Feb, Mar)  B |Mar, Jul)  C |Jul, ∞)
        context "when it sits at the genesis" do
          let!(:employee_id) { create_employee.tap { |id| insert_zero_length_row(id, _02_01) } }
          let(:new_valid_from) { _01_01 }

          it "extends the first segment that holds a time" do
            shift_genesis

            expect(rows(employee)).to match [
              [_01_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when it shifts to the current genesis" do
          let(:new_valid_from) { _02_01 }

          it_behaves_like "a call that changes nothing"
        end
      end
    end

    describe "#cancel_termination" do
      subject(:cancel_termination) { Timecop.freeze(operated_at) { employee.cancel_termination } }

      # Self, terminated at Aug on 2020-10-03
      shared_context "terminated" do
        let(:employee) { super().tap { |e| Timecop.freeze("2020/10/03") { e.terminate(termination_time: _08_01) } } }
      end

      context "with a seam" do
        include_context "a seam"

        context "when the termination merged it" do
          include_context "terminated"

          it "restores the timeline with it merged, keeping the merged row" do
            cancel_termination

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end

        context "when it isn't terminated" do
          it "merges it" do
            expect(cancel_termination).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        include_context "a zero-length row"

        context "when the termination closed it" do
          include_context "terminated"
          let(:zero_length_closed_at) { "2020/10/03".in_time_zone }

          it "restores the timeline without it, keeping the rows it doesn't change" do
            cancel_termination

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
          end

          it_behaves_like "closing the zero-length row"
          it_behaves_like "writing no row it closes again"
        end

        context "when it isn't terminated" do
          it "keeps every other row" do
            expect(cancel_termination).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when it's terminated" do
          include_context "terminated"

          it "rewrites only the segment the termination cut" do
            cancel_termination

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_to: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_07_01, _08_01, "C"],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_from: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_07_01, infinity, "C"],
            ]
          end
        end

        context "when it isn't terminated" do
          it_behaves_like "a call that changes nothing"
        end
      end
    end

    describe "#cancel_shift_genesis" do
      subject(:cancel_shift_genesis) { Timecop.freeze(operated_at) { employee.cancel_shift_genesis } }

      # Self, its genesis shifted to shifted_to on 2020-10-03
      shared_context "shifted" do
        let(:employee) { super().tap { |e| Timecop.freeze("2020/10/03") { e.shift_genesis(new_valid_from: shifted_to) } } }
      end

      context "with a seam" do
        include_context "a seam"

        context "when the shift merged it" do
          include_context "shifted"
          let(:shifted_to) { _04_01 }

          it "restores the timeline with it merged" do
            cancel_shift_genesis

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end

        context "when its genesis was never shifted" do
          it "merges it" do
            expect(cancel_shift_genesis).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        include_context "a zero-length row"

        context "when the shift closed it" do
          include_context "shifted"
          let(:shifted_to) { _04_01 }
          let(:zero_length_closed_at) { "2020/10/03".in_time_zone }

          it "restores the timeline without it, keeping the rows it doesn't change" do
            cancel_shift_genesis

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
          it_behaves_like "writing no row it closes again"
        end

        context "when its genesis was never shifted" do
          it "keeps every other row" do
            expect(cancel_shift_genesis).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when its genesis was shifted" do
          include_context "shifted"
          let(:shifted_to) { _01_01 }

          it "rewrites only the segment the shift extended" do
            cancel_shift_genesis

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", an_inserted_row],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_to: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_01_01, _03_01, "A"],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_from: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_02_01, _03_01, "A"],
            ]
          end
        end

        context "when its genesis was never shifted" do
          it_behaves_like "a call that changes nothing"
        end
      end

      # A genesis shift recorded over a timeline of zero-length rows alone, as an operation could
      # record one before every operation closed such rows. It can't be built through them now:
      #   2020-10-01  A |May, ∞)
      #   2020-10-02  A |May, May)   an upstream destroy at the genesis
      #   2020-10-03  A |Jan, May)   the genesis shifted to Jan
      # The snapshot the shift ended holds no time, so there's no timeline in it to restore.
      # The one before it ended with the destroy, and the shift was recorded after that.
      context "when the shift was recorded over zero-length rows alone" do
        let!(:employee_id) {
          id = Timecop.freeze("2020/10/01") {
            ActiveRecord::Bitemporal.valid_at(_05_01) { Employee.create!(name: "A", emp_code: "E1") }.id
          }
          Timecop.freeze("2020/10/02") { ActiveRecord::Bitemporal.valid_at(_05_01) { Employee.find(id).destroy } }
          Timecop.freeze("2020/10/03") {
            Employee.unscoped.where(bitemporal_id: id, transaction_to: tt_infinity)
              .update_all(transaction_to: Time.current, deleted_at: Time.current)
            Employee.unscoped.insert_all!([{
              bitemporal_id: id, name: "A", emp_code: "E1", valid_from: _01_01, valid_to: _05_01,
              transaction_from: Time.current, transaction_to: tt_infinity, created_at: Time.current, updated_at: Time.current,
            }])
          }
          id
        }

        it "refuses and writes nothing" do
          history_before = history

          expect { cancel_shift_genesis }.to raise_error(ActiveRecord::Bitemporal::PreShiftGenesisStateNotFoundError)
          expect(history).to eq history_before
        end
      end
    end

    describe "#reopen" do
      subject(:reopen) { Timecop.freeze(operated_at) { employee.reopen } }

      # Self, terminated at Aug on 2020-10-03
      shared_context "terminated" do
        let(:employee) { super().tap { |e| Timecop.freeze("2020/10/03") { e.terminate(termination_time: _08_01) } } }
      end

      context "with a seam" do
        include_context "a seam"

        context "when the termination merged it" do
          include_context "terminated"

          it "lifts the end, keeping the merged row" do
            reopen

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end

        context "when it isn't terminated" do
          it "merges it" do
            expect(reopen).to be true
            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", an_inserted_row],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "writing no row it closes again"
        end
      end

      context "with a zero-length row" do
        # Recorded after the termination, at the end of the timeline:
        #   A |Feb, Mar)  B |Mar, Jul)  C |Jul, Aug)  Q |Aug, Aug)
        context "when it ends a terminated timeline" do
          let!(:employee_id) {
            create_employee.tap { |id|
              Timecop.freeze("2020/10/01 12:00") { Employee.find_at_time(_02_01, id).terminate(termination_time: _08_01) }
              insert_zero_length_row(id, _08_01)
            }
          }
          let(:zero_length_closed_at) { operated_at }

          it "continues the last segment that holds a time, keeping the rows it doesn't change" do
            reopen

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
          end

          it_behaves_like "closing the zero-length row"
          it_behaves_like "writing no row it closes again"
        end

        context "when it isn't terminated" do
          include_context "a zero-length row"

          it "keeps every other row" do
            expect(reopen).to be true
            expect(rows(employee)).to eq [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", row_id(_07_01, infinity)],
            ]
          end

          it_behaves_like "closing the zero-length row"
        end
      end

      context "with neither" do
        include_context "a normalized timeline"

        context "when it's terminated" do
          include_context "terminated"

          it "rewrites only the last segment" do
            reopen

            expect(rows(employee)).to match [
              [_02_01, _03_01, "A", row_id(_02_01, _03_01)],
              [_03_01, _07_01, "B", row_id(_03_01, _07_01)],
              [_07_01, infinity, "C", an_inserted_row],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_to: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_07_01, _08_01, "C"],
            ]
            expect(all_rows(Employee, employee_id).where(transaction_from: operated_at).pluck(:valid_from, :valid_to, :name)).to eq [
              [_07_01, infinity, "C"],
            ]
          end
        end

        context "when it isn't terminated" do
          it_behaves_like "a call that changes nothing"
        end
      end
    end

    # The predicates read the timeline the operations act on, so they look past zero-length rows too
    describe "#shifted_genesis?" do
      context "with a zero-length row before the genesis" do
        #   Q |Jan, Jan)  A |Feb, Mar)  B |Mar, Jul)  C |Jul, ∞)
        let!(:employee_id) { create_employee.tap { |id| insert_zero_length_row(id, _01_01) } }

        it "reads the genesis from the first segment that holds a time" do
          expect(employee.shifted_genesis?).to be false
        end
      end

      # An upstream destroy at the genesis leaves A |Feb, Feb) in front of B
      context "with a zero-length row at the original genesis" do
        #   A |Feb, Feb)  B |Mar, Jul)  C |Jul, ∞)
        let!(:employee_id) {
          create_employee.tap { |id|
            Timecop.freeze("2020/10/02") { ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.find(id).destroy } }
          }
        }
        let(:employee) { Employee.find_at_time(_03_01, employee_id) }

        it "reads the genesis from the first segment that holds a time" do
          expect(employee.shifted_genesis?).to be true
        end
      end
    end

    # An upstream destroy at the genesis leaves only A |Feb, Feb): no segment holds a time
    context "when every current row is zero-length" do
      # Self, loaded before the destroy
      let!(:employee) {
        id = Timecop.freeze("2020/10/01") {
          ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", emp_code: "E1") }.id
        }
        Employee.find_at_time(_02_01, id).tap {
          Timecop.freeze("2020/10/02") { ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.find(id).destroy } }
        }
      }
      let(:employee_id) { employee.id }

      {
        "correct" => ->(e) { e.correct(valid_from: "2020/02/01".in_time_zone, name: "X") },
        "shift_genesis" => ->(e) { e.shift_genesis(new_valid_from: "2020/01/01".in_time_zone) },
        "cancel_shift_genesis" => :cancel_shift_genesis.to_proc,
        "terminate" => ->(e) { e.terminate(termination_time: "2020/03/01".in_time_zone) },
        "cancel_termination" => :cancel_termination.to_proc,
        "reopen" => :reopen.to_proc,
      }.each do |name, operation|
        it "#{name} finds no version and writes nothing" do
          history_before = history

          expect { Timecop.freeze(operated_at) { operation.call(employee) } }.to raise_error(ActiveRecord::RecordNotFound)
          expect(history).to eq history_before
        end
      end

      it "reads as neither terminated nor shifted" do
        expect(employee.terminated?).to be false
        expect(employee.shifted_genesis?).to be false
      end
    end
  end

  # An operation inserts every row with save_without_bitemporal_callbacks!(validate: false) and
  # closes every row with update_columns. So the model's validations never run on its rows: the
  # only check is that the current rows don't overlap, and validating new values is the caller's
  # job. Each inserted row runs the model's save and create callbacks, a closed row runs none,
  # and upstream's bitemporal_* callbacks never run. Upstream's after_create gives every inserted
  # row the entity's id, so Rails runs the commit callbacks on one of them: once for the
  # operation, however many rows it inserts.
  describe "validations and callbacks during an operation" do
    let(:_01_01) { "2020/01/01".in_time_zone }
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_03_01) { "2020/03/01".in_time_zone }
    let(:_04_01) { "2020/04/01".in_time_zone }
    let(:_05_01) { "2020/05/01".in_time_zone }
    let(:_07_01) { "2020/07/01".in_time_zone }
    let(:_08_01) { "2020/08/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
    let(:operated_at) { "2020/10/05".in_time_zone }

    # The callbacks the model ran, in order, and the columns each row it saved reported as changed
    let(:callbacks) { [] }
    let(:saved_columns) { [] }

    # The operations run through this model on the employees table. Its validation rejects a blank
    # name, and it logs every validation, save, create, update, destroy, bitemporal_* and commit
    # callback it runs.
    let(:model) {
      log = callbacks
      columns = saved_columns
      Class.new(ActiveRecord::Base) {
        def self.name; "CallbackLoggingEmployee"; end
        self.table_name = "employees"
        include ActiveRecord::Bitemporal

        validates :name, presence: true

        %i[
          before_validation after_validation
          before_save after_save before_create after_create before_update after_update before_destroy after_destroy
          before_bitemporal_create after_bitemporal_create before_bitemporal_update after_bitemporal_update
          before_bitemporal_destroy after_bitemporal_destroy
          after_commit after_create_commit after_update_commit after_save_commit after_destroy_commit
        ].each { |callback| public_send(callback) { log << callback } }
        around_save { |_, save| log << :around_save; save.call }
        around_create { |_, create| log << :around_create; create.call }
        after_save { columns << saved_changes.keys.sort }
      }
    }

    # The callbacks one inserted row runs, and those that run on commit (Rails runs commit
    # callbacks last defined first)
    let(:insert_callbacks) { %i[before_save around_save before_create around_create after_create after_save] }
    let(:commit_callbacks) { %i[after_save_commit after_create_commit after_commit] }

    #   A |Feb, Mar)  B |Mar, Jul)  C |Jul, ∞)   recorded on 2020-10-01 through Employee, which has
    #   neither the model's validation nor its callbacks
    let(:b_name) { "B" }
    let!(:employee_id) {
      Timecop.freeze("2020/10/01") {
        id = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", emp_code: "E1") }.id
        ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(id).update!(name: b_name) }
        ActiveRecord::Bitemporal.valid_at(_07_01) { Employee.find(id).update!(name: "C") }
        id
      }
    }

    let(:employee) { model.find_at_time(_02_01, employee_id) }

    # [valid_from, valid_to, name, emp_code] of every current row
    def timeline
      all_rows(Employee, employee_id).where(transaction_to: tt_infinity).order(:valid_from)
        .pluck(:valid_from, :valid_to, :name, :emp_code)
    end

    # [valid_from, valid_to, name] of the rows the operation inserted, and of those it closed
    def inserted
      all_rows(Employee, employee_id).where(transaction_from: operated_at).order(:valid_from)
        .pluck(:valid_from, :valid_to, :name)
    end

    def closed
      all_rows(Employee, employee_id).where(transaction_to: operated_at).order(:valid_from)
        .pluck(:valid_from, :valid_to, :name)
    end

    def history
      all_rows(Employee, employee_id).order(:id).pluck(*Employee.column_names)
    end

    describe "validations" do
      subject(:correct) { Timecop.freeze(operated_at) { employee.correct(**correction) } }

      context "when the correction sets a value the model's validation rejects" do
        let(:correction) { { valid_from: _04_01, name: "" } }

        it "writes it without running the validation" do
          expect(correct).to be true
          expect(timeline).to eq [
            [_02_01, _03_01, "A", "E1"],
            [_03_01, _04_01, "B", "E1"],
            [_04_01, _07_01, "", "E1"],
            [_07_01, infinity, "C", "E1"],
          ]
          expect(callbacks).not_to include(:before_validation, :after_validation)
        end
      end

      # B has no name, as a row stored before the validation was added can
      context "when a segment the correction patches holds a value the validation rejects" do
        let(:b_name) { nil }
        let(:correction) { { valid_from: _04_01, valid_to: _08_01, emp_code: "E2" } }

        it "keeps that value in the pieces it writes" do
          expect(correct).to be true
          expect(timeline).to eq [
            [_02_01, _03_01, "A", "E1"],
            [_03_01, _04_01, nil, "E1"],
            [_04_01, _07_01, nil, "E2"],
            [_07_01, _08_01, "C", "E2"],
            [_08_01, infinity, "C", "E1"],
          ]
        end
      end

      # Only rows written around the gem overlap, here Q |May, Aug) over B and C
      context "when the current rows overlap" do
        let(:correction) { { valid_from: _02_01, valid_to: _03_01, name: "X" } }

        before {
          Timecop.freeze("2020/10/02") {
            Employee.unscoped.insert_all!([{
              bitemporal_id: employee_id, name: "Q", emp_code: "E1", valid_from: _05_01, valid_to: _08_01,
              transaction_from: Time.current, transaction_to: tt_infinity, created_at: Time.current, updated_at: Time.current,
            }])
          }
        }

        it "still raises RecordInvalid and writes nothing" do
          history_before = history

          expect { correct }.to raise_error(ActiveRecord::RecordInvalid, /Overlapping valid periods/)
          expect(history).to eq history_before
        end
      end
    end

    # after_commit runs only when the transaction commits, so these examples commit each operation
    describe "callbacks", use_truncation: true do
      describe "#correct" do
        subject(:correct) { Timecop.freeze(operated_at) { employee.correct(**correction) } }

        #   A |Feb, Mar)  B |Mar, Apr)  X |Apr, Aug)  C |Aug, ∞)
        let(:correction) { { valid_from: _04_01, valid_to: _08_01, name: "X" } }

        # The whole log, so no validation, update, destroy or bitemporal_* callback ran either
        it "runs the save and create callbacks once for each row it inserts, none for a row it closes, and the commit callbacks once" do
          correct

          expect(inserted).to eq [[_03_01, _04_01, "B"], [_04_01, _08_01, "X"], [_08_01, infinity, "C"]]
          expect(closed).to eq [[_03_01, _07_01, "B"], [_07_01, infinity, "C"]]
          expect(callbacks).to eq [*insert_callbacks * 3, *commit_callbacks]
        end

        # Each row is a new copy of a version, so every column holding a value counts as changed
        it "reports every column holding a value as changed on each row it inserts" do
          correct

          expect(saved_columns).to eq [
            %w[bitemporal_id created_at emp_code id name transaction_from transaction_to updated_at valid_from valid_to],
          ] * 3
        end

        #   A |Feb, Mar)  B |Mar, May)  B |May, Jul)  C |Jul, ∞)
        context "when it merges a seam" do
          let!(:employee_id) {
            id = Timecop.freeze("2020/10/01") {
              employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", emp_code: "E1") }
              ActiveRecord::Bitemporal.valid_at(_05_01) { Employee.find(employee.id).update!(name: "B") }
              ActiveRecord::Bitemporal.valid_at(_07_01) { Employee.find(employee.id).update!(name: "C") }
              employee.id
            }
            Timecop.freeze("2020/10/02") {
              ActiveRecord::Bitemporal.valid_at(_03_01) { Employee.find(id).update!(name: "B") }
            }
            id
          }
          let(:correction) { { valid_from: _02_01, valid_to: _03_01, name: "X" } }

          it "runs the commit callbacks once for the merged row and the correction" do
            correct

            expect(inserted).to eq [[_02_01, _03_01, "X"], [_03_01, _07_01, "B"]]
            expect(callbacks).to eq [*insert_callbacks * 2, *commit_callbacks]
          end
        end

        context "when the correction changes nothing" do
          let(:correction) { { valid_from: _02_01, name: "A" } }

          it "runs no callback, commit callbacks included" do
            expect(correct).to be true
            expect(callbacks).to be_empty
          end
        end
      end

      describe "#terminate" do
        subject(:terminate) { Timecop.freeze(operated_at) { employee.terminate(termination_time: termination_time) } }

        let(:termination_time) { _05_01 }

        it "runs the save and create callbacks for the row it inserts, and the commit callbacks once" do
          terminate

          expect(inserted).to eq [[_03_01, _05_01, "B"]]
          expect(closed).to eq [[_03_01, _07_01, "B"], [_07_01, infinity, "C"]]
          expect(callbacks).to eq [*insert_callbacks, *commit_callbacks]
        end

        # Nothing is saved, so no record is left for the commit callbacks to run on
        context "when it ends the timeline at a segment's end" do
          let(:termination_time) { _07_01 }

          it "only closes rows, running no callback, commit callbacks included" do
            terminate

            expect(inserted).to be_empty
            expect(closed).to eq [[_07_01, infinity, "C"]]
            expect(callbacks).to be_empty
          end
        end
      end

      describe "#shift_genesis" do
        subject(:shift_genesis) { Timecop.freeze(operated_at) { employee.shift_genesis(new_valid_from: new_valid_from) } }

        let(:new_valid_from) { _01_01 }

        it "runs the save and create callbacks for the row it inserts, and the commit callbacks once" do
          shift_genesis

          expect(inserted).to eq [[_01_01, _03_01, "A"]]
          expect(closed).to eq [[_02_01, _03_01, "A"]]
          expect(callbacks).to eq [*insert_callbacks, *commit_callbacks]
        end

        # Nothing is saved, so no record is left for the commit callbacks to run on
        context "when it moves the genesis forward to a segment's start" do
          let(:new_valid_from) { _03_01 }

          it "only closes rows, running no callback, commit callbacks included" do
            shift_genesis

            expect(inserted).to be_empty
            expect(closed).to eq [[_02_01, _03_01, "A"]]
            expect(callbacks).to be_empty
          end
        end
      end

      describe "#cancel_termination" do
        subject(:cancel_termination) { Timecop.freeze(operated_at) { employee.cancel_termination } }

        # Terminated at May on 2020-10-03, through Employee
        before { Timecop.freeze("2020/10/03") { Employee.find_at_time(_02_01, employee_id).terminate(termination_time: _05_01) } }

        it "runs the save and create callbacks once for each row it restores, and the commit callbacks once" do
          cancel_termination

          expect(inserted).to eq [[_03_01, _07_01, "B"], [_07_01, infinity, "C"]]
          expect(closed).to eq [[_03_01, _05_01, "B"]]
          expect(callbacks).to eq [*insert_callbacks * 2, *commit_callbacks]
        end
      end

      describe "#cancel_shift_genesis" do
        subject(:cancel_shift_genesis) { Timecop.freeze(operated_at) { employee.cancel_shift_genesis } }

        # Shifted back to Jan on 2020-10-03, through Employee
        before { Timecop.freeze("2020/10/03") { Employee.find_at_time(_02_01, employee_id).shift_genesis(new_valid_from: _01_01) } }

        it "runs the save and create callbacks for the row it restores, and the commit callbacks once" do
          cancel_shift_genesis

          expect(inserted).to eq [[_02_01, _03_01, "A"]]
          expect(closed).to eq [[_01_01, _03_01, "A"]]
          expect(callbacks).to eq [*insert_callbacks, *commit_callbacks]
        end
      end

      describe "#reopen" do
        subject(:reopen) { Timecop.freeze(operated_at) { employee.reopen } }

        # Terminated at May on 2020-10-03, through Employee
        before { Timecop.freeze("2020/10/03") { Employee.find_at_time(_02_01, employee_id).terminate(termination_time: _05_01) } }

        it "runs the save and create callbacks for the row it inserts, and the commit callbacks once" do
          reopen

          expect(inserted).to eq [[_03_01, infinity, "B"]]
          expect(closed).to eq [[_03_01, _05_01, "B"]]
          expect(callbacks).to eq [*insert_callbacks, *commit_callbacks]
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

  # An operation works on the entity's whole current timeline, as upstream's own writes
  # record at now, whatever block or scope the caller runs it in.
  describe "the caller's blocks and scopes" do
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_03_01) { "2020/03/01".in_time_zone }
    let(:_04_01) { "2020/04/01".in_time_zone }
    let(:_05_01) { "2020/05/01".in_time_zone }
    let(:_06_01) { "2020/06/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }

    # Runs the operation as the caller does: outside any block, unless a context says otherwise
    let(:callers_block) { ->(operation) { operation.call } }

    def in_callers_block(&operation)
      callers_block.call(operation)
    end

    # [valid_from, valid_to, name, *attributes] of every current-knowledge row, read outside
    # the caller's block
    def timeline(bitemporal_id, *attributes)
      Employee.ignore_valid_datetime
        .where(bitemporal_id: bitemporal_id, transaction_to: tt_infinity)
        .order(:valid_from)
        .pluck(:valid_from, :valid_to, :name, *attributes)
    end

    describe "a transaction_at, valid_at or scoping block" do
      # A transaction time from before B was re-recorded
      let(:past) { "2020/10/02".in_time_zone }

      #   A |02-01, 03-01)  B |03-01, 05-01)  C |05-01, ∞)   recorded on 2020-10-01,
      #   then B re-recorded in place as B2 on 2020-10-03
      let!(:employee_id) {
        Timecop.freeze("2020/10/01") do
          @employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A") }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B") }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C") }
        end
        Timecop.freeze("2020/10/03") do
          b = Employee.find_at_time(_03_01, @employee.id)
          b.force_update { b.update!(name: "B2") }
        end
        @employee.id
      }
      # Loaded before the block, as the caller's record is
      let!(:employee) { Employee.find_at_time(_03_01, employee_id) }

      shared_examples "in or out of the caller's blocks" do |examples|
        context "outside any block" do
          include_examples examples
        end

        context "in a transaction_at block from before B2 was recorded" do
          let(:callers_block) { ->(operation) { ActiveRecord::Bitemporal.transaction_at(past) { operation.call } } }

          include_examples examples
        end

        context "in a transaction_at! block from before B2 was recorded" do
          let(:callers_block) { ->(operation) { ActiveRecord::Bitemporal.transaction_at!(past) { operation.call } } }

          include_examples examples
        end

        context "in a bitemporal_at block from before B2 was recorded" do
          let(:callers_block) { ->(operation) { ActiveRecord::Bitemporal.bitemporal_at(past) { operation.call } } }

          include_examples examples
        end

        context "in a valid_at! block at a time only A covers" do
          let(:callers_block) { ->(operation) { ActiveRecord::Bitemporal.valid_at!(_02_01) { operation.call } } }

          include_examples examples
        end

        context "in a scoping block only C matches" do
          let(:callers_block) { ->(operation) { Employee.where(name: "C").scoping { operation.call } } }

          include_examples examples
        end
      end

      describe "#correct" do
        subject(:correct) {
          Timecop.freeze("2020/10/05") {
            in_callers_block { employee.correct(valid_from: _02_01, valid_to: _06_01, name: "X") }
          }
        }

        shared_examples "patching every current segment in the range" do
          it "patches every current segment in the range" do
            correct

            expect(timeline(employee_id)).to eq [[_02_01, _06_01, "X"], [_06_01, infinity, "C"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "patching every current segment in the range"
      end

      describe "#terminate" do
        subject(:terminate) {
          Timecop.freeze("2020/10/05") { in_callers_block { employee.terminate(termination_time: _04_01) } }
        }

        shared_examples "ending the current timeline" do
          it "ends the current timeline there" do
            terminate

            expect(timeline(employee_id)).to eq [[_02_01, _03_01, "A"], [_03_01, _04_01, "B2"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "ending the current timeline"
      end

      describe "#shift_genesis" do
        subject(:shift_genesis) {
          Timecop.freeze("2020/10/05") { in_callers_block { employee.shift_genesis(new_valid_from: _04_01) } }
        }

        shared_examples "starting the current timeline later" do
          it "starts the current timeline there" do
            shift_genesis

            expect(timeline(employee_id)).to eq [[_04_01, _05_01, "B2"], [_05_01, infinity, "C"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "starting the current timeline later"
      end

      describe "#cancel_termination" do
        subject(:cancel_termination) { Timecop.freeze("2020/10/05") { in_callers_block { employee.cancel_termination } } }

        before { Timecop.freeze("2020/10/04") { employee.terminate(termination_time: _04_01) } }

        shared_examples "restoring the current timeline" do
          it "restores the current timeline from before the termination" do
            cancel_termination

            expect(timeline(employee_id)).to eq [[_02_01, _03_01, "A"], [_03_01, _05_01, "B2"], [_05_01, infinity, "C"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "restoring the current timeline"
      end

      describe "#cancel_shift_genesis" do
        subject(:cancel_shift_genesis) { Timecop.freeze("2020/10/05") { in_callers_block { employee.cancel_shift_genesis } } }

        before { Timecop.freeze("2020/10/04") { employee.shift_genesis(new_valid_from: _04_01) } }

        shared_examples "restoring the current timeline" do
          it "restores the current timeline from before the shift" do
            cancel_shift_genesis

            expect(timeline(employee_id)).to eq [[_02_01, _03_01, "A"], [_03_01, _05_01, "B2"], [_05_01, infinity, "C"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "restoring the current timeline"
      end

      describe "#reopen" do
        subject(:reopen) { Timecop.freeze("2020/10/05") { in_callers_block { employee.reopen } } }

        before { Timecop.freeze("2020/10/04") { employee.terminate(termination_time: _04_01) } }

        shared_examples "continuing the current timeline" do
          it "continues the current timeline's last segment" do
            reopen

            expect(timeline(employee_id)).to eq [[_02_01, _03_01, "A"], [_03_01, infinity, "B2"]]
          end
        end

        it_behaves_like "in or out of the caller's blocks", "continuing the current timeline"
      end

      describe "#terminated?" do
        subject(:terminated) { in_callers_block { employee.terminated? } }

        context "after a termination" do
          before { Timecop.freeze("2020/10/04") { employee.terminate(termination_time: _04_01) } }

          shared_examples "terminated" do
            it { is_expected.to be true }
          end

          it_behaves_like "in or out of the caller's blocks", "terminated"
        end

        context "after a termination and its cancel, both recorded after the block's time" do
          before do
            Timecop.freeze("2020/10/04") { employee.terminate(termination_time: _04_01) }
            Timecop.freeze("2020/10/05") { employee.cancel_termination }
          end

          shared_examples "not terminated" do
            it { is_expected.to be false }
          end

          it_behaves_like "in or out of the caller's blocks", "not terminated"
        end
      end

      describe "#shifted_genesis?" do
        subject(:shifted_genesis) { in_callers_block { employee.shifted_genesis? } }

        context "after a genesis shift" do
          before { Timecop.freeze("2020/10/04") { employee.shift_genesis(new_valid_from: _04_01) } }

          shared_examples "shifted" do
            it { is_expected.to be true }
          end

          it_behaves_like "in or out of the caller's blocks", "shifted"
        end

        context "after a genesis shift and its cancel, both recorded after the block's time" do
          before do
            Timecop.freeze("2020/10/04") { employee.shift_genesis(new_valid_from: _04_01) }
            Timecop.freeze("2020/10/05") { employee.cancel_shift_genesis }
          end

          shared_examples "not shifted" do
            it { is_expected.to be false }
          end

          it_behaves_like "in or out of the caller's blocks", "not shifted"
        end
      end

      describe "the lock on the row valid now" do
        subject(:row_locks) {
          Timecop.freeze("2020/10/05") {
            row_locks_during { in_callers_block { employee.correct(valid_from: _05_01, name: "X") } }
          }
        }

        # Every FOR UPDATE statement the block runs, with the values bound to it
        def row_locks_during(&block)
          locks = []
          callback = ->(*, payload) {
            next unless payload[:sql].include?("FOR UPDATE")

            binds = payload[:type_casted_binds]
            locks << [payload[:sql], binds.respond_to?(:call) ? binds.call : binds]
          }
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
          locks
        end

        shared_examples "save!'s lock" do
          it "is the lock upstream's save! takes outside any block, at the same time" do
            locks = row_locks
            save_lock = Timecop.freeze("2020/10/05") { row_locks_during { Employee.find(employee_id).save! } }.sole

            expect(locks.first).to eq save_lock
          end
        end

        it_behaves_like "in or out of the caller's blocks", "save!'s lock"
      end

      context "across connections", use_truncation: true do
        def in_thread(&block)
          Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
        end

        shared_examples "row-locking every current row" do
          it "row-locks every current row, the one the block hides included" do
            paused = Queue.new
            resume = Queue.new
            # Holds the operation right after it has taken its locks, at its first read
            first_read = true
            allow(employee).to receive(:find_all_current_knowledge_segments).and_wrap_original { |original, *args|
              if first_read
                first_read = false
                paused << true
                resume.pop
              end
              original.call(*args)
            }
            run_in_callers_block = callers_block
            operation = in_thread { run_in_callers_block.call(-> { employee.correct(valid_from: _05_01, name: "X") }) }
            paused.pop

            begin
              # B2: not valid now, so save!'s lock doesn't cover it
              expect {
                Employee.ignore_valid_datetime
                  .where(bitemporal_id: employee_id, name: "B2")
                  .lock("FOR UPDATE NOWAIT")
                  .to_a
              }.to raise_error(ActiveRecord::LockWaitTimeout)
            ensure
              resume << true
              operation.join
            end
          end
        end

        it_behaves_like "in or out of the caller's blocks", "row-locking every current row"
      end
    end

    describe "a default scope or a scoping block that hides rows" do
      let(:archived_at) { "2020/09/01".in_time_zone }

      #   A |02-01, 03-01) archived  B |03-01, 05-01)  C |05-01, ∞) archived   recorded on 2020-10-01
      let!(:employee_id) {
        Timecop.freeze("2020/10/01") do
          @employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A", archived_at: archived_at) }
          ActiveRecord::Bitemporal.valid_at(_03_01) { @employee.update!(name: "B", archived_at: nil) }
          ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "C", archived_at: archived_at) }
        end
        @employee.id
      }

      # The whole timeline, unchanged
      let(:recorded_timeline) {
        [[_02_01, _03_01, "A", archived_at], [_03_01, _05_01, "B", nil], [_05_01, infinity, "C", archived_at]]
      }

      shared_examples "with a default scope or in a scoping block" do |examples|
        context "with the model's default scope" do
          let(:unarchived_employee_class) {
            Class.new(Employee) {
              def self.name; "UnarchivedEmployee"; end
              default_scope { where(archived_at: nil) }
            }
          }
          # Loaded through that scope, before the operation
          let!(:employee) { unarchived_employee_class.find_at_time(_03_01, employee_id) }

          include_examples examples
        end

        context "in a scoping block" do
          let!(:employee) { Employee.find_at_time(_03_01, employee_id) }
          let(:callers_block) { ->(operation) { Employee.where(archived_at: nil).scoping { operation.call } } }

          include_examples examples
        end
      end

      describe "#correct" do
        subject(:correct) {
          Timecop.freeze("2020/10/05") {
            in_callers_block { employee.correct(valid_from: _02_01, valid_to: _06_01, name: "X") }
          }
        }

        shared_examples "patching the hidden rows too" do
          it "patches every current segment in the range, the hidden ones included" do
            correct

            expect(timeline(employee_id, :archived_at)).to eq [
              [_02_01, _03_01, "X", archived_at],
              [_03_01, _05_01, "X", nil],
              [_05_01, _06_01, "X", archived_at],
              [_06_01, infinity, "C", archived_at],
            ]
          end
        end

        it_behaves_like "with a default scope or in a scoping block", "patching the hidden rows too"
      end

      describe "#terminate" do
        subject(:terminate) {
          Timecop.freeze("2020/10/05") { in_callers_block { employee.terminate(termination_time: _04_01) } }
        }

        shared_examples "closing the hidden rows too" do
          it "ends the whole current timeline there" do
            terminate

            expect(timeline(employee_id, :archived_at)).to eq [[_02_01, _03_01, "A", archived_at], [_03_01, _04_01, "B", nil]]
          end
        end

        it_behaves_like "with a default scope or in a scoping block", "closing the hidden rows too"
      end

      describe "#shift_genesis" do
        subject(:shift_genesis) {
          Timecop.freeze("2020/10/05") { in_callers_block { employee.shift_genesis(new_valid_from: _04_01) } }
        }

        shared_examples "closing the hidden rows too" do
          it "starts the whole current timeline there" do
            shift_genesis

            expect(timeline(employee_id, :archived_at)).to eq [[_04_01, _05_01, "B", nil], [_05_01, infinity, "C", archived_at]]
          end
        end

        it_behaves_like "with a default scope or in a scoping block", "closing the hidden rows too"
      end

      describe "#cancel_termination" do
        subject(:cancel_termination) { Timecop.freeze("2020/10/06") { in_callers_block { employee.cancel_termination } } }

        context "after a termination" do
          before { Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).terminate(termination_time: _04_01) } }

          shared_examples "restoring the hidden rows too" do
            it "restores the whole timeline" do
              cancel_termination

              expect(timeline(employee_id, :archived_at)).to eq recorded_timeline
            end
          end

          it_behaves_like "with a default scope or in a scoping block", "restoring the hidden rows too"
        end

        context "when a hidden row was re-recorded since the termination" do
          before do
            Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).terminate(termination_time: _06_01) }
            Timecop.freeze("2020/10/05") do
              c = Employee.find_at_time(_05_01, employee_id)
              c.force_update { c.update!(name: "C2") }
            end
          end

          shared_examples "refusing" do
            it "refuses and keeps the re-recorded row" do
              expect { cancel_termination }.to raise_error(ActiveRecord::Bitemporal::RecordedSinceTerminationError)
              expect(timeline(employee_id, :archived_at)).to eq [
                [_02_01, _03_01, "A", archived_at],
                [_03_01, _05_01, "B", nil],
                [_05_01, _06_01, "C2", archived_at],
              ]
            end
          end

          it_behaves_like "with a default scope or in a scoping block", "refusing"
        end
      end

      describe "#cancel_shift_genesis" do
        subject(:cancel_shift_genesis) { Timecop.freeze("2020/10/05") { in_callers_block { employee.cancel_shift_genesis } } }

        # Moves the genesis off the hidden row A
        before { Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).shift_genesis(new_valid_from: _03_01) } }

        shared_examples "restoring the hidden genesis" do
          it "restores the whole timeline" do
            cancel_shift_genesis

            expect(timeline(employee_id, :archived_at)).to eq recorded_timeline
          end
        end

        it_behaves_like "with a default scope or in a scoping block", "restoring the hidden genesis"
      end

      describe "#reopen" do
        subject(:reopen) { Timecop.freeze("2020/10/06") { in_callers_block { employee.reopen } } }

        # Ends the timeline in the hidden row C
        context "after a termination" do
          before { Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).terminate(termination_time: _06_01) } }

          shared_examples "continuing the hidden row" do
            it "continues the whole timeline's last segment" do
              reopen

              expect(timeline(employee_id, :archived_at)).to eq recorded_timeline
            end
          end

          it_behaves_like "with a default scope or in a scoping block", "continuing the hidden row"
        end

        context "when a hidden row was re-recorded since the termination" do
          before do
            Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).terminate(termination_time: _06_01) }
            Timecop.freeze("2020/10/05") do
              c = Employee.find_at_time(_05_01, employee_id)
              c.force_update { c.update!(name: "C2") }
            end
          end

          shared_examples "continuing the re-recorded row" do
            it "continues the re-recorded row" do
              reopen

              expect(timeline(employee_id, :archived_at)).to eq [
                [_02_01, _03_01, "A", archived_at],
                [_03_01, _05_01, "B", nil],
                [_05_01, infinity, "C2", archived_at],
              ]
            end
          end

          it_behaves_like "with a default scope or in a scoping block", "continuing the re-recorded row"
        end
      end

      describe "#terminated?" do
        subject(:terminated) { in_callers_block { employee.terminated? } }

        shared_examples "not terminated" do
          it { is_expected.to be false }
        end

        it_behaves_like "with a default scope or in a scoping block", "not terminated"
      end

      describe "#shifted_genesis?" do
        subject(:shifted_genesis) { in_callers_block { employee.shifted_genesis? } }

        # Moves the genesis off the hidden row A
        before { Timecop.freeze("2020/10/04") { Employee.find_at_time(_03_01, employee_id).shift_genesis(new_valid_from: _03_01) } }

        shared_examples "shifted" do
          it { is_expected.to be true }
        end

        it_behaves_like "with a default scope or in a scoping block", "shifted"
      end
    end
  end

  # A host whose clock runs ahead of this one records rows later than this host's now, and
  # closing such a row at now would end it before it starts in transaction time
  describe "a current row recorded after the operation's time" do
    let(:_02_01) { "2020/02/01".in_time_zone }
    let(:_05_01) { "2020/05/01".in_time_zone }
    let(:_06_01) { "2020/06/01".in_time_zone }
    let(:infinity) { ActiveRecord::Bitemporal::DEFAULT_VALID_TO }
    # This host's time when it runs the operation
    let(:now) { "2020/10/05 12:00:00".in_time_zone }
    # The other host's at that moment
    let(:ahead) { now + 5.seconds }

    #   A |02-01, 05-01)  B |05-01, ∞)   recorded on 2020-10-01
    let!(:employee_id) {
      Timecop.freeze("2020/10/01") do
        @employee = ActiveRecord::Bitemporal.valid_at(_02_01) { Employee.create!(name: "A") }
        ActiveRecord::Bitemporal.valid_at(_05_01) { @employee.update!(name: "B") }
      end
      @employee.id
    }
    # Loaded before the other host writes
    let!(:employee) { Employee.find_at_time(_05_01, employee_id) }

    # Every row of the entity, as stored
    def history
      all_rows(Employee, employee_id).order(:transaction_from, :valid_from).map(&:attributes)
    end

    # The row the other host recorded
    let(:later_row_id) { Employee.ignore_valid_datetime.find_by!(bitemporal_id: employee_id, transaction_from: ahead).swapped_id }
    let(:message) {
      "Employee with bitemporal_id=#{employee_id} has a current row (id=#{later_row_id}) " \
        "with transaction_from 2020-10-05T12:00:05.000000Z, 5.0 seconds after this operation's " \
        "time 2020-10-05T12:00:00.000000Z. Closing it would set its transaction_to before its " \
        "transaction_from; the host that recorded it may have a clock running ahead"
    }

    context "when a host whose clock runs ahead re-recorded B" do
      before do
        Timecop.freeze(ahead) do
          b = Employee.find_at_time(_05_01, employee_id)
          b.force_update { b.update!(name: "B2") }
        end
      end

      {
        "correct" => ->(e) { e.correct(valid_from: "2020/06/01".in_time_zone, name: "X") },
        "terminate" => ->(e) { e.terminate(termination_time: "2020/06/01".in_time_zone) },
        "shift_genesis" => ->(e) { e.shift_genesis(new_valid_from: "2020/03/01".in_time_zone) },
      }.each do |name, operation|
        it "#{name} raises before it writes" do
          recorded = history
          before_operation = employee.attributes

          expect {
            Timecop.freeze(now) { operation.call(employee) }
          }.to raise_error(ActiveRecord::Bitemporal::TransactionTimeSkewError, message)
          expect(history).to eq recorded
          expect(employee.attributes).to eq before_operation
        end
      end

      context "once this host's clock has passed that row's time" do
        it "builds on it" do
          Timecop.freeze(ahead + 1.second) { employee.correct(valid_from: _06_01, name: "X") }

          expect(rows(employee)).to match [
            [_02_01, _05_01, "A", Integer],
            [_05_01, _06_01, "B2", Integer],
            [_06_01, infinity, "X", Integer],
          ]
        end
      end
    end

    context "when a host whose clock runs ahead recorded the operation a cancel undoes or reopen lifts" do
      {
        "cancel_termination" => [->(e) { e.terminate(termination_time: "2020/06/01".in_time_zone) }, :cancel_termination.to_proc],
        "cancel_shift_genesis" => [->(e) { e.shift_genesis(new_valid_from: "2020/03/01".in_time_zone) }, :cancel_shift_genesis.to_proc],
        "reopen" => [->(e) { e.terminate(termination_time: "2020/06/01".in_time_zone) }, :reopen.to_proc],
      }.each do |name, (undone, operation)|
        it "#{name} raises before it writes" do
          Timecop.freeze(ahead) { undone.call(Employee.find_at_time(_05_01, employee_id)) }
          recorded = history
          before_operation = employee.attributes

          expect {
            Timecop.freeze(now) { operation.call(employee) }
          }.to raise_error(ActiveRecord::Bitemporal::TransactionTimeSkewError, message)
          expect(history).to eq recorded
          expect(employee.attributes).to eq before_operation
        end
      end
    end

    context "when another host re-recorded B at the operation's own time" do
      before do
        Timecop.freeze(now) do
          b = Employee.find_at_time(_05_01, employee_id)
          b.force_update { b.update!(name: "B2") }
        end
      end

      it "builds on it" do
        Timecop.freeze(now) { employee.correct(valid_from: _06_01, name: "X") }

        expect(rows(employee)).to match [
          [_02_01, _05_01, "A", Integer],
          [_05_01, _06_01, "B2", Integer],
          [_06_01, infinity, "X", Integer],
        ]
      end

      context "at a time with a fraction of a microsecond, which the column cuts off" do
        let(:now) { "2020/10/05 12:00:00.1234567".in_time_zone }

        it "builds on it" do
          Timecop.freeze(now) { employee.correct(valid_from: _06_01, name: "X") }

          expect(rows(employee)).to match [
            [_02_01, _05_01, "A", Integer],
            [_05_01, _06_01, "B2", Integer],
            [_06_01, infinity, "X", Integer],
          ]
        end
      end
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
        "reopen" => [->(e) { e.terminate(termination_time: "2020/03/01".in_time_zone) }, :reopen.to_proc],
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
