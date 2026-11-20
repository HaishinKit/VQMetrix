#!/usr/bin/env ruby
require 'fileutils'
require 'json'
require 'open3'
require 'rexml/document'
require 'tmpdir'

root = File.expand_path('..', __dir__)
tag = ENV.fetch('RELEASE_TAG')
abort 'Only stable numeric release tags can be advertised' unless tag.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)
archives = Dir[File.join(root, '.build/VQMetrix-macos-*.zip')]
abort 'Expected exactly one macOS update archive' unless archives.length == 1
config = JSON.parse(File.read(File.join(root, 'Support/updates.json')))
tools = File.join(root, '.build/artifacts/sparkle/Sparkle/bin')
secret = ENV.delete('SPARKLE_PRIVATE_KEY')
abort 'Missing update signing key in CI' if ENV['CI'] && (secret.nil? || secret.empty?)
key_arguments = secret ? ['--ed-key-file', '-'] : ['--account', config.fetch('keychain_account')]
run = lambda do |command, private_input = false|
  output, status = Open3.capture2e(*command, stdin_data: private_input && secret ? secret + "\n" : '')
  abort "#{File.basename(command.first)} failed:\n#{output}" unless status.success?
  output
end
Dir.mktmpdir('vqmetrix-appcast') do |directory|
  archive = File.join(directory, File.basename(archives.first))
  FileUtils.cp(archives.first, archive)
  prefix = "https://github.com/HaishinKit/VQMetrix/releases/download/#{tag}/"
  run.call([File.join(tools, 'generate_appcast'), *key_arguments, '--download-url-prefix', prefix,
            '--link', 'https://haishinkit.github.io/VQMetrix/', '--maximum-deltas', '0', directory], true)
  feed = File.join(directory, 'appcast.xml')
  document = REXML::Document.new(File.read(feed))
  item = REXML::XPath.first(document, '/rss/channel/item')
  enclosure = item&.elements&.[]('enclosure')
  abort 'Unexpected appcast version' unless item&.elements&.[]('sparkle:version')&.text == tag
  abort 'Unexpected update URL' unless enclosure&.attributes&.[]('url') == prefix + File.basename(archive)
  abort 'Unexpected update length' unless enclosure.attributes['length'].to_i == File.size(archive)
  signature = enclosure.attributes['sparkle:edSignature']
  abort 'Missing archive signature' unless signature
  run.call(['swift', File.join(root, 'Scripts/verify_update.swift'), archive, config.fetch('public_ed_key'), signature])
  run.call([File.join(tools, 'sign_update'), *key_arguments, '--verify', feed], true)
  FileUtils.cp(feed, File.join(root, '.build/appcast.xml'))
end
puts 'Generated and verified signed appcast.xml'
