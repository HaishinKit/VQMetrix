#!/usr/bin/env ruby
require 'cgi'
require 'fileutils'
output = File.expand_path(ARGV.fetch(0))
version = CGI.escapeHTML(ARGV.fetch(1))
FileUtils.cp(File.join(__dir__, 'serve_documentation.rb'), File.join(output, 'serve.rb'))
File.write(File.join(output, 'README.txt'), "Run: ruby serve.rb\nOpen: http://127.0.0.1:8788/VQMetrix/\nNo network connection is needed after extraction.\n")
%w[swift/index.html android/index.html].each { |path| abort "Missing #{path}" unless File.file?(File.join(output,path)) }
File.write(File.join(output, 'index.html'), <<~HTML)
  <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VQMetrix #{version} documentation</title><style>body{font:17px/1.7 system-ui;max-width:800px;margin:64px auto;padding:24px;color:#172033}a{color:#0077bb}li{margin:12px 0}small{color:#526078}</style>
  <h1>VQMetrix</h1><p>Video quality development tools for HaishinKit. Documentation for #{version}.</p>
  <ul><li><a href="swift/documentation/vqmetrixcore/">macOS guide and Swift reference</a></li><li><a href="android/index.html">Android producer guide and Kotlin reference</a></li></ul>
  <p><a href="https://github.com/HaishinKit/VQMetrix/releases">Download development apps</a> · <a href="https://github.com/HaishinKit/VQMetrix">Source and transfer specification</a></p>
  <p><small>Built on <a href="https://haishinkit.com">HaishinKit</a>. Android creates reference/encoded material; macOS evaluates quality. The network receiver remains a separate integration.</small></p></html>
HTML
