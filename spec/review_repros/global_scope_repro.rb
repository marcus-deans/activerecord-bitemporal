# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Fork review: global bitemporal scope leaks into correct()" do
  let(:tt_inf) { ActiveRecord::Bitemporal::DEFAULT_TRANSACTION_TO }
  def tl(id)
    Employee.ignore_valid_datetime.where(bitemporal_id: id).where(transaction_to: tt_inf).order(:valid_from).pluck(:valid_from, :valid_to, :name)
      .map { |a, b, n| "#{a.to_date}..#{b.year == 9999 ? 'inf' : b.to_date} #{n}" }.join(' | ')
  end

  it "correct inside transaction_at(past) builds from a partial view" do
    e = nil
    Timecop.freeze("2020/10/01") { e = ActiveRecord::Bitemporal.valid_at("2020/01/01") { Employee.create!(name: "A") } }
    Timecop.freeze("2020/10/05") { ActiveRecord::Bitemporal.valid_at("2020/03/01") { Employee.find(e.id).update!(name: "B") } }
    puts "\n[tx_at] before: #{tl(e.id)}"
    err = nil
    Timecop.freeze("2020/10/10") do
      ActiveRecord::Bitemporal.transaction_at("2020/10/02".in_time_zone) do
        rec = Employee.find(e.id)
        begin
          rec.correct(valid_from: "2020/02/01".in_time_zone, name: "X")
        rescue => ex
          err = ex
        end
      end
    end
    puts "[tx_at] error=#{err&.class} #{err&.message}"
    puts "[tx_at] after:  #{tl(e.id)}"
  end

  it "correct inside valid_at(x) global block" do
    e = nil
    Timecop.freeze("2020/10/01") do
      e = ActiveRecord::Bitemporal.valid_at("2020/01/01") { Employee.create!(name: "A") }
      ActiveRecord::Bitemporal.valid_at("2020/03/01") { Employee.find(e.id).update!(name: "B") }
    end
    Timecop.freeze("2020/10/10") do
      ActiveRecord::Bitemporal.valid_at("2020/03/15") { Employee.find(e.id).correct(valid_from: "2020/02/01".in_time_zone, valid_to: "2020/04/01".in_time_zone, name: "X") }
    end
    puts "\n[valid_at] after: #{tl(e.id)}"
  end
end
