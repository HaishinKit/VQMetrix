#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'localize_documentation_site'
root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.fetch(0))
source = File.join(root, 'Documentation/VQMetrix.docc')
# Current DocC treats localized Markdown as duplicate articles. Stage each language
# separately while keeping the source catalog's Localization/ja.lproj layout.
%w[en ja].each do |language|
  prefix = language == 'en' ? 'swift' : 'ja/swift'
  destination = File.join(output, prefix)
  FileUtils.mkdir_p(destination)
  Dir.mktmpdir('vqmetrix-docc-') do |temporary|
    catalog = File.join(temporary, 'VQMetrix.docc')
    FileUtils.mkdir_p(catalog)
    Dir.children(source).reject { |name| name == 'Localization' }.each do |name|
      FileUtils.cp_r(File.join(source, name), catalog)
    end
    if language == 'ja'
      Dir.children(File.join(source, 'Localization/ja.lproj')).each do |name|
        FileUtils.cp_r(File.join(source, 'Localization/ja.lproj', name), catalog)
      end
    end
    command = ['xcrun', 'docc', 'convert', catalog, '--fallback-display-name', 'VQMetrix',
               '--fallback-bundle-identifier', 'com.haishinkit.VQMetrix.documentation',
               '--transform-for-static-hosting', '--hosting-base-path', 'VQMetrix/' + prefix,
               '--output-dir', destination, '--warnings-as-errors']
    text, status = Open3.capture2e(*command)
    abort text unless status.success?
  end
  puts "Built #{language} DocC guide"
end

SiteLocalization.install(output)
