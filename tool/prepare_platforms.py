"""Configure fresh Flutter native projects without overwriting application Dart files.
Run after flutter create --platforms=android,ios --no-pub in a temporary directory.
"""
from pathlib import Path
import plistlib
import re
import shutil
import sys

root = Path(__file__).resolve().parents[1]
generated = Path(sys.argv[1])
for platform in ('android', 'ios'):
    target = root / platform
    if not target.exists():
        shutil.copytree(generated / platform, target)

manifest = root / 'android/app/src/main/AndroidManifest.xml'
text = manifest.read_text().replace('android:label="medibox"', 'android:label="MediBox"')
if 'android.permission.CAMERA' not in text:
    text = text.replace('<application', '<uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
manifest.write_text(text)
gradle = root / 'android/app/build.gradle.kts'
if gradle.exists():
    text = gradle.read_text().replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
    gradle.write_text(text)

info = root / 'ios/Runner/Info.plist'
with info.open('rb') as f:
    data = plistlib.load(f)
data.update({
    'CFBundleDisplayName': 'MediBox',
    'NSCameraUsageDescription': 'Kamera naudojama vaistų pakuotėms, čekiams ir kodams nuskaityti.',
    'NSPhotoLibraryUsageDescription': 'Pasirinkta nuotrauka naudojama vaisto arba čekio tekstui atpažinti.',
})
with info.open('wb') as f:
    plistlib.dump(data, f, sort_keys=False)
project = root / 'ios/Runner.xcodeproj/project.pbxproj'
text = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;', 'IPHONEOS_DEPLOYMENT_TARGET = 15.5;', project.read_text())
project.write_text(text)
(root / 'ios/Podfile').write_text('''platform :ios, '15.5'
ENV['COCOAPODS_DISABLE_STATS'] = 'true'
project 'Runner', {'Debug' => :debug, 'Profile' => :release, 'Release' => :release}
def flutter_root
  config = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  raise "Run flutter pub get first" unless File.exist?(config)
  File.foreach(config) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise 'FLUTTER_ROOT missing'
end
require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)
flutter_ios_podfile_setup
target 'Runner' do
  use_frameworks!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['EXCLUDED_ARCHS[sdk=*]'] = 'armv7'
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] || '0'
      if Gem::Version.new(current) < Gem::Version.new('15.5')
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.5'
      end
    end
  end
end
''')
print('Android and iOS configured; application source and tests preserved.')
