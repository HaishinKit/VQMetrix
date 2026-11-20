#!/usr/bin/env ruby
require 'json'
root = File.expand_path('..', __dir__)
deps = JSON.parse(File.read(File.join(root, 'Support/dependencies.json')))
values = deps.to_h do |kind, dependency|
  revision = dependency.fetch('revision')
  abort 'Invalid dependency revision' unless revision.match?(/\A[0-9a-f]{40}\z/)
  ["#{kind}_revision", revision]
end
version = (ENV['RELEASE_TAG'].to_s.empty? ? File.read(File.join(root, 'VERSION')).strip : ENV.fetch('RELEASE_TAG')).sub(/\Av/, '')
abort 'Use a semantic version tag, such as 1.0.0' unless version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z/)
values['version'] = version
if ENV['GITHUB_OUTPUT']
  File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |file| values.each { |key,value| file.puts "#{key}=#{value}" } }
else
  puts JSON.pretty_generate(values)
end
