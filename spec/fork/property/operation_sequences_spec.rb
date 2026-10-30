# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require_relative 'reference_model'
require_relative 'sequence_runner'

# Property-based checks of the fork's timeline operations: random sequences of fork
# operations and upstream writes over one or two entities, each step checked against
# ReferenceModel and the store's invariants (see ForkProperty::Runner).
#
# With no ENV this runs the smoke tier, a fixed budget that's part of the normal suite. ENV
# knobs select the deep tier, rerun one sequence or batch, or check a mutant; see
# docs/TESTING.md:
#
#   FORK_PROPERTY=deep            the deep tier (a model x zero-length x seams matrix)
#   FORK_PROPERTY_MODEL=Employee  only that model's batches; with a seed, the model to run
#   FORK_PROPERTY_SEED=1200017    one batch from this seed instead of the tier's batches
#   FORK_PROPERTY_COUNT=1         sequences in that batch (default 1); in a tier, in each batch
#   FORK_PROPERTY_STEPS=40        steps per sequence at most (default 40); in a tier, in each batch
#   FORK_PROPERTY_ZERO_LENGTH=1   with a seed: upstream destroys may leave zero-length rows
#   FORK_PROPERTY_SEAMS=1         with a seed: upstream writes lean towards leaving seams
#   FORK_PROPERTY_SHRINK=0        don't shrink failures
#   FORK_PROPERTY_OUT=dir         where reports go (default: a directory in Dir.tmpdir)
#   FORK_PROPERTY_DIVERGENCES=1   print upstream divergences
#   FORK_PROPERTY_MUTANT=no_merge check that the harness catches that mutant (see mutants.rb)

ActiveRecord::Schema.define(version: 1) do
  create_table :fork_property_custom_column_records, force: true do |t|
    t.string :name
    t.integer :code

    t.integer :bitemporal_id
    t.datetime :effective_from, precision: 6
    t.datetime :effective_to, precision: 6
    t.datetime :deleted_at, precision: 6
    t.datetime :transaction_from, precision: 6
    t.datetime :transaction_to, precision: 6

    t.timestamps
  end
end

