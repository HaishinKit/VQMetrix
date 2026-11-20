#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.fetch(0))
%w[en ja].each do |language|
  prefix = language == 'en' ? 'swift' : 'ja/swift'
  destination = File.join(output, prefix)
  FileUtils.mkdir_p(destination)
  catalog = File.join(root, 'Documentation', language + '.lproj', 'VQMetrix.docc')
  command = ['xcrun', 'docc', 'convert', catalog, '--fallback-display-name', 'VQMetrix',
             '--fallback-bundle-identifier', 'com.haishinkit.VQMetrix.documentation',
             '--transform-for-static-hosting', '--hosting-base-path', 'VQMetrix/' + prefix,
             '--output-dir', destination, '--warnings-as-errors']
  text, status = Open3.capture2e(*command)
  abort text unless status.success?
  puts "Built #{language} DocC guide"
end
