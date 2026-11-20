#!/usr/bin/env ruby
require 'cgi'
require 'fileutils'
output = File.expand_path(ARGV.fetch(0))
version = CGI.escapeHTML(ARGV.fetch(1))
FileUtils.cp(File.join(__dir__, 'serve_documentation.rb'), File.join(output, 'serve.rb'))
File.write(File.join(output, 'README.txt'), "Run: ruby serve.rb\nOpen: http://127.0.0.1:8788/VQMetrix/\nNo network connection is needed after extraction.\n")
%w[swift/index.html android/index.html].each { |path| abort "Missing #{path}" unless File.file?(File.join(output,path)) }
# Keep help links from the released 1.0.x split-module apps usable.
canonical = File.join(output, 'swift/documentation/vqmetrix')
if File.directory?(canonical)
  Dir[File.join(canonical, '**/index.html')].each do |page|
    suffix = page.delete_prefix(canonical).delete_suffix('index.html')
    destination = File.join(output, 'swift/documentation/vqmetrixcore', suffix, 'index.html')
    FileUtils.mkdir_p(File.dirname(destination))
    url = '/VQMetrix/swift/documentation/vqmetrix' + suffix
    File.write(destination, "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=#{url}\"><title>VQMetrix documentation</title><a href=\"#{url}\">Continue to VQMetrix documentation</a>")
  end
end
# Historic Japanese article URLs now lead to the Japanese catalog's same-name article.
if File.file?(File.join(output, 'ja/swift/documentation/vqmetrix/understandingvmaf/index.html'))
  %w[vqmetrixcore vqmetrix].each do |name|
    destination = File.join(output, 'swift/documentation', name, 'understandingvmaf-japanese/index.html')
    FileUtils.mkdir_p(File.dirname(destination))
    url = '/VQMetrix/ja/swift/documentation/vqmetrix/understandingvmaf/'
    File.write(destination, "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=#{url}\"><title>VQMetrix</title><a href=\"#{url}\">日本語ガイド</a>")
  end
end
abort 'Landing page generation failed' unless system(RbConfig.ruby, File.join(__dir__, 'build_landing_page.rb'), output, ARGV.fetch(1))
