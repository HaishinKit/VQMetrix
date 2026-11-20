#!/usr/bin/env ruby
require 'digest'
require 'open3'
root = File.expand_path(ENV.fetch('RELEASE_DIRECTORY'))
tag = ENV.fetch('RELEASE_TAG')
abort 'Invalid release tag' unless tag.match?(/\Av?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z/)
repository = ENV.fetch('GITHUB_REPOSITORY')
macos = Dir[File.join(root, 'VQMetrix-macos-*.zip')]
abort 'Expected exactly one macOS archive' unless macos.length == 1
assets = macos + %w[HaishinKit-Example-debug.apk api-documentation.tar.gz].map { |name| File.join(root,name) }
assets.each { |path| abort "Missing release asset #{File.basename(path)}" unless File.file?(path) }
checksums = File.join(root, 'SHA256SUMS.txt')
File.write(checksums, assets.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{File.basename(path)}" }.join("\n")+"\n")
_,status = Open3.capture2e('gh','release','view',tag,'--repo',repository)
unless status.success?
  command = ['gh','release','create',tag,'--repo',repository,'--verify-tag','--title',"VQMetrix #{tag}",'--generate-notes']
  command << '--prerelease' if tag.include?('-')
  output,status = Open3.capture2e(*command)
  abort output unless status.success?
end
output,status = Open3.capture2e('gh','release','upload',tag,*assets,checksums,'--repo',repository,'--clobber')
abort output unless status.success?
puts "Attached #{assets.length + 1} release assets to #{tag}"
