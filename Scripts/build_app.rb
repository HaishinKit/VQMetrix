#!/usr/bin/env ruby
require 'fileutils'
require 'json'
require 'open3'

ROOT = File.expand_path('..', __dir__)

def capture(*command)
  output, status = Open3.capture2e(*command, chdir: ROOT)
  abort "#{command.first} failed:\n#{output}" unless status.success?
  output.strip
end

def dependencies(binary)
  capture('otool', '-L', binary).lines.drop(1)
    .select { |line| line.include?(' (compatibility version') }
    .map { |line| line.strip.split(' (compatibility version').first }
end

def system_library?(path)
  path.start_with?('/usr/lib/', '/System/Library/')
end

version = ENV.fetch('VQMETRIX_VERSION', File.read(File.join(ROOT, 'VERSION')).strip)
abort 'Invalid app version' unless version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z/)
short_version = version.split('-').first
puts capture('swift', 'build', '-c', 'release')
bin = capture('swift', 'build', '-c', 'release', '--show-bin-path').lines.last.strip
gui = File.join(bin, 'VQMetrixApp')
vmaf = dependencies(gui).find { |path| File.basename(path).match?(/\Alibvmaf\..*dylib\z/) }
abort 'Missing libvmaf' unless vmaf && File.file?(vmaf)
extra = dependencies(gui).reject { |path| system_library?(path) || path == vmaf }
extra += dependencies(vmaf).reject { |path| system_library?(path) || File.basename(path) == File.basename(vmaf) }
abort "Additional dependencies need bundling and license handling: #{extra.join(', ')}" unless extra.empty?
vmaf_real = File.realpath(vmaf)
vmaf_license = File.join(File.expand_path('..', File.dirname(vmaf_real)), 'LICENSE')
abort 'Missing libvmaf license' unless File.file?(vmaf_license)
app = File.join(ROOT, '.build/VQMetrix.app')
FileUtils.rm_rf(app)
contents = File.join(app, 'Contents')
resources = File.join(contents, 'Resources')
frameworks = File.join(contents, 'Frameworks')
FileUtils.mkdir_p([resources, File.join(contents, 'MacOS'), frameworks, File.join(resources, 'Licenses')])
FileUtils.cp(gui, File.join(contents, 'MacOS/VQMetrix'))
resource_bundle = File.join(bin, 'VQMetrix_VQMetrixCore.bundle')
abort 'Missing localization resources' unless File.directory?(resource_bundle)
FileUtils.cp_r(resource_bundle, resources)
Dir[File.join(bin, 'ZIPFoundation*.bundle/PrivacyInfo.xcprivacy')].each { |notice| FileUtils.cp(notice, resources) }
{ 'en' => 'VQMetrix uses the camera only while measuring video quality. No audio is captured.',
  'ja' => '映像品質の計測中にカメラを使用します。音声は取得しません。' }.each do |language, message|
  folder = File.join(resources, language + '.lproj')
  FileUtils.mkdir_p(folder)
  File.write(File.join(folder, 'InfoPlist.strings'), '"NSCameraUsageDescription" = ' + JSON.generate(message) + ";\n")
end
library = File.join(frameworks, File.basename(vmaf))
FileUtils.cp(vmaf_real, library)
capture('install_name_tool', '-id', "@loader_path/#{File.basename(vmaf)}", library)
capture('install_name_tool', '-change', vmaf, "@executable_path/../Frameworks/#{File.basename(vmaf)}", File.join(contents, 'MacOS/VQMetrix'))
{
  'VQMetrix.txt' => File.join(ROOT, 'LICENSE.md'),
  'HaishinKit.txt' => File.expand_path('../HaishinKit.swift/LICENSE.md', ROOT),
  'Logboard.txt' => File.join(ROOT, '.build/checkouts/Logboard/LICENSE.md'),
  'libvmaf.txt' => vmaf_license,
  'ZIPFoundation.txt' => File.join(ROOT, '.build/checkouts/ZIPFoundation/LICENSE')
}.each { |name, source| FileUtils.cp(source, File.join(resources, 'Licenses', name)) }
iconset = File.join(ROOT, '.build/AppIcon.iconset')
FileUtils.mkdir_p(iconset)
[16, 32, 128, 256, 512].each do |size|
  ['', '@2x'].each do |scale|
    pixels = size * (scale.empty? ? 1 : 2)
    capture('sips', '-z', pixels.to_s, pixels.to_s, File.join(ROOT, 'Assets/AppIcon.png'),
      '--out', File.join(iconset, "icon_#{size}x#{size}#{scale}.png"))
  end
end
capture('iconutil', '-c', 'icns', iconset, '-o', File.join(resources, 'AppIcon.icns'))
minimum = [gui, vmaf_real].map { |path| capture('vtool', '-show-build', path)[/\bminos\s+(\S+)/, 1] }.compact
minimum << '13.0'
minimum = minimum.max_by { |version| version.split('.').map(&:to_i) }
File.write(File.join(contents, 'Info.plist'), <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
  <key>CFBundleName</key><string>VQMetrix</string>
  <key>CFBundleDisplayName</key><string>VQMetrix</string>
  <key>CFBundleIdentifier</key><string>com.haishinkit.VQMetrix</string>
  <key>CFBundleExecutable</key><string>VQMetrix</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>#{short_version}</string>
  <key>VQMetrixReleaseVersion</key><string>#{version}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>#{minimum}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>NSCameraUsageDescription</key><string>VQMetrix uses the camera only while measuring video quality. No audio is captured.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Receive evaluation samples from other devices on your local network.</string>
  <key>NSBonjourServices</key><array><string>_vqmetrix._tcp</string></array>
  </dict></plist>
PLIST
(Dir[File.join(resources, '*.bundle')] + [library, File.join(contents, 'MacOS/VQMetrix'), app]).each do |path|
  capture('codesign', '--force', '--sign', '-', path)
end
capture('codesign', '--verify', '--deep', '--strict', app)
archive = File.join(ROOT, ".build/VQMetrix-macos-#{capture('uname', '-m')}.zip")
capture('ditto', '-c', '-k', '--keepParent', app, archive)
puts "App: #{app}"
puts "Archive: #{archive}"
puts "Minimum macOS: #{minimum}; ad hoc signed, not notarized"
