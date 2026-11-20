#!/usr/bin/env ruby
require 'json'
require 'open3'
ROOT = File.expand_path('..', __dir__)
versions = JSON.parse(File.read(File.join(ROOT, 'Support/dependencies.json')))
requested = ARGV.empty? ? %w[swift android] : ARGV
abort 'Use swift and/or android' unless (requested - %w[swift android]).empty?
requested.each do |kind|
  name = kind == 'swift' ? 'HaishinKit.swift' : 'HaishinKit.kt'
  directory = File.expand_path("../#{name}", ROOT)
  abort "Missing #{directory}; check out #{versions.fetch(kind).fetch('repository')} at #{versions.fetch(kind).fetch('revision')}" unless File.directory?(directory)
  marker = kind == 'swift' ? 'HaishinKit/Sources/Codec/VideoCodecProbe.swift' : 'app/vqmetrix/src/main/java/com/haishinkit/app/vqmetrix/MixerCapture.kt'
  ready = File.file?(File.join(directory, marker))
  if kind == 'android' && ready
    ready = File.read(File.join(directory, 'app/vqmetrix/build.gradle.kts')).include?('com.github.HaishinKit.VQMetrix:transfer:')
  end
  next if ready
  head,status = Open3.capture2('git','rev-parse','HEAD', chdir: directory)
  abort "Wrong #{name} revision" unless status.success? && head.strip == versions.fetch(kind).fetch('revision')
  patch = File.join(ROOT, "Support/#{name}.patch")
  [['git','apply','--check',patch], ['git','apply',patch]].each do |command|
    output,status = Open3.capture2e(*command, chdir: directory)
    abort "#{name} adapter failed: #{output}" unless status.success?
  end
  puts "Prepared #{name} development adapter"
end