module ForkProperty
  # Valid time under other column names, and an integer business column
  class CustomColumnRecord < ActiveRecord::Base
    self.table_name = "fork_property_custom_column_records"
    bitemporalize valid_from_key: :effective_from, valid_to_key: :effective_to
  end

  # The models sequences run on, and the values generated attributes take. Employee has a
  # datetime valid time and deleted_at, Department a date valid time and no deleted_at.
  MODELS = {
    "Employee" => [Employee, { "name" => ["a", "b", "c", nil], "emp_code" => ["x", "y"], "company_id" => [1, 2] }],
    "Department" => [Department, { "name" => ["a", "b", "c"] }],
    "CustomColumnRecord" => [CustomColumnRecord, { "name" => ["a", "b"], "code" => [1, 2] }],
  }.freeze

  # Each tier is a list of batches:
  #   [model, first seed, sequences, steps at most, zero-length rows, seams]

  # In the normal suite: about 10 seconds
  SMOKE = [
    ["Employee", 1_000, 6, 30, false, true],
    ["Employee", 2_000, 5, 30, true, true],
    ["Department", 3_000, 6, 30, false, true],
    ["CustomColumnRecord", 5_000, 5, 30, true, false],
  ].freeze

  # Every model with zero-length rows and seams off and on: 3600 sequences, about 45 minutes
  DEEP = [
    ["Employee", 1_100_000, 300, 40, false, false],
    ["Employee", 1_200_000, 300, 40, false, true],
    ["Employee", 1_300_000, 300, 40, true, false],
    ["Employee", 1_400_000, 300, 40, true, true],
    ["Department", 2_100_000, 300, 40, false, false],
    ["Department", 2_200_000, 300, 40, false, true],
    ["Department", 2_300_000, 300, 40, true, false],
    ["Department", 2_400_000, 300, 40, true, true],
    ["CustomColumnRecord", 3_100_000, 300, 40, false, false],
    ["CustomColumnRecord", 3_200_000, 300, 40, false, true],
    ["CustomColumnRecord", 3_300_000, 300, 40, true, false],
    ["CustomColumnRecord", 3_400_000, 300, 40, true, true],
  ].freeze

  module Settings
    module_function

    def env(name, default = nil)
      value = ENV["FORK_PROPERTY_#{name}"]
      value.nil? || value.empty? ? default : value
    end

    def flag(name)
      env(name, "0") == "1"
    end

    def tier
      ENV["FORK_PROPERTY"].to_s.empty? ? "smoke" : ENV["FORK_PROPERTY"]
    end

    def batches
      model_name = env("MODEL")
      if model_name && !MODELS.key?(model_name)
        raise ArgumentError, "FORK_PROPERTY_MODEL is one of #{MODELS.keys.join(', ')}, not #{model_name.inspect}"
      end

      configs =
        if (seed = env("SEED"))
          [[model_name || "Employee", Integer(seed), Integer(env("COUNT", "1")), Integer(env("STEPS", "40")), flag("ZERO_LENGTH"), flag("SEAMS")]]
        else
          { "smoke" => SMOKE, "deep" => DEEP }
            .fetch(tier) { raise ArgumentError, "FORK_PROPERTY is smoke or deep, not #{tier.inspect}" }
            .select { |name, *| model_name.nil? || name == model_name }
            .map { |name, first_seed, count, max_steps, *rest| [name, first_seed, Integer(env("COUNT", count)), Integer(env("STEPS", max_steps)), *rest] }
        end
      configs.map { |name, first_seed, count, max_steps, zero_length, seams|
        model, values = MODELS.fetch(name)
        Batch.new(
          name: name, model: model, values: values, first_seed: first_seed, count: count, max_steps: max_steps,
          zero_length: zero_length, seams: seams
        )
      }
    end

    # The smoke tier stays quiet and stops at its first failure; anything else reports
    def quiet?
      tier == "smoke" && env("SEED").nil?
    end

    def out_dir
      env("OUT", File.join(Dir.tmpdir, "activerecord-bitemporal-fork-property"))
    end
  end
end

if (mutant = ForkProperty::Settings.env("MUTANT"))
  require_relative 'mutants'
  ForkProperty::Mutants.install(mutant)
end

RSpec.describe "Fork timeline operations over random sequences" do
  settings = ForkProperty::Settings
  batches = settings.batches

  def message(text)
    RSpec.configuration.reporter.message(text)
  end

  if mutant
    around { |example| ForkProperty::Mutants.enabled { example.run } }

    it "catches the #{mutant} mutant" do
      sequences = 0
      caught = batches.lazy.filter_map { |batch|
        result = batch.run(shrink: false, stop_on_failure: true)
        sequences += result.sequences
        [batch, result.failures.first] if result.failures.any?
      }.first
      expect(caught).not_to be_nil, "the #{mutant} mutant survived #{sequences} sequences in #{batches.size} batches"

      batch, failure_case = caught
      message("#{mutant}: caught by #{failure_case.failure.signature} after #{sequences} sequences " \
              "(#{batch.name}, seed #{failure_case.seed})")
    end
  else
    batches.each do |batch|
      it batch.description do
        result = batch.run(shrink: settings.env("SHRINK", "1") == "1", stop_on_failure: settings.quiet?)
        unless settings.quiet?
          FileUtils.mkdir_p(settings.out_dir)
          path = File.join(settings.out_dir, "#{batch.name}-#{batch.first_seed}.txt")
          File.write(path, batch.report(result))
          message("#{batch.description}: #{result.steps} steps, #{result.failures.size} failure signatures, " \
                  "#{result.divergences.size} upstream divergences, #{result.seconds.round(1)}s -> #{path}")
        end
        message(result.divergences.join("\n")) if settings.flag("DIVERGENCES") && result.divergences.any?

        expect(result.failures).to be_empty, -> {
          result.failures.map { |failure_case| batch.failure_report(failure_case) }.join("\n")
        }
      end
    end
  end
end
