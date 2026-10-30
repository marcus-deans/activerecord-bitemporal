# frozen_string_literal: true

require 'spec_helper'
require 'digest'

# Fingerprints of upstream code the fork copies instead of calling, so a sync with upstream
# that changes it fails here instead of leaving the copies behind. Upstream behaviour the fork
# relies on through calls is pinned by the fork's behavioural specs instead (save!'s row lock,
# for one, in timeline_operations_spec.rb).
module ForkUpstreamSentinel
  BITEMPORAL_RB = File.expand_path("../../lib/activerecord-bitemporal/bitemporal.rb", __dir__)

  # SHA256 of upstream's refinements block in bitemporal.rb, normalized (see .normalize)
  REFINEMENTS_DIGEST = "4fec6b6bed239b07888488c91ad3a3353dcc7fecc08c402f262c83bd5da07dae"

  module_function

  # The block from `using Module.new {`, followed by `refine Persistence do`, to the `}` that
  # closes it at the same indentation. nil when those anchors aren't there.
  def refinements_block(source)
    lines = source.lines
    start = lines.each_index.find { |index|
      lines[index].strip == "using Module.new {" &&
        lines[(index + 1)..].find { |line| !line.strip.empty? }&.strip == "refine Persistence do"
    }
    return nil unless start

    closing = "#{lines[start][/\A\s*/]}}"
    finish = ((start + 1)...lines.size).find { |index| lines[index].chomp == closing }
    finish && lines[start..finish].join
  end

  # Code only: indentation, blank lines and full-line comments don't count
  def normalize(text)
    text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.join("\n")
  end

  def digest(text)
    Digest::SHA256.hexdigest(normalize(text))
  end
end

RSpec.describe "Upstream code the fork mirrors" do
  # TimelineOperations is in another file, so it can't use these refinements. It carries
  # copies of the two it needs.
  describe "upstream's refinements block in bitemporal.rb" do
    let(:block) { ForkUpstreamSentinel.refinements_block(File.read(ForkUpstreamSentinel::BITEMPORAL_RB)) }

    it "is still there, with the two methods the fork mirrors" do
      expect(block).not_to be_nil, <<~MESSAGE
        Can't find upstream's refinements block (`using Module.new {` followed by `refine Persistence do`)
        in #{ForkUpstreamSentinel::BITEMPORAL_RB}. Find where upstream moved the refined
        ActiveRecord::Base#dup and Persistence#update_transaction_to, review them against
        TimelineOperations#timeline_dup and #timeline_close in
        lib/activerecord-bitemporal/timeline_operations.rb, and point this sentinel at them.
      MESSAGE
      expect(block).to include("refine ActiveRecord::Base do", "def dup(*)", "def update_transaction_to(value)")
    end

    it "is unchanged since the fork last mirrored it" do
      actual = ForkUpstreamSentinel.digest(block.to_s)

      expect(actual).to eq(ForkUpstreamSentinel::REFINEMENTS_DIGEST), <<~MESSAGE
        Upstream's refinements block in lib/activerecord-bitemporal/bitemporal.rb changed.
        The fork mirrors two of its methods in lib/activerecord-bitemporal/timeline_operations.rb:
          TimelineOperations#timeline_dup   mirrors the refined ActiveRecord::Base#dup
          TimelineOperations#timeline_close mirrors the refined Persistence#update_transaction_to
        Review the change:
          git diff <upstream commit last synced> upstream/master -- lib/activerecord-bitemporal/bitemporal.rb
        mirror what applies into those methods and their examples in spec/fork/timeline_operations_spec.rb,
        then record the new digest in spec/fork/upstream_sentinel_spec.rb:
          REFINEMENTS_DIGEST = "#{actual}"
      MESSAGE
    end
  end
end
