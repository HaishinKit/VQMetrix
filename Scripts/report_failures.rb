#!/usr/bin/env ruby
require 'json'
JSON.parse(ENV.fetch('STEPS_JSON', '{}')).each do |name, step|
  next unless step['outcome'] == 'failure'
  escaped = name.gsub('%', '%25').gsub("\r", '%0D').gsub("\n", '%0A').gsub(',', '%2C').gsub(':', '%3A')
  puts "::error title=Failed step: #{escaped}::The #{escaped} step failed. Open its logs for details."
end
