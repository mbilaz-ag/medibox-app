"""Configure fresh Flutter native projects without overwriting application Dart files.
Run after flutter create --platforms=android,ios --no-pub in a temporary directory.
"""
from pathlib import Path
import plistlib
import re
import shutil
import sys
from android_signing import configure_android_signing

root = Path(__file__).resolve().parents[1]
generated = Path(sys.argv[1])
for platform in ('android', 'ios'):
    target = root / platform
    if not target.exists():
        shutil.copytree(generated / platform, target)

manifest = root / 'android/app/src/main/AndroidManifest.xml'
text = manifest.read_text().replace('android:label="medibox"', 'android:label="MediBox"')
if 'android:allowBackup=' not in text:
    text = text.replace(
        '<application',
        '<application\n        android:allowBackup="false"\n        android:fullBackupContent="@xml/backup_rules"\n        android:dataExtractionRules="@xml/data_extraction_rules"',
        1,
    )
if 'android.permission.INTERNET' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        1,
    )
if 'android.permission.POST_NOTIFICATIONS' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <application',
        1,
    )
if 'android.permission.SCHEDULE_EXACT_ALARM' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>\n    <application',
        1,
    )
if 'android.permission.CAMERA' not in text:
    text = text.replace('<application', '<uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
if 'android.permission.RECEIVE_BOOT_COMPLETED' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n    <application',
        1,
    )
if 'ScheduledNotificationReceiver' not in text:
    receivers = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver" />
'''
    text = text.replace('</application>', receivers + '    </application>', 1)
manifest.write_text(text)

backup_domains = (
    'root', 'file', 'database', 'sharedpref', 'external',
    'device_root', 'device_file', 'device_database', 'device_sharedpref',
)
xml_dir = root / 'android/app/src/main/res/xml'
xml_dir.mkdir(parents=True, exist_ok=True)
exclusions = '\n'.join(
    f'    <exclude domain="{domain}" path="." />' for domain in backup_domains
)
(xml_dir / 'backup_rules.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<full-backup-content>\n'
    f'{exclusions}\n'
    '</full-backup-content>\n'
)
section_exclusions = '\n'.join(
    f'        <exclude domain="{domain}" path="." />' for domain in backup_domains
)
(xml_dir / 'data_extraction_rules.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<data-extraction-rules>\n'
    '    <cloud-backup>\n'
    f'{section_exclusions}\n'
    '    </cloud-backup>\n'
    '    <device-transfer>\n'
    f'{section_exclusions}\n'
    '    </device-transfer>\n'
    '</data-extraction-rules>\n'
)

# local_auth requires FragmentActivity on Android.
for activity in (root / 'android/app/src/main').rglob('MainActivity.kt'):
    activity_text = activity.read_text()
    activity_text = activity_text.replace(
        'import io.flutter.embedding.android.FlutterActivity',
        'import io.flutter.embedding.android.FlutterFragmentActivity',
    ).replace('FlutterActivity()', 'FlutterFragmentActivity()')
    activity.write_text(activity_text)

# Install the MediBox launcher icon generated from the approved brand mark.
android_icons = {
    'mipmap-mdpi': 'mdpi.png',
    'mipmap-hdpi': 'hdpi.png',
    'mipmap-xhdpi': 'xhdpi.png',
    'mipmap-xxhdpi': 'xxhdpi.png',
    'mipmap-xxxhdpi': 'xxxhdpi.png',
}
for folder, source_name in android_icons.items():
    destination = root / 'android/app/src/main/res' / folder
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / 'assets/icon/android' / source_name,
                 destination / 'ic_launcher.png')
gradle = root / 'android/app/build.gradle.kts'
if gradle.exists():
    text = (gradle.read_text()
            .replace('minSdk = flutter.minSdkVersion', 'minSdk = 23')
            .replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 36')
            .replace('targetSdk = flutter.targetSdkVersion', 'targetSdk = 36'))
    text = configure_android_signing(text)
    if 'medibox-r8-rules' not in text:
        text += '''

// medibox-r8-rules: ML Kit exposes optional scripts which are not bundled.
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        getByName("release") {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
'''
    gradle.write_text(text)
(root / 'android/app/proguard-rules.pro').write_text('''# MediBox uses only TextRecognitionScript.latin.
# The Flutter bridge references optional recognizers in its switch, so R8 must
# tolerate their absence when the optional language artifacts are not bundled.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
''')

info = root / 'ios/Runner/Info.plist'
with info.open('rb') as f:
    data = plistlib.load(f)
data.update({
    'CFBundleDisplayName': 'MediBox',
    'NSCameraUsageDescription': 'Kamera naudojama vaistų pakuotėms, čekiams ir kodams nuskaityti.',
    'NSPhotoLibraryUsageDescription': 'Pasirinkta nuotrauka naudojama vaisto arba čekio tekstui atpažinti.',
    'NSPhotoLibraryAddUsageDescription': 'Nuotrauka išsaugoma tik tada, kai tai aiškiai pasirenkate.',
    'NSFaceIDUsageDescription': 'Face ID naudojamas MediBox sveikatos duomenims apsaugoti.',
    'GIDClientID': '281777960665-ih4n1o1v4mqhsm2kj0mddc1oso1mljrm.apps.googleusercontent.com',
    'GIDServerClientID': '281777960665-b2nigi9i4lfsi6s2gjegvidmnbrhv7mm.apps.googleusercontent.com',
    'CFBundleURLTypes': [{
        'CFBundleTypeRole': 'Editor',
        'CFBundleURLSchemes': [
            'com.googleusercontent.apps.281777960665-ih4n1o1v4mqhsm2kj0mddc1oso1mljrm',
        ],
    }],
})
with info.open('wb') as f:
    plistlib.dump(data, f, sort_keys=False)
ios_icon_target = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
ios_icon_target.mkdir(parents=True, exist_ok=True)
for source in sorted((root / 'assets/icon/ios').glob('*.png')):
    shutil.copy2(source, ios_icon_target / source.name)
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
