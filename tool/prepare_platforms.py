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
if 'android.permission.ACCESS_NOTIFICATION_POLICY' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.ACCESS_NOTIFICATION_POLICY"/>\n    <application',
        1,
    )
if 'android.permission.USE_FULL_SCREEN_INTENT' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>\n    <application',
        1,
    )
if 'android.permission.MODIFY_AUDIO_SETTINGS' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>\n    <application',
        1,
    )
if 'android.permission.VIBRATE' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.VIBRATE"/>\n    <application',
        1,
    )
if 'android.permission.WAKE_LOCK' not in text:
    text = text.replace(
        '<application',
        '<uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <application',
        1,
    )
if 'android:showWhenLocked=' not in text:
    text = text.replace(
        '<activity',
        '<activity\n            android:showWhenLocked="true"\n            android:turnScreenOn="true"',
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
        <receiver android:exported="false" android:name=".MediBoxAlarmReceiver" />
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
    if 'medibox/alarm_volume' not in activity_text:
        activity_text = activity_text.replace(
            'import io.flutter.embedding.android.FlutterFragmentActivity',
            '''import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray''',
        )
        activity_text = re.sub(
            r'class MainActivity\s*:\s*FlutterFragmentActivity\(\)\s*',
            '''class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "medibox/alarm_volume",
        ).setMethodCallHandler { call, result ->
            if (call.method == "maximizeAlarmVolume") {
                try {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    audio.setStreamVolume(
                        AudioManager.STREAM_ALARM,
                        audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                        0,
                    )
                    result.success(true)
                } catch (error: Exception) {
                    result.error("alarm_volume", error.message, null)
                }
            } else if (call.method == "scheduleMaximumAlarm") {
                val id = call.argument<Number>("id")?.toInt()
                val atMillis = call.argument<Number>("atMillis")?.toLong()
                if (id == null || atMillis == null) {
                    result.error("alarm_arguments", "Missing alarm id or time", null)
                } else {
                    MediBoxAlarmScheduler.schedule(
                        this,
                        id,
                        atMillis,
                        call.argument<String>("reminderId") ?: "",
                        call.argument<String>("occurrenceDate") ?: "",
                    )
                    result.success(true)
                }
            } else if (call.method == "playMaximumAlarm") {
                sendBroadcast(Intent(this, MediBoxAlarmReceiver::class.java))
                result.success(true)
            } else if (call.method == "stopMaximumAlarm") {
                MediBoxAlarmPlayback.stop(applicationContext)
                result.success(true)
            } else if (call.method == "cancelAllMaximumAlarms") {
                MediBoxAlarmScheduler.cancelAll(this)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}

private object MediBoxAlarmScheduler {
    private const val preferencesName = "medibox_maximum_alarm_ids"

    private fun pendingIntent(context: Context, id: Int, intent: Intent): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    fun schedule(
        context: Context,
        id: Int,
        atMillis: Long,
        reminderId: String,
        occurrenceDate: String,
    ) {
        val intent = Intent(context, MediBoxAlarmReceiver::class.java)
            .putExtra("alarmId", id)
            .putExtra("reminderId", reminderId)
            .putExtra("occurrenceDate", occurrenceDate)
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val operation = pendingIntent(context, id, intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager.canScheduleExactAlarms()
        ) {
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, operation)
        } else {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, operation)
        }
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val ids = preferences.getStringSet("ids", emptySet())!!.toMutableSet()
        ids.add(id.toString())
        preferences.edit().putStringSet("ids", ids).apply()
    }

    fun cancelAll(context: Context) {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val ids = preferences.getStringSet("ids", emptySet())!!.toSet()
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (value in ids) {
            val id = value.toIntOrNull() ?: continue
            val intent = Intent(context, MediBoxAlarmReceiver::class.java)
            alarmManager.cancel(pendingIntent(context, id, intent))
        }
        preferences.edit().remove("ids").apply()
    }

    fun remove(context: Context, id: Int) {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val ids = preferences.getStringSet("ids", emptySet())!!.toMutableSet()
        ids.remove(id.toString())
        preferences.edit().putStringSet("ids", ids).apply()
    }
}

private object MediBoxAlarmPlayback {
    private const val flutterPreferencesName = "FlutterSharedPreferences"
    private const val stopSignalKey = "flutter.medibox_stop_alarm_signal_v1"
    private const val stopSignalPollMillis = 150L
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var pendingResult: BroadcastReceiver.PendingResult? = null
    private var activeSession = 0L

    @Synchronized
    fun stop(context: Context) {
        activeSession += 1
        try {
            player?.stop()
        } catch (_: Exception) {}
        player?.release()
        player = null
        vibrator?.cancel()
        vibrator = null
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        pendingResult?.finish()
        pendingResult = null
    }

    fun start(context: Context, result: BroadcastReceiver.PendingResult) {
        val application = context.applicationContext
        stop(application)
        val stopSignalAtStart = stopSignal(application)
        val session: Long
        synchronized(this) {
            activeSession += 1
            session = activeSession
            pendingResult = result
        }
        val power = application.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "MediBox:MedicineAlarm",
        ).also { it.acquire(20_000) }

        val audio = application.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            audio.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0,
            )
        } catch (_: Exception) {}

        vibrator = application.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        val pattern = longArrayOf(0, 1500, 250, 1500, 250, 2000, 400, 2500)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(
                VibrationEffect.createWaveform(
                    pattern,
                    intArrayOf(0, 255, 0, 255, 0, 255, 0, 255),
                    -1,
                ),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
            )
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, -1)
        }

        val finishPlayback = { finishIfActive(application, session) }
        pollForStopSignal(application, session, stopSignalAtStart)
        try {
            val descriptor = application.resources.openRawResourceFd(R.raw.medibox_alarm)
            player = MediaPlayer().also { media ->
                media.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                media.setDataSource(
                    descriptor.fileDescriptor,
                    descriptor.startOffset,
                    descriptor.length,
                )
                descriptor.close()
                media.setVolume(1.0f, 1.0f)
                media.setOnCompletionListener { finishPlayback() }
                media.prepare()
                media.start()
            }
            Handler(Looper.getMainLooper()).postDelayed(
                { finishPlayback() },
                15_000,
            )
        } catch (_: Exception) {
            finishPlayback()
        }
    }

    @Synchronized
    private fun finishIfActive(context: Context, session: Long) {
        if (activeSession == session) stop(context)
    }

    private fun stopSignal(context: Context): Long =
        context.getSharedPreferences(flutterPreferencesName, Context.MODE_PRIVATE)
            .getLong(stopSignalKey, 0L)

    private fun pollForStopSignal(
        context: Context,
        session: Long,
        initialSignal: Long,
    ) {
        Handler(Looper.getMainLooper()).postDelayed(
            {
                if (activeSession != session) return@postDelayed
                if (stopSignal(context) != initialSignal) {
                    finishIfActive(context, session)
                } else {
                    pollForStopSignal(context, session, initialSignal)
                }
            },
            stopSignalPollMillis,
        )
    }

}

class MediBoxAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val alarmId = intent.getIntExtra("alarmId", -1)
        if (alarmId >= 0) MediBoxAlarmScheduler.remove(context, alarmId)
        if (doseAlreadyHandled(context, intent)) return
        MediBoxAlarmPlayback.start(context, goAsync())
    }

    private fun doseAlreadyHandled(context: Context, intent: Intent): Boolean {
        val reminderId = intent.getStringExtra("reminderId") ?: return false
        val occurrenceDate = intent.getStringExtra("occurrenceDate") ?: return false
        if (reminderId.isEmpty() || occurrenceDate.isEmpty()) return false
        return try {
            val preferences = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            val raw = preferences.getString("flutter.medibox_reminders_v1", null)
                ?: return false
            val reminders = JSONArray(raw)
            for (index in 0 until reminders.length()) {
                val reminder = reminders.getJSONObject(index)
                if (reminder.optString("id") != reminderId) continue
                val taken = reminder.optJSONArray("takenDates")
                val skipped = reminder.optJSONArray("skippedDates")
                return arrayContains(taken, occurrenceDate) ||
                    arrayContains(skipped, occurrenceDate)
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun arrayContains(values: JSONArray?, expected: String): Boolean {
        if (values == null) return false
        for (index in 0 until values.length()) {
            if (values.optString(index) == expected) return true
        }
        return false
    }
}
''',
            activity_text,
            count=1,
        )
    activity.write_text(activity_text)

android_raw = root / 'android/app/src/main/res/raw'
android_raw.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'assets/sounds/medibox_alarm.ogg',
             android_raw / 'medibox_alarm.ogg')

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
