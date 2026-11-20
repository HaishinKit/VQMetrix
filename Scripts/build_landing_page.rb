#!/usr/bin/env ruby
require 'erb'
require 'cgi'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.fetch(0))
version = CGI.escapeHTML(ARGV.fetch(1, File.read(File.join(root, 'VERSION')).strip))
assets = File.join(output, 'assets')
FileUtils.mkdir_p(assets)
FileUtils.cp(File.join(root, 'docs/site/site.css'), File.join(assets, 'site.css'))
FileUtils.cp(File.join(root, 'Assets/AppIcon.png'), File.join(assets, 'app-icon.png'))
%w[macos-measurement.png macos-receiver.png macos-bitrate-search.png].each do |name|
  FileUtils.cp(File.join(root, 'Assets/Screenshots', name), File.join(assets, name))
end
# PNG dimensions reserve the screenshot's natural layout before it loads.
dimensions = ->(name) { File.binread(File.join(assets, name), 24).byteslice(16, 8).unpack('NN') }
screenshot_width, screenshot_height = dimensions.call('macos-measurement.png')
receiver_width, receiver_height = dimensions.call('macos-receiver.png')
search_width, search_height = dimensions.call('macos-bitrate-search.png')
template = ERB.new(File.read(File.join(root, 'docs/site/index.html.erb')))
%w[en ja].each do |lang|
  t = ->(en, ja) { lang == 'ja' ? ja : en }
  home = lang == 'ja' ? '/VQMetrix/ja/' : '/VQMetrix/'
  documentation_base = lang == 'ja' ? '/VQMetrix/ja/swift/documentation/vqmetrix' : '/VQMetrix/swift/documentation/vqmetrix'
  guide = documentation_base + '/understandingvmaf/'
  destination = lang == 'ja' ? File.join(output, 'ja') : output
  FileUtils.mkdir_p(destination)
  File.write(File.join(destination, 'index.html'), template.result(binding))
end
File.write(File.join(output, '.nojekyll'), '')
puts "Built English and Japanese landing pages in #{output}"
