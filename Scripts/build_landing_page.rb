#!/usr/bin/env ruby
require 'erb'
require 'cgi'
require 'fileutils'
require_relative 'localize_documentation_site'
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
home = '/VQMetrix/'
documentation_base = '/VQMetrix/swift/documentation/vqmetrix'
guide = documentation_base + '/understandingvmaf/'
File.write(File.join(output, 'index.html'), template.result(binding))
# Preserve old landing-page links without publishing Japanese marketing copy.
FileUtils.mkdir_p(File.join(output, 'ja'))
File.write(File.join(output, 'ja/index.html'), <<~HTML)
  <!doctype html><html lang="en"><head><meta charset="utf-8">
  <meta http-equiv="refresh" content="0;url=/VQMetrix/">
  <link rel="canonical" href="https://haishinkit.github.io/VQMetrix/">
  <title>VQMetrix</title><script>location.replace('/VQMetrix/' + location.search + location.hash)</script>
  </head><body><a href="/VQMetrix/">Continue to VQMetrix</a></body></html>
HTML
SiteLocalization.install(output)
File.write(File.join(output, '.nojekyll'), '')
puts "Built English landing page in #{output}"
