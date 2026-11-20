#!/usr/bin/env ruby
require 'cgi'
require 'fileutils'
output = File.expand_path(ARGV.fetch(0))
version = CGI.escapeHTML(ARGV.fetch(1))
FileUtils.cp(File.join(__dir__, 'serve_documentation.rb'), File.join(output, 'serve.rb'))
File.write(File.join(output, 'README.txt'), "Run: ruby serve.rb\nOpen: http://127.0.0.1:8788/VQMetrix/\nNo network connection is needed after extraction.\n")
%w[swift/index.html android/index.html].each { |path| abort "Missing #{path}" unless File.file?(File.join(output,path)) }
abort 'Landing page generation failed' unless system(RbConfig.ruby, File.join(__dir__, 'build_landing_page.rb'), output, ARGV.fetch(1))
