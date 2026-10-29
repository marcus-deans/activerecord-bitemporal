# frozen_string_literal: true

# Entry point for everything this fork adds on top of upstream kufu/activerecord-bitemporal.
#
# Upstream's files stay byte-identical so upstream syncs stay conflict-free; the fork's only
# footprint in them is the `require "activerecord-bitemporal/fork"` at the end of
# lib/activerecord-bitemporal.rb.
#
# Error classes are defined at require time, like upstream's errors.rb. The timeline
# operations need upstream's Persistence module, so they load in an on_load hook. This
# file is required after upstream registers its own hook, so ours runs after it.
module ActiveRecord
  module Bitemporal
    class PreTerminationStateNotFoundError < BitemporalError; end

    class PreShiftGenesisStateNotFoundError < BitemporalError; end

    # A cancel refuses when changes were recorded after the operation it undoes. These
    # subclass the not-found errors, so a rescue of those catches the refusal too.
    class RecordedSinceTerminationError < PreTerminationStateNotFoundError; end

    class RecordedSinceGenesisShiftError < PreShiftGenesisStateNotFoundError; end

    # A timeline operation refuses when a current row was recorded after its own current
    # time, as a host whose clock runs ahead records one: closing that row would set its
    # transaction_to before its transaction_from.
    class TransactionTimeSkewError < BitemporalError; end
  end
end

ActiveSupport.on_load(:active_record) do
  require "activerecord-bitemporal/timeline_operations"
end
