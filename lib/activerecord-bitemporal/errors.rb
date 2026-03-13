# frozen_string_literal: true

module ActiveRecord::Bitemporal
  class BitemporalError < StandardError; end

  class ValidDatetimeRangeError < BitemporalError; end

  class PreTerminationStateNotFoundError < BitemporalError; end

  class PreShiftGenesisStateNotFoundError < BitemporalError; end
end
