import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models/models.dart';
import 'services/medicine_matcher.dart';
import 'services/reminder_logic.dart';
import 'services/reminder_notifications.dart';
import 'services/expiry_status.dart';
import 'services/store.dart';
import 'services/vvkt_service.dart';
import 'services/ai_symptom_service.dart';
import 'services/ai_medicine_profile_service.dart';
import 'services/ai_medicine_advisor_service.dart';
import 'services/medicine_image_service.dart';
import 'services/dose_guidance.dart';
import 'widgets/body_map.dart';
import 'models/leaflet_draft.dart';
import 'widgets/leaflet_import_page.dart' show LeafletRecordCard;
import 'widgets/medicine_price_card.dart';
import 'services/firebase_leaflet_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/app_update_service.dart';
import 'services/subscription_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppUpdateService.initialize();
  await ReminderNotifications.initialize();
  runApp(const App());
}

const green = Color(0xff079b7a),
    navy = Color(0xff102a43),
    mint = Color(0xffe9f8f4),
    appointmentBlue = Color(0xff3478c9),
    appointmentBlueSoft = Color(0xffeaf3ff);
String tx(BuildContext c, String lt, String en) =>
    Localizations.localeOf(c).languageCode == 'en' ? en : lt;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();
String dateKey([DateTime? value]) {
  final d = value ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String quantityLabel(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

String doseUnitLabel(BuildContext context, String unit) {
  if (Localizations.localeOf(context).languageCode != 'en') return unit;
  return switch (unit) {
    'vnt.' => 'unit',
    'tabletė' => 'tablet',
    'kapsulė' => 'capsule',
    'dozė' => 'dose',
    'tūbelė' => 'tube',
    'įpurškimas' => 'spray',
    'lašas' => 'drop',
    _ => unit,
  };
}

const medicineQuantityUnits = [
  'vnt.',
  'tabletė',
  'kapsulė',
  'ml',
  'g',
  'mg',
  'dozė',
  'tūbelė',
  'įpurškimas',
  'lašas',
];

String suggestedMedicineQuantityUnit(String dosageForm) {
  final value = dosageForm.toLowerCase();
  if (value.contains('tūbel')) return 'tūbelė';
  if (value.contains('tablet')) return 'tabletė';
  if (value.contains('kapsul')) return 'kapsulė';
  if (value.contains('laš')) return 'lašas';
  if (value.contains('purš') || value.contains('aerozol')) return 'įpurškimas';
  if (value.contains('tirpal') ||
      value.contains('sirup') ||
      value.contains('suspens') ||
      value.contains('skyst')) {
    return 'ml';
  }
  if (value.contains('krem') ||
      value.contains('tepal') ||
      value.contains('gel')) {
    return 'g';
  }
  return 'vnt.';
}

String subscriptionPlanLabel(BuildContext context, SubscriptionPlan plan) =>
    switch (plan) {
      SubscriptionPlan.free => 'Free',
      SubscriptionPlan.premiumMonthly =>
        tx(context, 'Premium mėnesinis', 'Premium monthly'),
      SubscriptionPlan.premiumYearly =>
        tx(context, 'Premium metinis', 'Premium yearly'),
    };

Future<bool> requirePremium(BuildContext context) async {
  if (SubscriptionService.instance.hasPremium) return true;
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SubscriptionPage()),
  );
  return SubscriptionService.instance.hasPremium;
}

/// Keeps the final control above Android's gesture/navigation area on long
/// pages. A fixed 18–28 px bottom inset is not enough on many phones.
EdgeInsets scrollPagePadding(
  BuildContext context, {
  double horizontal = 18,
  double top = 18,
}) => EdgeInsets.fromLTRB(
  horizontal,
  top,
  horizontal,
  MediaQuery.viewPaddingOf(context).bottom + 96,
);

bool reminderMatchesMember(AppData data, Reminder reminder, String memberId) {
  if (memberId.isEmpty) return true;
  if (reminder.memberId == memberId) return true;
  if (reminder.memberId.isNotEmpty) return false;

  final medicine = data.meds
      .where((item) => item.id == reminder.medId)
      .firstOrNull;
  if (medicine != null && medicine.memberIds.contains(memberId)) return true;

  final member = data.members.where((item) => item.id == memberId).firstOrNull;
  return medicine != null &&
      medicine.memberIds.isEmpty &&
      member?.relation == 'self';
}

class DateDashFormatter extends TextInputFormatter {
  final bool monthOnly;
  DateDashFormatter({this.monthOnly = false});
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final max = monthOnly ? 6 : 8;
    final length = digits.length > max ? max : digits.length;
    final value = digits.substring(0, length);
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (i == 4 || (!monthOnly && i == 6)) out.write('-');
      out.write(value[i]);
    }
    return TextEditingValue(
      text: out.toString(),
      selection: TextSelection.collapsed(offset: out.length),
    );
  }
}

class App extends StatefulWidget {
  const App({super.key});
  State<App> createState() => _App();
}

Future<bool> _showPermissionsCenter(
  BuildContext context,
  AppData data, {
  required bool firstLaunch,
}) async {
  var camera = data.cameraConsentGranted;
  var medicineNotifications = data.medicationNotificationsGranted;
  var repeatUnconfirmed = data.repeatUnconfirmedMedicationReminders;
  var loudMedicationReminders = data.loudMedicationReminders;
  var appointmentNotifications = data.appointmentNotificationsGranted;
  var ai = data.aiConsentGranted;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: !firstLaunch,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(tx(dialogContext, 'Sutikimai ir leidimai', 'Permissions and consent')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tx(
                dialogContext,
                'Pasirinkite kiekvieną funkciją atskirai. Šiuos pasirinkimus vėliau galėsite pakeisti profilyje.',
                'Choose each feature separately. You can change these choices later in your profile.',
              )),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.camera_alt_outlined),
                value: camera,
                title: Text(tx(dialogContext, 'Kamera', 'Camera')),
                subtitle: Text(tx(dialogContext, 'Fotografuoti ir atpažinti vaistų pakuotes', 'Photograph and recognize medicine packages')),
                onChanged: (value) => setDialogState(() => camera = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.medication_outlined),
                value: medicineNotifications,
                title: Text(tx(dialogContext, 'Vaistų priminimai', 'Medicine reminders')),
                subtitle: Text(tx(dialogContext, 'Gauti pranešimus apie vaistą, dozę ir vartojimo laiką', 'Receive medicine, dose and schedule notifications')),
                onChanged: (value) => setDialogState(() => medicineNotifications = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.notification_important_outlined),
                value: medicineNotifications && repeatUnconfirmed,
                title: Text(tx(
                  dialogContext,
                  'Kartoti nepatvirtintą priminimą',
                  'Repeat unconfirmed reminder',
                )),
                subtitle: Text(tx(
                  dialogContext,
                  'Jei nepasirinktas joks veiksmas, kartoti kas 30 min. iki reakcijos (ne ilgiau kaip 24 val.)',
                  'If no action is selected, repeat every 30 min. until you respond (up to 24 hours)',
                )),
                onChanged: medicineNotifications
                    ? (value) => setDialogState(() => repeatUnconfirmed = value)
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.alarm_on_rounded),
                value: medicineNotifications && loudMedicationReminders,
                title: Text(tx(
                  dialogContext,
                  'Maksimalaus garsumo priminimai',
                  'Maximum alert reminders',
                )),
                subtitle: Text(tx(
                  dialogContext,
                  'Žadintuvo garsas, stipri vibracija ir perspėjimas virš užrakinto ekrano. „Netrukdyti“ režimui reikės atskiro telefono leidimo.',
                  'Alarm sound, strong vibration and an alert over the lock screen. Bypassing Do Not Disturb requires a separate phone permission.',
                )),
                onChanged: medicineNotifications
                    ? (value) => setDialogState(
                        () => loudMedicationReminders = value,
                      )
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.event_available_outlined),
                value: appointmentNotifications,
                title: Text(tx(dialogContext, 'Vizitų priminimai', 'Appointment reminders')),
                subtitle: Text(tx(dialogContext, 'Gauti pranešimus apie suplanuotus vizitus', 'Receive notifications about scheduled appointments')),
                onChanged: (value) => setDialogState(() => appointmentNotifications = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.auto_awesome_rounded),
                value: ai,
                title: const Text('Firebase AI / Gemini'),
                subtitle: Text(tx(dialogContext, 'Vaistų atpažinimas, paaiškinimai ir „Man bloga“ analizė', 'Medicine recognition, explanations and symptom analysis')),
                onChanged: (value) => setDialogState(() => ai = value),
              ),
            ],
          ),
        ),
        actions: [
          if (!firstLaunch)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tx(dialogContext, 'Atšaukti', 'Cancel')),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tx(dialogContext, 'Išsaugoti ir tęsti', 'Save and continue')),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return false;

  data
    ..permissionsChoiceMade = true
    ..aiConsentChoiceMade = true
    ..aiConsentGranted = ai
    ..cameraConsentGranted = camera
    ..medicationNotificationsGranted = medicineNotifications
    ..repeatUnconfirmedMedicationReminders = repeatUnconfirmed
    ..loudMedicationReminders =
        medicineNotifications && loudMedicationReminders
    ..appointmentNotificationsGranted = appointmentNotifications;

  if (camera) {
    data.cameraPermissionAsked = true;
    final status = await Permission.camera.request();
    if (!status.isGranted) data.cameraConsentGranted = false;
  }
  if (medicineNotifications || appointmentNotifications) {
    await ReminderNotifications.requestPermissions();
  }
  if (medicineNotifications && loudMedicationReminders) {
    await ReminderNotifications.requestMaximumAlertPermissions();
  }
  await Store.save(data);
  await ReminderNotifications.scheduleAll(data);
  return true;
}

Future<bool> _cameraAvailable(BuildContext context, AppData data) async {
  if (!data.cameraConsentGranted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tx(
          context,
          'Kamerą įjunkite: Profilis → Sutikimai ir leidimai.',
          'Enable the camera in Profile → Permissions and consent.',
        )),
      ));
    }
    return false;
  }
  final status = await Permission.camera.request();
  if (status.isGranted) return true;
  data.cameraConsentGranted = false;
  await Store.save(data);
  return false;
}

class _App extends State<App> with WidgetsBindingObserver {
  AppData? data;
  bool launchAccepted = false;
  bool authenticating = false;
  bool _reloadingNotificationActions = false;
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _finishOpening(AppData current) async {
    if (current.onboarded && !current.permissionsChoiceMade && mounted) {
      await _showPermissionsCenter(
        navigatorKey.currentContext!,
        current,
        firstLaunch: true,
      );
    }
    if (mounted) {
      setState(() => launchAccepted = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    }
  }

  Future<void> _checkForUpdate({bool manual = false}) async {
    final update = await AppUpdateService.check();
    final context = navigatorKey.currentContext;
    if (!mounted || context == null) return;
    if (update == null) {
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tx(
                context,
                'Naudojate naujausią versiją.',
                'You are using the latest version.',
              ),
            ),
          ),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(
          Icons.system_update_alt_rounded,
          color: green,
          size: 36,
        ),
        title: Text(
          tx(dialogContext, 'Yra atnaujinimas', 'Update available'),
        ),
        content: Text(
          tx(
            dialogContext,
            'Paruošta MediBox ${update.version} versija. Atsisiuntus telefonas paprašys patvirtinti diegimą.',
            'MediBox ${update.version} is ready. Your phone will ask you to confirm installation after download.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tx(dialogContext, 'Vėliau', 'Later')),
          ),
          FilledButton.icon(
            onPressed: () async {
              await launchUrl(
                Uri.parse(update.downloadUrl),
                mode: LaunchMode.externalApplication,
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.download_rounded),
            label: Text(tx(dialogContext, 'Atsisiųsti', 'Download')),
          ),
        ],
      ),
    );
  }

  Future<void> _openApp() async {
    final current = data;
    if (current == null || authenticating) return;
    if (!current.privacyLock) {
      await _finishOpening(current);
      return;
    }
    setState(() => authenticating = true);
    try {
      final accepted = await LocalAuthentication().authenticate(
        localizedReason: 'Atrakinkite MediBox sveikatos duomenis',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (mounted && accepted) await _finishOpening(current);
    } catch (_) {
      // The app remains locked if the device cannot authenticate.
    } finally {
      if (mounted) setState(() => authenticating = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.wait([
      Store.load(),
      Future<void>.delayed(const Duration(milliseconds: 1400)),
    ]).then((values) {
      final v = values.first as AppData;
      ReminderNotifications.onAction = _handleReminderAction;
      ReminderNotifications.scheduleAll(v);
      if (mounted) setState(() => data = v);
      CloudSyncService.instance.resume(
        v,
        onRemoteApplied: () async {
          await ReminderNotifications.scheduleAll(v);
          if (mounted) setState(() {});
        },
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reloadNotificationActions());
    }
  }

  Future<void> _reloadNotificationActions() async {
    final current = data;
    if (current == null || _reloadingNotificationActions) return;
    _reloadingNotificationActions = true;
    try {
      // Give the background notification isolate time to finish its local
      // write before refreshing the in-memory reminder history.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final stored = await Store.load();
      current.meds = stored.meds;
      current.reminders = stored.reminders;
      CloudSyncService.instance.queueUpload(current);
      await ReminderNotifications.scheduleAll(current);
      if (mounted) setState(() {});
    } finally {
      _reloadingNotificationActions = false;
    }
  }

  Future<void> _handleReminderAction(
    String action,
    String reminderId,
    DateTime occurrence,
  ) async {
    final current = data;
    if (current == null) return;
    final matches = current.reminders.where((x) => x.id == reminderId);
    if (matches.isEmpty) return;
    final reminder = matches.first;
    if (action == 'taken') {
      markDoseTaken(current, reminder, occurrence);
      await ReminderNotifications.cancelOccurrence(reminder, occurrence);
    } else if (action == 'skip') {
      markDoseSkipped(reminder, occurrence);
      await ReminderNotifications.cancelOccurrence(reminder, occurrence);
    } else if (action == 'snooze') {
      await ReminderNotifications.snooze(reminder, current, occurrence);
    }
    await Store.recordPendingReminderAction(
      action,
      reminder.id,
      occurrence,
    );
    await Store.save(current);
    CloudSyncService.instance.queueUpload(current);
    if (mounted) setState(() {});
  }

  void changed() {
    if (data != null) {
      Store.save(data!);
      CloudSyncService.instance.queueUpload(data!);
      ReminderNotifications.scheduleAll(data!);
      setState(() {});
    }
  }

  @override
  Widget build(c) {
    final d = data;
    if (d == null || !launchAccepted) {
      return MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        locale: d != null && d.language != 'system' ? Locale(d.language) : null,
        supportedLocales: const [Locale('lt'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: LaunchScreen(
          ready: d != null,
          onStart: d == null ? null : _openApp,
        ),
      );
    }
    Locale? locale;
    if (d.language != 'system') locale = Locale(d.language);
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'MediBox',
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.9,
        maxScaleFactor: 1.2,
        child: child!,
      ),
      locale: locale,
      supportedLocales: const [Locale('lt'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        brightness: Brightness.light,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.fromSeed(
          seedColor: green,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff6fbfa),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xffe0eeeb)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff078b71),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: d.onboarded
          ? Shell(data: d, onChanged: changed)
          : OnboardingPage(data: d, onChanged: changed),
    );
  }
}

class LaunchScreen extends StatelessWidget {
  final bool ready;
  final VoidCallback? onStart;
  const LaunchScreen({super.key, required this.ready, this.onStart});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff8fcfb),
    body: Stack(
      children: [
        Positioned.fill(
          child: Image.asset(
            'assets/images/medibox_home_background.webp',
            fit: BoxFit.cover,
          ),
        ),
        Positioned.fill(
          child: ColoredBox(color: Colors.white.withValues(alpha: .24)),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 14),
            child: Column(
              children: [
                const MediBoxLogo(size: 82),
                const SizedBox(height: 10),
                const Text(
                  'MediBox',
                  style: TextStyle(
                    fontSize: 43,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    color: navy,
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  tx(
                    context,
                    'Tavo išmani šeimos vaistinėlė.',
                    'Your smart family medicine cabinet.',
                  ),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: navy,
                  ),
                ),
                const SizedBox(height: 2),
                Expanded(
                  child: Transform.translate(
                    offset: const Offset(0, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: Image.asset(
                        'assets/images/medibox_family_equal.webp',
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -12),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(17, 12, 17, 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .92),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xffe5efec)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x18082f29),
                          blurRadius: 20,
                          offset: Offset(0, 7),
                        ),
                      ],
                    ),
                    child: const Column(
                      children: [
                        _LaunchBenefit(
                          Icons.inventory_2_outlined,
                          'Mažiau rūpesčių',
                          'Less worry',
                        ),
                        _LaunchBenefit(
                          Icons.verified_user_outlined,
                          'Daugiau saugumo',
                          'More safety',
                        ),
                        _LaunchBenefit(
                          Icons.people_outline,
                          'Sveikesnė šeima',
                          'A healthier family',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: green,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: onStart,
                  child: ready
                      ? Text(tx(context, 'Pradėti', 'Get started'))
                      : const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        ),
                ),
                SizedBox(
                  height: 36,
                  child: TextButton(
                    onPressed: ready ? onStart : null,
                    child: Text(
                      tx(
                        context,
                        'Turi paskyrą? Prisijungti',
                        'Have an account? Sign in',
                      ),
                      style: const TextStyle(
                        color: green,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _LaunchBenefit extends StatelessWidget {
  final IconData icon;
  final String lt, en;
  const _LaunchBenefit(this.icon, this.lt, this.en);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, color: green, size: 21),
        const SizedBox(width: 12),
        Text(
          tx(context, lt, en),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class MediBoxLogo extends StatelessWidget {
  final double size;
  const MediBoxLogo({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.14,
    height: size,
    child: Stack(
      children: [
        Positioned(
          left: 0,
          top: size * .28,
          child: _logoSquare(size * .68, const [
            Color(0xff079b7a),
            Color(0xff057c65),
          ]),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: _logoSquare(size * .72, const [
            Color(0xff59ddb4),
            Color(0xff14aa86),
          ]),
        ),
        Center(
          child: Icon(Icons.add_rounded, color: Colors.white, size: size * .62),
        ),
      ],
    ),
  );

  Widget _logoSquare(double side, List<Color> colors) => Container(
    width: side,
    height: side,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: colors,
      ),
      borderRadius: BorderRadius.circular(side * .25),
      boxShadow: const [
        BoxShadow(
          color: Color(0x28078b71),
          blurRadius: 14,
          offset: Offset(0, 6),
        ),
      ],
    ),
  );
}

class OnboardingPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const OnboardingPage({
    super.key,
    required this.data,
    required this.onChanged,
  });
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  int step = 0;
  bool busy = false;
  String error = '';
  late final name = TextEditingController(text: widget.data.profile.name);
  late final birth = TextEditingController(text: widget.data.profile.birthDate);
  late final phone = TextEditingController(text: widget.data.profile.phone);
  late final email = TextEditingController(text: widget.data.profile.email);
  late final blood = TextEditingController(text: widget.data.profile.bloodType);
  late final allergies = TextEditingController(text: widget.data.profile.allergies);
  late final conditions = TextEditingController(text: widget.data.profile.conditions);
  late final medications = TextEditingController(text: widget.data.profile.medications);
  late final emergencyName = TextEditingController(text: widget.data.profile.emergencyName);
  late final emergencyPhone = TextEditingController(text: widget.data.profile.emergencyPhone);
  final height = TextEditingController();
  final weight = TextEditingController();
  String gender = 'unspecified';

  void _reloadProfileControllers() {
    final profile = widget.data.profile;
    name.text = profile.name;
    birth.text = profile.birthDate;
    phone.text = profile.phone;
    email.text = profile.email;
    blood.text = profile.bloodType;
    allergies.text = profile.allergies;
    conditions.text = profile.conditions;
    medications.text = profile.medications;
    emergencyName.text = profile.emergencyName;
    emergencyPhone.text = profile.emergencyPhone;
    final own = widget.data.members.where((member) => member.relation == 'self');
    if (own.isNotEmpty) {
      gender = own.first.gender;
      height.text = own.first.height;
      weight.text = own.first.weight;
    }
  }

  @override
  void dispose() {
    for (final controller in [name, birth, phone, email, blood, allergies, conditions, medications, emergencyName, emergencyPhone, height, weight]) {
      controller.dispose();
    }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: switch (step) {
          0 => _welcome(context),
          1 => _permissions(context),
          2 => _account(context),
          3 => _profile(context),
          4 => _family(context),
          _ => _sharing(context),
        },
      ),
    ),
  );

  Widget _welcome(BuildContext context) => Padding(
    key: const ValueKey('welcome'),
    padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
    child: Column(
      children: [
        const MediBoxLogo(size: 76),
        const SizedBox(height: 14),
        const Text(
          'MediBox',
          style: TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.w800,
            color: navy,
          ),
        ),
        Text(
          tx(
            context,
            'Tavo išmani šeimos vaistinėlė.',
            'Your smart family medicine cabinet.',
          ),
          style: const TextStyle(fontSize: 17, color: navy),
        ),
        const SizedBox(height: 8),
        Text(
          tx(context, 'Pasirinkite programėlės kalbą', 'Choose app language'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'lt', label: Text('Lietuvių')),
            ButtonSegment(value: 'en', label: Text('English')),
          ],
          selected: {widget.data.language == 'en' ? 'en' : 'lt'},
          onSelectionChanged: (value) {
            widget.data.language = value.first;
            widget.onChanged();
            setState(() {});
          },
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Image.asset(
            'assets/images/medibox_family_equal.webp',
            fit: BoxFit.contain,
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              _benefit(
                Icons.inventory_2_outlined,
                tx(context, 'Mažiau rūpesčių', 'Less worry'),
              ),
              _benefit(
                Icons.verified_user_outlined,
                tx(context, 'Daugiau saugumo', 'More safety'),
              ),
              _benefit(
                Icons.people_outline,
                tx(context, 'Sveikesnė šeima', 'A healthier family'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () {
            if (widget.data.language == 'system') {
              widget.data.language = Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'lt';
              widget.onChanged();
            }
            setState(() => step = 1);
          },
          child: Text(tx(context, 'Pradėti', 'Get started')),
        ),
      ],
    ),
  );

  Widget _benefit(IconData icon, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, color: green),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );

  Widget _stepPage(BuildContext context, {required int number, required String title, required String subtitle, required List<Widget> children}) => ListView(
    key: ValueKey('onboarding-$number'),
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
    children: [
      Row(children: [
        IconButton(onPressed: busy ? null : () => setState(() => step--), icon: const Icon(Icons.arrow_back)),
        const MediBoxLogo(size: 42),
        const SizedBox(width: 10),
        const Expanded(child: Text('MediBox', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: navy))),
        Text('$number/6', style: const TextStyle(color: Color(0xff60747f))),
      ]),
      const SizedBox(height: 24),
      Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: navy)),
      const SizedBox(height: 8),
      Text(subtitle, style: const TextStyle(fontSize: 16, color: Color(0xff48606f))),
      const SizedBox(height: 20),
      ...children,
    ],
  );

  Widget _permissions(BuildContext context) => _stepPage(
    context,
    number: 2,
    title: tx(context, 'Sutikimai ir leidimai', 'Permissions and consent'),
    subtitle: tx(context, 'Kiekvieną pasirinkimą valdote atskirai. Juos bet kada pakeisite profilyje.', 'You control every choice separately and can change it later in your profile.'),
    children: [
      card(Column(children: [
        _benefit(Icons.camera_alt_outlined, tx(context, 'Kamera vaistų fotografavimui', 'Camera for medicine photos')),
        _benefit(Icons.medication_outlined, tx(context, 'Vaistų priminimai', 'Medicine reminders')),
        _benefit(Icons.event_outlined, tx(context, 'Vizitų priminimai', 'Appointment reminders')),
        _benefit(Icons.auto_awesome, 'Firebase AI / Gemini'),
      ])),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy ? null : () async {
          final saved = await _showPermissionsCenter(context, widget.data, firstLaunch: true);
          if (saved && mounted) setState(() => step = 2);
        },
        child: Text(tx(context, 'Pasirinkti leidimus', 'Choose permissions')),
      ),
    ],
  );

  Widget _account(BuildContext context) {
    final account = CloudSyncService.instance.user;
    return _stepPage(
      context,
      number: 3,
      title: tx(context, 'Google paskyra', 'Google account'),
      subtitle: tx(context, 'Prisijungus vaistinėlė, profiliai, nuotraukos, priminimai ir vizitai sinchronizuosis tarp įrenginių.', 'Sign in to sync the cabinet, profiles, photos, reminders and appointments across devices.'),
      children: [
        card(Row(children: [
          CircleAvatar(backgroundColor: mint, child: Icon(account == null ? Icons.cloud_off_outlined : Icons.cloud_done_outlined, color: green)),
          const SizedBox(width: 14),
          Expanded(child: Text(account == null ? tx(context, 'Dar neprisijungta', 'Not signed in yet') : (account.email ?? account.displayName ?? ''), style: const TextStyle(fontWeight: FontWeight.w700))),
        ])),
        if (error.isNotEmpty) ...[const SizedBox(height: 10), Text(error, style: const TextStyle(color: Colors.red))],
        const SizedBox(height: 16),
        if (account == null)
          FilledButton.icon(
            onPressed: busy ? null : () async {
              setState(() { busy = true; error = ''; });
              try {
                await CloudSyncService.instance.signIn(widget.data, onRemoteApplied: () async => widget.onChanged());
                _reloadProfileControllers();
                if (mounted) setState(() => step = 3);
              } catch (e) {
                if (mounted) setState(() => error = CloudSyncService.instance.readableError(e));
              } finally {
                if (mounted) setState(() => busy = false);
              }
            },
            icon: const Icon(Icons.account_circle_outlined),
            label: Text(tx(context, 'Prisijungti su Google', 'Sign in with Google')),
          )
        else
          FilledButton(onPressed: () => setState(() => step = 3), child: Text(tx(context, 'Tęsti', 'Continue'))),
        TextButton(onPressed: busy ? null : () => setState(() => step = 3), child: Text(tx(context, 'Kol kas praleisti', 'Skip for now'))),
      ],
    );
  }

  Widget _profile(BuildContext context) => _stepPage(
    context,
    number: 4,
    title: tx(context, 'Mano profilis', 'My profile'),
    subtitle: tx(context, 'Vardas būtinas. Kita informacija padės tiksliau priskirti vaistus ir priminimus.', 'Your name is required. Other details help assign medicines and reminders correctly.'),
    children: [
      field(context, name, 'Vardas', 'Name'),
      dateField(context, birth, 'Gimimo data YYYY-MM-DD', 'Date of birth YYYY-MM-DD'),
      DropdownButtonFormField<String>(
        initialValue: gender,
        decoration: InputDecoration(labelText: tx(context, 'Lytis', 'Gender')),
        items: [
          DropdownMenuItem(value: 'female', child: Text(tx(context, 'Moteris', 'Female'))),
          DropdownMenuItem(value: 'male', child: Text(tx(context, 'Vyras', 'Male'))),
          DropdownMenuItem(value: 'unspecified', child: Text(tx(context, 'Nenurodyta', 'Not specified'))),
        ],
        onChanged: (value) => setState(() => gender = value!),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: field(context, height, 'Ūgis (cm)', 'Height (cm)', number: true)),
        const SizedBox(width: 10),
        Expanded(child: field(context, weight, 'Svoris (kg)', 'Weight (kg)', number: true)),
      ]),
      field(context, phone, 'Telefonas', 'Phone'),
      field(context, email, 'El. paštas', 'Email'),
      field(context, blood, 'Kraujo grupė', 'Blood type'),
      field(context, allergies, 'Alergijos', 'Allergies', lines: 2),
      field(context, conditions, 'Sveikatos būklės', 'Medical conditions', lines: 2),
      field(context, medications, 'Nuolat vartojami arba netoleruojami vaistai', 'Regular or intolerant medicines', lines: 2),
      field(context, emergencyName, 'Skubios pagalbos kontaktas', 'Emergency contact'),
      field(context, emergencyPhone, 'Kontakto telefonas', 'Emergency phone'),
      FilledButton(onPressed: () {
        if (name.text.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tx(context, 'Įrašykite savo vardą.', 'Enter your name.'))));
          return;
        }
        _saveSelf();
        setState(() => step = 4);
      }, child: Text(tx(context, 'Išsaugoti ir tęsti', 'Save and continue'))),
    ],
  );

  void _saveSelf() {
    final profile = widget.data.profile;
    profile
      ..name = name.text.trim()
      ..birthDate = birth.text.trim()
      ..phone = phone.text.trim()
      ..email = email.text.trim()
      ..bloodType = blood.text.trim()
      ..allergies = allergies.text.trim()
      ..conditions = conditions.text.trim()
      ..medications = medications.text.trim()
      ..emergencyName = emergencyName.text.trim()
      ..emergencyPhone = emergencyPhone.text.trim();
    final own = widget.data.members.where((member) => member.relation == 'self');
    final member = own.isNotEmpty ? own.first : Member(id: newId(), name: '', relation: 'self');
    member
      ..name = profile.name
      ..relation = 'self'
      ..gender = gender
      ..ageGroup = 'adult'
      ..birthDate = profile.birthDate
      ..height = height.text.trim()
      ..weight = weight.text.trim()
      ..bloodType = profile.bloodType
      ..allergies = profile.allergies
      ..conditions = profile.conditions
      ..intolerantMedicines = profile.medications;
    if (own.isEmpty) widget.data.members.add(member);
    widget.data.linkedMemberId = member.id;
    widget.onChanged();
  }

  Widget _family(BuildContext context) => _stepPage(
    context,
    number: 5,
    title: tx(context, 'Šeimos nariai', 'Family members'),
    subtitle: tx(context, 'Ar norite dabar pridėti kitą šeimos narį? Galėsite pridėti tiek, kiek reikia.', 'Would you like to add another family member now? You can add as many as needed.'),
    children: [
      ...widget.data.members.where((member) => member.relation != 'self').map((member) => ListTile(
        leading: const CircleAvatar(backgroundColor: mint, child: Icon(Icons.person, color: green)),
        title: Text(member.name),
        subtitle: Text(relationName(context, member.relation)),
      )),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: () async {
          if (!await requirePremium(context) || !context.mounted) return;
          await Navigator.push(context, MaterialPageRoute(builder: (_) => MemberEditor(data: widget.data, initialRelation: 'child', onChanged: widget.onChanged)));
          if (mounted) setState(() {});
        },
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(tx(context, 'Pridėti šeimos narį', 'Add family member')),
      ),
      OutlinedButton(onPressed: () => setState(() => step = 5), child: Text(tx(context, 'Tęsti', 'Continue'))),
    ],
  );

  Widget _sharing(BuildContext context) => _stepPage(
    context,
    number: 6,
    title: tx(context, 'Kaip naudosite „MediBox“?', 'How will you use MediBox?'),
    subtitle: tx(context, 'Galite naudotis vienas arba sukurti bendrą namų ūkio vaistinėlę. Tai visada pakeisite nustatymuose.', 'Use it privately or share a household cabinet. You can change this later in settings.'),
    children: [
      card(Column(children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(backgroundColor: mint, child: Icon(Icons.person_outline, color: green)),
          title: Text(tx(context, 'Naudotis tik man', 'Use only for me')),
          subtitle: Text(tx(context, 'Duomenys lieka asmeninėje erdvėje', 'Data stays in your personal space')),
          trailing: const Icon(Icons.chevron_right),
          onTap: _finish,
        ),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(backgroundColor: mint, child: Icon(Icons.family_restroom, color: green)),
          title: Text(tx(context, 'Šeimos bendrinimas', 'Family sharing')),
          subtitle: Text(tx(context, 'Sukurti namų ūkį arba įvesti kvietimo kodą', 'Create a household or enter an invite code')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            if (!await requirePremium(context) || !context.mounted) return;
            if (CloudSyncService.instance.user == null) {
              setState(() => step = 2);
              return;
            }
            await Navigator.push(context, MaterialPageRoute(builder: (_) => HouseholdSettingsPage(data: widget.data, onChanged: widget.onChanged)));
            if (widget.data.householdId.isNotEmpty) _finish();
          },
        ),
      ])),
    ],
  );

  void _finish() {
    widget.data.onboarded = true;
    widget.onChanged();
  }
}

class Shell extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const Shell({super.key, required this.data, required this.onChanged});
  State<Shell> createState() => _Shell();
}

class RoleAvatar extends StatelessWidget {
  final String type;
  const RoleAvatar({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    if (type == 'shared') {
      return const CircleAvatar(
        radius: 27,
        backgroundColor: mint,
        child: Icon(Icons.home_rounded, color: green, size: 30),
      );
    }
    final face = switch (type) {
      'child' => '👦',
      'family' => '👵',
      _ => '👩',
    };
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: mint,
        border: Border.all(color: const Color(0xffb9e5d9), width: 2),
      ),
      child: Center(child: Text(face, style: const TextStyle(fontSize: 31))),
    );
  }
}

class _Shell extends State<Shell> {
  int index = 0;
  String selectedMemberId = '';
  DateTime? calendarInitialDate;
  String calendarInitialMemberId = '';
  int calendarRequestVersion = 0;

  void _openCalendar(DateTime date, String memberId) {
    setState(() {
      calendarInitialDate = date;
      calendarInitialMemberId = memberId;
      calendarRequestVersion++;
      index = 4;
    });
  }

  @override
  Widget build(c) {
    final d = widget.data;
    final pages = [
      HomePage(
        data: d,
        onChanged: widget.onChanged,
        memberId: selectedMemberId,
        onMemberChanged: (value) => setState(() => selectedMemberId = value),
        onOpenCalendar: _openCalendar,
      ),
      CabinetPage(data: d, onChanged: widget.onChanged),
      SymptomsPage(data: d, onChanged: widget.onChanged),
      FamilyPage(data: d, onChanged: widget.onChanged),
      HealthCalendarPage(
        key: ValueKey('calendar-$calendarRequestVersion'),
        data: d,
        onChanged: widget.onChanged,
        initialDate: calendarInitialDate,
        initialMemberId: calendarInitialMemberId,
      ),
    ];
    return Scaffold(
      backgroundColor: const Color(0xfff6fbfa),
      body: ColoredBox(
        color: const Color(0xfff6fbfa),
        child: SafeArea(child: pages[index]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) async {
          if (v == 3 && !await requirePremium(c)) return;
          if (mounted) setState(() => index = v);
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            label: tx(c, 'Pradžia', 'Home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.medication_outlined),
            label: tx(c, 'Vaistinėlė', 'Medicine'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.health_and_safety_outlined),
            label: tx(c, 'Man bloga', 'Symptoms'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            label: tx(c, 'Šeima', 'Family'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.calendar_month_outlined),
            label: tx(c, 'Kalendorius', 'Calendar'),
          ),
        ],
      ),
    );
  }
}

Widget card(Widget child) => Card(
  elevation: 0,
  color: Colors.white,
  child: Padding(padding: const EdgeInsets.all(16), child: child),
);
Widget title(String s) => Text(
  s,
  style: const TextStyle(
    fontSize: 28,
    height: 1.15,
    fontFamily: 'sans-serif',
    fontWeight: FontWeight.w700,
    color: navy,
    decoration: TextDecoration.none,
  ),
);

Future<bool> confirmDelete(BuildContext c, String item) async =>
    await showDialog<bool>(
      context: c,
      builder: (dialogContext) => AlertDialog(
        title: Text(tx(c, 'Patvirtinkite ištrynimą', 'Confirm deletion')),
        content: Text(
          tx(
            c,
            'Ar tikrai norite ištrinti „$item“? Šio veiksmo atšaukti nepavyks.',
            'Delete “$item”? This action cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tx(c, 'Atšaukti', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tx(c, 'Ištrinti', 'Delete')),
          ),
        ],
      ),
    ) ??
    false;

class HomePage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  final String memberId;
  final ValueChanged<String> onMemberChanged;
  final void Function(DateTime date, String memberId) onOpenCalendar;
  const HomePage({
    super.key,
    required this.data,
    required this.onChanged,
    this.memberId = '',
    required this.onMemberChanged,
    required this.onOpenCalendar,
  });

  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final today = dateKey(now);
    final active =
        data.reminders
            .where(
              (x) =>
                  reminderAppliesOn(x, now) &&
                  reminderMatchesMember(data, x, memberId),
            )
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final taken = active.where((x) => x.takenDates.contains(today)).length;
    final remaining = active.length - taken;
    final doseColors = active
        .map((reminder) => _doseStatusColor(
              reminder,
              now,
              reminder.takenDates.contains(today),
            ))
        .toList();
    final lowStockMeds = data.meds.where((medicine) {
      return (memberId.isEmpty ||
              medicine.memberIds.isEmpty ||
              medicine.memberIds.contains(memberId)) &&
          medicine.stock < medicine.lowStockThreshold;
    }).toList();
    final expiringMeds =
        data.meds
            .where(
              (x) =>
                  (memberId.isEmpty ||
                      x.memberIds.isEmpty ||
                      x.memberIds.contains(memberId)) &&
                  medicineNeedsExpiryAttention(x.expiry, now),
            )
            .toList()
          ..sort(
            (a, b) => (daysUntilMedicineExpiry(a.expiry, now) ?? 999999)
                .compareTo(daysUntilMedicineExpiry(b.expiry, now) ?? 999999),
          );
    final upcomingAppointments =
        data.appointments.where((item) {
          final at = DateTime.tryParse('${item.date}T${item.time}');
          return !item.completed &&
              at != null &&
              !at.isBefore(now) &&
              (memberId.isEmpty || item.memberId == memberId);
        }).toList()..sort(
          (a, b) => '${a.date}${a.time}'.compareTo('${b.date}${b.time}'),
        );
    final nextAppointment = upcomingAppointments.firstOrNull;
    final sameDayAppointments = nextAppointment == null
        ? <HealthAppointment>[]
        : upcomingAppointments
              .where((item) => item.date == nextAppointment.date)
              .toList();
    final selectedMemberName = memberId.isEmpty
        ? tx(c, 'Visa šeima', 'Whole family')
        : _memberName(data, memberId);

    return Stack(
      children: [
        Positioned.fill(
          child: Image.asset(
            'assets/images/medibox_home_background.webp',
            fit: BoxFit.cover,
          ),
        ),
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0xfff6fbfa).withValues(alpha: .88),
          ),
        ),
        ListView(
          padding: scrollPagePadding(c, horizontal: 16),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          accountDisplayName(data).isEmpty
                              ? tx(c, 'Labas! 👋', 'Hello! 👋')
                              : tx(
                                  c,
                                  'Labas, ${accountDisplayName(data)}! 👋',
                                  'Hello, ${accountDisplayName(data)}! 👋',
                                ),
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: navy,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _todayLabel(c, now),
                        style: const TextStyle(color: Color(0xff48606f)),
                      ),
                    ],
                  ),
                ),
                Badge(
                  isLabelVisible: remaining > 0,
                  label: Text('$remaining'),
                  child: IconButton(
                    tooltip: tx(c, 'Priminimai', 'Reminders'),
                    onPressed: () => Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) =>
                            ReminderRoutePage(data: data, onChanged: onChanged),
                      ),
                    ),
                    icon: const Icon(Icons.notifications_outlined, size: 28),
                  ),
                ),
                IconButton(
                  tooltip: tx(c, 'Mano profilis', 'My profile'),
                  onPressed: () => Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfilePage(data: data, onChanged: onChanged),
                    ),
                  ),
                  icon: const Icon(Icons.account_circle_outlined, size: 30),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (data.members.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text(tx(c, 'Visa šeima', 'Whole family')),
                      selected: memberId.isEmpty,
                      onSelected: (_) => onMemberChanged(''),
                    ),
                    const SizedBox(width: 7),
                    ...data.members.map(
                      (member) => Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: ChoiceChip(
                          avatar: Text(
                            _memberEmoji(member.gender, member.ageGroup),
                          ),
                          label: Text(member.name),
                          selected: memberId == member.id,
                          onSelected: (_) => onMemberChanged(member.id),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Card(
              color: Colors.white.withValues(alpha: .94),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xffe5efec)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 112,
                          height: 112,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox.expand(
                                child: CustomPaint(
                                  painter: _DoseProgressPainter(doseColors),
                                ),
                              ),
                              Text(
                                '$taken/${active.length}\n${tx(c, 'dozės\nišgertos', 'doses\ntaken')}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.05,
                                  fontWeight: FontWeight.w800,
                                  color: navy,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(54),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                ),
                                onPressed: () => Navigator.push(
                                  c,
                                  MaterialPageRoute(
                                    builder: (_) => ReminderRoutePage(
                                      data: data,
                                      onChanged: onChanged,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      tx(c, 'Rodyti visus', 'Show all'),
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.chevron_right_rounded),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tx(
                        c,
                        'Rodoma: $selectedMemberName',
                        'Showing: $selectedMemberName',
                      ),
                      style: const TextStyle(
                        color: Color(0xff526575),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              color: Colors.white.withValues(alpha: .96),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xffe5efec)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 6,
                ),
                child: Column(
                  children: [
                    if (active.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          tx(
                            c,
                            'Šiandien suplanuotų vaistų nėra.',
                            'No medicines scheduled today.',
                          ),
                        ),
                      ),
                    ...active.take(4).map((r) {
                      final isTaken = r.takenDates.contains(today);
                      return Column(
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 15,
                              height: 15,
                              decoration: BoxDecoration(
                                color: _doseStatusColor(r, now, isTaken),
                                shape: BoxShape.circle,
                              ),
                            ),
                            title: Row(
                              children: [
                                SizedBox(
                                  width: 72,
                                  child: Text(
                                    r.time,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      color: navy,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    r.title,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: navy,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: memberId.isEmpty &&
                                    data.householdId.isNotEmpty
                                ? Text(_who(data, r, tx(c, 'Aš', 'Me')))
                                : null,
                            trailing: IconButton(
                              tooltip: isTaken
                                  ? tx(
                                      c,
                                      'Pažymėti kaip neišgertą',
                                      'Mark as not taken',
                                    )
                                  : tx(
                                      c,
                                      'Pažymėti kaip išgertą',
                                      'Mark as taken',
                                    ),
                              onPressed: () {
                                if (isTaken) {
                                  undoDoseTaken(data, r, now);
                                } else {
                                  markDoseTaken(data, r, now);
                                }
                                onChanged();
                              },
                              icon: Icon(
                                isTaken
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: isTaken
                                    ? green
                                    : const Color(0xff7b8ba1),
                                size: 34,
                              ),
                            ),
                          ),
                          if (r != active.take(4).last)
                            const Divider(height: 1, color: Color(0xffe2e8ec)),
                        ],
                      );
                    }),
                    if (active.length > 4)
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
                        child: Text(
                          tx(
                            c,
                            'Dar ${active.length - 4} suplanuotos dozės',
                            '${active.length - 4} more scheduled doses',
                          ),
                          style: const TextStyle(
                            color: green,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (nextAppointment != null) ...[
              Card(
                color: appointmentBlueSoft,
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(
                      Icons.local_hospital_outlined,
                      color: appointmentBlue,
                    ),
                  ),
                  title: Text(
                    tx(c, 'Artimiausias vizitas', 'Next appointment'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: navy,
                    ),
                  ),
                  subtitle: Text(
                    [
                      '${nextAppointment.date} ${nextAppointment.time} • ${nextAppointment.title}',
                      [
                        _memberName(data, nextAppointment.memberId),
                        nextAppointment.doctor,
                        nextAppointment.facility,
                      ].where((value) => value.isNotEmpty).join(' • '),
                      if (sameDayAppointments.length > 1)
                        tx(
                          c,
                          'Rodyti visus ${sameDayAppointments.length} vizitus',
                          'View all ${sameDayAppointments.length} appointments',
                        ),
                    ].where((value) => value.isNotEmpty).join('\n'),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onOpenCalendar(
                    DateTime.tryParse(nextAppointment.date) ?? now,
                    memberId,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (lowStockMeds.isNotEmpty) ...[
              _medicineStatusCard(
                context: c,
                medicines: lowStockMeds,
                icon: Icons.warning_amber_rounded,
                color: const Color(0xffff9f1c),
                background: const Color(0xfffff3df),
                title: tx(c, 'Mažas vaistų likutis', 'Low medicine stock'),
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) =>
                        CabinetPage(data: data, onChanged: onChanged),
                  ),
                ),
                onMedicineTap: (medicine) => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => MedicinePage(
                      data: data,
                      med: medicine,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (expiringMeds.isNotEmpty) ...[
              _medicineStatusCard(
                context: c,
                medicines: expiringMeds,
                icon: Icons.event_busy_outlined,
                color: const Color(0xffe53935),
                background: const Color(0xffffe9e8),
                title: tx(
                  c,
                  '${expiringMeds.length} ${expiringMeds.length == 1 ? 'vaistas greitai baigs' : 'vaistai greitai baigs'} galioti',
                  '${expiringMeds.length} medicines expire soon',
                ),
                expiry: true,
                now: now,
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => ExpiringMedicinesPage(
                      data: data,
                      medicines: expiringMeds,
                      now: now,
                      onChanged: onChanged,
                    ),
                  ),
                ),
                onMedicineTap: (medicine) => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => MedicinePage(
                      data: data,
                      med: medicine,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) =>
                            ScanPage(data: data, onChanged: onChanged),
                      ),
                    ),
                    icon: const Icon(Icons.camera_alt),
                    label: Text(tx(c, 'Nuskenuoti vaistą', 'Scan medicine')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) =>
                            SymptomsPage(data: data, onChanged: onChanged),
                      ),
                    ),
                    icon: const Icon(Icons.health_and_safety),
                    label: Text(tx(c, 'Man bloga', 'I feel unwell')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _familyStatusCard(c, data, onChanged),
          ],
        ),
      ],
    );
  }
}

class _DoseProgressPainter extends CustomPainter {
  final List<Color> colors;
  const _DoseProgressPainter(this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - 12) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xffe1e8ec);
    canvas.drawCircle(center, radius, paint);
    if (colors.isEmpty) return;
    const full = 6.283185307179586;
    final gap = colors.length == 1 ? 0.0 : 0.045;
    final segment = full / colors.length;
    var start = -1.5707963267948966;
    for (final color in colors) {
      paint.color = color;
      canvas.drawArc(rect, start + gap / 2, segment - gap, false, paint);
      start += segment;
    }
  }

  @override
  bool shouldRepaint(covariant _DoseProgressPainter oldDelegate) =>
      oldDelegate.colors.length != colors.length ||
      oldDelegate.colors.join() != colors.join();
}

Color _doseStatusColor(Reminder reminder, DateTime now, bool isTaken) {
  if (isTaken) return green;
  final due = reminderDateTime(reminder, now);
  if (due != null && !due.isAfter(now)) return const Color(0xffef3e36);
  return const Color(0xffffb62e);
}

String _todayLabel(BuildContext context, DateTime date) {
  if (Localizations.localeOf(context).languageCode == 'en') {
    return DateFormat('EEEE, MMMM d').format(date);
  }
  const weekdays = [
    'pirmadienis',
    'antradienis',
    'trečiadienis',
    'ketvirtadienis',
    'penktadienis',
    'šeštadienis',
    'sekmadienis',
  ];
  const months = [
    'sausio',
    'vasario',
    'kovo',
    'balandžio',
    'gegužės',
    'birželio',
    'liepos',
    'rugpjūčio',
    'rugsėjo',
    'spalio',
    'lapkričio',
    'gruodžio',
  ];
  return 'Šiandien, ${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day} d.';
}

Widget _medicineStatusCard({
  required BuildContext context,
  required List<Med> medicines,
  required IconData icon,
  required Color color,
  required Color background,
  required String title,
  bool expiry = false,
  DateTime? now,
  VoidCallback? onTap,
  ValueChanged<Med>? onMedicineTap,
}) => InkWell(
  onTap: onTap,
  borderRadius: BorderRadius.circular(16),
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (onTap != null) Icon(Icons.chevron_right_rounded, color: color),
          ],
        ),
        const SizedBox(height: 8),
        ...medicines.take(4).map((medicine) {
          final days = expiry
              ? daysUntilMedicineExpiry(medicine.expiry, now!)
              : null;
          final detail = expiry
              ? _expiryDetail(context, medicine.expiry, days)
              : tx(
                  context,
                  'liko ${quantityLabel(medicine.stock)} ${doseUnitLabel(context, medicine.stockUnit)}',
                  '${quantityLabel(medicine.stock)} ${doseUnitLabel(context, medicine.stockUnit)} remaining',
                );
          return InkWell(
            onTap: onMedicineTap == null ? null : () => onMedicineTap(medicine),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${medicine.name} ${medicine.strength} — $detail',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: expiry && (days ?? 0) < 0
                            ? const Color(0xffb91c1c)
                            : navy,
                      ),
                    ),
                  ),
                  if (onMedicineTap != null)
                    const Icon(Icons.open_in_new_rounded, size: 16),
                ],
              ),
            ),
          );
        }),
        if (medicines.length > 4)
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 6, 4, 0),
            child: Text(
              tx(
                context,
                'Dar ${medicines.length - 4} vaistai',
                '${medicines.length - 4} more medicines',
              ),
              style: TextStyle(color: color, fontWeight: FontWeight.w800),
            ),
          ),
      ],
    ),
  ),
);

String _expiryDetail(BuildContext context, String expiry, int? days) {
  if (days == null) return expiry;
  if (days < 0) {
    return tx(context, 'galiojimas pasibaigė', 'expired');
  }
  if (days == 0) {
    return tx(context, 'galioja iki šiandien', 'expires today');
  }
  return tx(context, 'liko $days d.', '$days days left');
}

Widget _familyStatusCard(
  BuildContext context,
  AppData data,
  VoidCallback onChanged,
) => InkWell(
  borderRadius: BorderRadius.circular(16),
  onTap: () async {
    if (!await requirePremium(context) || !context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FamilyPage(data: data, onChanged: onChanged),
      ),
    );
  },
  child: Container(
    height: 82,
    padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
    decoration: BoxDecoration(
      color: const Color(0xffe2f6f1).withValues(alpha: .96),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        const Icon(Icons.groups_rounded, color: green, size: 31),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tx(
              context,
              'Šeimos narių: ${data.members.length}',
              'Family members: ${data.members.length}',
            ),
            style: const TextStyle(
              color: navy,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ),
        SizedBox(
          width: data.members.length > 3 ? 146 : 112,
          height: 52,
          child: Stack(
            children: [
              for (var i = 0; i < data.members.take(3).length; i++)
                Positioned(
                  left: i * 34,
                  child: _FamilyAvatar(
                    member: data.members[i],
                    fallbackIndex: i,
                  ),
                ),
              if (data.members.length > 3)
                Positioned(
                  left: 102,
                  child: Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: green,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Text(
                      '+${data.members.length - 3}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              if (data.members.isEmpty)
                for (var i = 0; i < 3; i++)
                  Positioned(
                    left: i * 34,
                    child: _FamilyAvatar(fallbackIndex: i),
                  ),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded, color: green),
      ],
    ),
  ),
);

class _FamilyAvatar extends StatelessWidget {
  final Member? member;
  final int fallbackIndex;
  const _FamilyAvatar({this.member, required this.fallbackIndex});

  @override
  Widget build(BuildContext context) {
    final imagePath = member?.imagePath ?? '';
    final face = member == null
        ? ['👨', '👩', '👦'][fallbackIndex % 3]
        : _memberEmoji(member!.gender, member!.ageGroup);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xffdff2fb),
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: imagePath.isNotEmpty
          ? Image.file(
              File(imagePath),
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Text(face, style: const TextStyle(fontSize: 27)),
            )
          : Text(face, style: const TextStyle(fontSize: 27)),
    );
  }
}

String _memberEmoji(String gender, String ageGroup) =>
    switch ((gender, ageGroup)) {
      ('female', 'child') => '👧',
      ('male', 'child') => '👦',
      (_, 'child') => '🧒',
      ('female', _) => '👩',
      ('male', _) => '👨',
      _ => '🧑',
    };

class ExpiringMedicinesPage extends StatefulWidget {
  final AppData data;
  final List<Med> medicines;
  final DateTime now;
  final VoidCallback onChanged;
  const ExpiringMedicinesPage({
    super.key,
    required this.data,
    required this.medicines,
    required this.now,
    required this.onChanged,
  });

  @override
  State<ExpiringMedicinesPage> createState() => _ExpiringMedicinesPageState();
}

class _ExpiringMedicinesPageState extends State<ExpiringMedicinesPage> {
  @override
  Widget build(BuildContext context) {
    final medicines = widget.medicines.where((medicine) {
      final stillExists = widget.data.meds.any(
        (item) => item.id == medicine.id,
      );
      return stillExists &&
          medicineNeedsExpiryAttention(medicine.expiry, widget.now);
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tx(context, 'Besibaigiantys vaistai', 'Expiring medicines'),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(18),
        itemCount: medicines.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final medicine = medicines[index];
          final days = daysUntilMedicineExpiry(medicine.expiry, widget.now);
          return Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xffffe9e8),
                child: Icon(
                  Icons.event_busy_outlined,
                  color: Color(0xffe53935),
                ),
              ),
              title: Text(
                '${medicine.name} ${medicine.strength}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                _expiryDetail(context, medicine.expiry, days),
                style: TextStyle(
                  color: (days ?? 0) < 0
                      ? const Color(0xffb91c1c)
                      : const Color(0xffc62828),
                  fontWeight: FontWeight.w700,
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MedicinePage(
                      data: widget.data,
                      med: medicine,
                      onChanged: widget.onChanged,
                    ),
                  ),
                );
                if (mounted) setState(() {});
              },
            ),
          );
        },
      ),
    );
  }
}

String _who(AppData d, Reminder r, String me) {
  if (r.memberId.isEmpty) {
    if (d.householdId.isNotEmpty && d.linkedMemberId.isNotEmpty) {
      final linkedName = _memberName(d, d.linkedMemberId);
      if (linkedName.isNotEmpty) return linkedName;
    }
    return me;
  }
  return d.members
          .where((x) => x.id == r.memberId)
          .map((x) => x.name)
          .firstOrNull ??
      me;
}

class CabinetPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const CabinetPage({super.key, required this.data, required this.onChanged});

  @override
  State<CabinetPage> createState() => _CabinetPageState();
}

class _CabinetPageState extends State<CabinetPage> {
  String selectedCategory = '';
  String sortOrder = 'name';
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _chooseAddMethod(BuildContext context) async {
    final method = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tx(
                  sheetContext,
                  'Kaip norite pridėti vaistą?',
                  'How would you like to add it?',
                ),
                style: const TextStyle(
                  color: navy,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => Navigator.pop(sheetContext, 'camera'),
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(
                  tx(
                    sheetContext,
                    'Fotografuoti arba nuskaityti',
                    'Photograph or scan',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(sheetContext, 'manual'),
                icon: const Icon(Icons.edit_note_outlined),
                label: Text(tx(sheetContext, 'Įvesti ranka', 'Enter manually')),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || method == null) return;
    if (method == 'manual') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              MedicineEditor(data: widget.data, onChanged: widget.onChanged),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScanPage(
            data: widget.data,
            onChanged: widget.onChanged,
            openCameraImmediately: true,
          ),
        ),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(c) {
    final categories =
        widget.data.meds
            .expand((medicine) => _splitCategories(medicine.category))
            .toSet()
            .toList()
          ..sort();
    final activeCategory = categories.contains(selectedCategory)
        ? selectedCategory
        : '';
    final query = search.text.trim().toLowerCase();
    final medicines =
        (activeCategory.isEmpty
                ? widget.data.meds
                : widget.data.meds
                      .where(
                        (medicine) =>
                            _splitCategories(medicine.category)
                                .contains(activeCategory),
                      )
                      .toList())
            .where(
              (medicine) =>
                  query.isEmpty ||
                  '${medicine.name} ${medicine.substance} ${medicine.purpose} ${medicine.barcode}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort(
            (a, b) => switch (sortOrder) {
              'expiry' => a.expiry.compareTo(b.expiry),
              'stock' => a.stock.compareTo(b.stock),
              _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            },
          );
    return ColoredBox(
      color: const Color(0xfff6fbfa),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          MediaQuery.paddingOf(c).bottom + 36,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: title(tx(c, 'Mano vaistinėlė', 'My medicine cabinet')),
              ),
              const SizedBox(width: 12),
              IconButton.filled(
                onPressed: () => _chooseAddMethod(c),
                tooltip: tx(c, 'Pridėti vaistą', 'Add medicine'),
                style: IconButton.styleFrom(
                  backgroundColor: green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(52, 52),
                ),
                icon: const Icon(Icons.add_rounded, size: 30),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: tx(c, 'Ieškoti vaisto', 'Search medicines'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: sortOrder,
            decoration: InputDecoration(
              labelText: tx(c, 'Rikiavimas', 'Sort by'),
            ),
            items: [
              DropdownMenuItem(
                value: 'name',
                child: Text(tx(c, 'Pagal pavadinimą', 'Name')),
              ),
              DropdownMenuItem(
                value: 'expiry',
                child: Text(tx(c, 'Pagal galiojimą', 'Expiry')),
              ),
              DropdownMenuItem(
                value: 'stock',
                child: Text(tx(c, 'Pagal likutį', 'Stock')),
              ),
            ],
            onChanged: (value) => setState(() => sortOrder = value!),
          ),
          const SizedBox(height: 12),
          if (categories.isNotEmpty) ...[
            Text(
              tx(c, 'Filtruoti pagal kategoriją', 'Filter by category'),
              style: const TextStyle(
                fontSize: 16,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: navy,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(tx(c, 'Visi', 'All')),
                    selected: activeCategory.isEmpty,
                    onSelected: (_) => setState(() => selectedCategory = ''),
                  ),
                  const SizedBox(width: 8),
                  ...categories.map(
                    (category) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(category),
                        selected: activeCategory == category,
                        onSelected: (_) =>
                            setState(() => selectedCategory = category),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tx(c, 'Rasta: ${medicines.length}', 'Found: ${medicines.length}'),
              style: const TextStyle(
                fontSize: 14,
                height: 1.25,
                color: Color(0xff526572),
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (medicines.isEmpty)
            card(
              Text(
                tx(
                  c,
                  'Šioje kategorijoje vaistų nėra.',
                  'There are no medicines in this category.',
                ),
              ),
            ),
          ...medicines.map((m) {
            final days = daysUntilMedicineExpiry(m.expiry, DateTime.now());
            final expiryColor = days != null && days < 0
                ? const Color(0xffb91c1c)
                : days != null && days <= 7
                ? const Color(0xffd97706)
                : green;
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () async {
                  await Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => MedicinePage(
                        data: widget.data,
                        med: m,
                        onChanged: widget.onChanged,
                      ),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _medicineImage(m, size: 72),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${m.name} ${m.strength}'.trim(),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: navy,
                              ),
                            ),
                            if (m.substance.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(m.substance),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 7,
                              runSpacing: 6,
                              children: [
                                _medicinePill(
                                  Icons.inventory_2_outlined,
                                  tx(
                                    c,
                                    '${quantityLabel(m.stock)} ${doseUnitLabel(c, m.stockUnit)}',
                                    '${quantityLabel(m.stock)} ${doseUnitLabel(c, m.stockUnit)} left',
                                  ),
                                  green,
                                ),
                                if (m.expiry.isNotEmpty)
                                  _medicinePill(
                                    Icons.event_outlined,
                                    _expiryDetail(c, m.expiry, days),
                                    expiryColor,
                                  ),
                                if (m.prescription)
                                  _medicinePill(
                                    Icons.receipt_long_outlined,
                                    tx(c, 'Receptinis', 'Prescription'),
                                    navy,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

Widget _medicineImage(Med medicine, {double size = 56}) {
  final file = medicine.imagePath.isEmpty ? null : File(medicine.imagePath);
  if (file != null && file.existsSync()) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _medicinePlaceholder(size),
      ),
    );
  }
  return _medicinePlaceholder(size);
}

Widget _medicinePlaceholder(double size) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: mint,
    borderRadius: BorderRadius.circular(14),
  ),
  child: const Icon(Icons.medication_rounded, color: green, size: 31),
);

Widget _medicinePill(IconData icon, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .10),
    borderRadius: BorderRadius.circular(999),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 5),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  ),
);

class GroundingSearchWidget extends StatefulWidget {
  final String html;
  const GroundingSearchWidget({super.key, required this.html});
  State<GroundingSearchWidget> createState() => _GroundingSearchWidgetState();
}

class _GroundingSearchWidgetState extends State<GroundingSearchWidget> {
  late final WebViewController controller;
  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (request.isMainFrame && request.url != 'about:blank') {
              launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadHtmlString(widget.html);
  }
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 130,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: WebViewWidget(controller: controller),
    ),
  );
}

class MedicineAiPage extends StatefulWidget {
  final AppData data;
  final Med medicine;
  final String initialQuestion;
  const MedicineAiPage({super.key, required this.data, required this.medicine, this.initialQuestion = ''});
  State<MedicineAiPage> createState() => _MedicineAiPageState();
}

class _MedicineAiPageState extends State<MedicineAiPage> {
  final question = TextEditingController();
  MedicineAiAnswer? answer;
  bool busy = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuestion.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ask(widget.initialQuestion));
    }
  }

  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> ask([String? suggested]) async {
    if (!SubscriptionService.instance.hasPremium) {
      await requirePremium(context);
      return;
    }
    final value = (suggested ?? question.text).trim().isEmpty
        ? tx(
            context,
            'Trumpai paaiškink, kam skirtas šis vaistas, kaip jį saugiai vartoti ir į ką atkreipti dėmesį.',
            'Briefly explain what this medicine is for, how to use it safely, and what to watch for.',
          )
        : (suggested ?? question.text).trim();
    if (busy) return;
    // Automatically generated patient context is sent to AI but never exposed
    // in the editable question field.
    if (suggested == null) question.text = value;
    setState(() { busy = true; error = ''; answer = null; });
    try {
      if (widget.data.aiConsentGranted &&
          SubscriptionService.instance.hasPremium &&
          AiMedicineProfileService.needsInformation(widget.medicine)) {
        try {
          if (await AiMedicineProfileService.populate(widget.medicine)) await Store.save(widget.data);
        } catch (_) { /* The advisor may still answer from available data. */ }
      }
      if (!mounted) return;
      final result = await AiMedicineAdvisorService.ask(
        medicine: widget.medicine,
        question: value,
        language: Localizations.localeOf(context).languageCode,
      );
      if (mounted) setState(() => answer = result);
    } catch (_) {
      if (mounted) {
        setState(() {
          answer = AiMedicineAdvisorService.localFallback(
            widget.medicine,
            question: value,
            language: Localizations.localeOf(context).languageCode,
          );
          error = tx(
            context,
            'AI atsakymo šiuo metu gauti nepavyko. Žemiau – tik išsaugoti kortelės duomenys, ne AI įvertinimas.',
            'The AI could not answer right now. Below is saved card information only, not an AI assessment.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tx(context, 'AI apie vaistą', 'Medicine AI'))),
    body: ListView(
      padding: scrollPagePadding(context),
      children: [
        Text('${widget.medicine.name} ${widget.medicine.strength}'.trim(),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(tx(context,
          'Klauskite paprastai. AI tikrina dabartinę interneto informaciją ir rodo šaltinius.',
          'Ask naturally. AI checks current web information and shows sources.')),
        if (widget.initialQuestion.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Pateikiame aiškų paaiškinimą ir svarbiausius perspėjimus.'),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          ActionChip(label: Text(tx(context, 'Kam skirtas?', 'What is it for?')),
              onPressed: busy ? null : () => ask('Kam skirtas šis vaistas ir ką svarbiausia apie jį žinoti?')),
          ActionChip(label: Text(tx(context, 'Įspėjimai', 'Warnings')),
              onPressed: busy ? null : () => ask('Kokie svarbiausi įspėjimai, kontraindikacijos ir sąveikos?')),
          ActionChip(label: Text(tx(context, 'Kaip vartojamas?', 'How is it used?')),
              onPressed: busy ? null : () => ask('Paaiškink, kaip šis vaistas paprastai vartojamas, nekurdamas dozės.')),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: question,
          minLines: 2,
          maxLines: 5,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: tx(context, 'Klausimas apie vaistą', 'Question about the medicine'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => ask(),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: busy ? null : ask,
          icon: const Icon(Icons.auto_awesome), label: Text(tx(context, 'Klausti AI', 'Ask AI'))),
        if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(error, style: const TextStyle(color: Color(0xff526572)))),
        if (answer != null) ...[
          const SizedBox(height: 16),
          card(Text(answer!.text)),
          if (answer!.searchHtml.isNotEmpty) ...[
            Text(tx(context, 'Google paieška', 'Google Search'),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            GroundingSearchWidget(html: answer!.searchHtml),
          ],
          if (answer!.sourceUrls.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(tx(context, 'Interneto šaltiniai', 'Web sources'),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ...List.generate(answer!.sourceUrls.length, (i) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.open_in_new, color: green),
              title: Text(i < answer!.sourceTitles.length
                  ? answer!.sourceTitles[i] : answer!.sourceUrls[i]),
              onTap: () => launchUrl(Uri.parse(answer!.sourceUrls[i]),
                  mode: LaunchMode.externalApplication),
            )),
          ],
          const Text('AI informacija gali klysti. Skubiu atveju skambinkite 112; dėl gydymo kreipkitės į gydytoją arba vaistininką.'),
        ],
      ],
    ),
  );
}

class MedicinePage extends StatefulWidget {
  final AppData data;
  final Med med;
  final VoidCallback onChanged;
  const MedicinePage({
    super.key,
    required this.data,
    required this.med,
    required this.onChanged,
  });
  @override
  State<MedicinePage> createState() => _MedicinePageState();
}

class _MedicinePageState extends State<MedicinePage> {
  AppData get data => widget.data;
  Med get med => widget.med;
  VoidCallback get onChanged => widget.onChanged;
  bool filling = false;
  String fillMessage = '';

  @override
  void initState() {
    super.initState();
    if (data.aiConsentGranted &&
        SubscriptionService.instance.hasPremium &&
        AiMedicineProfileService.needsInformation(med)) {
      filling = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillInformation());
    }
  }

  Future<void> _fillInformation() async {
    try {
      final changed = await AiMedicineProfileService.populate(med);
      if (!mounted || !data.meds.contains(med)) return;
      if (changed) onChanged();
    } catch (error) {
      debugPrint('Medicine lookup: ${FirebaseLeafletService.readableError(error)}');
      if (mounted) fillMessage = 'Informacijos šiuo metu gauti nepavyko.';
    } finally {
      if (mounted) setState(() => filling = false);
    }
  }

  @override
  Widget build(c) {
    final weeklyUse = data.reminders
        .where((item) => item.enabled && item.medId == med.id)
        .fold<double>(
          0,
          (total, item) => total + item.quantityPerDose * item.weekdays.length,
        );
    final dailyUse = weeklyUse / 7;
    final daysRemaining = dailyUse > 0 ? (med.stock / dailyUse).floor() : null;
    final estimatedEnd = daysRemaining == null
        ? null
        : DateTime.now().add(Duration(days: daysRemaining));
    return StatefulBuilder(
      builder: (c, setPageState) => DefaultTabController(
        length: 5,
        child: Scaffold(
          backgroundColor: const Color(0xfff6fbfa),
          appBar: AppBar(
            title: Text(med.name),
            actions: [
              IconButton(
                tooltip: tx(c, 'Redaguoti', 'Edit'),
                onPressed: () async {
                  await Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => MedicineEditor(
                        data: data,
                        medicine: med,
                        onChanged: onChanged,
                      ),
                    ),
                  );
                  setPageState(() {});
                },
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                onPressed: () async {
                  if (!await confirmDelete(c, med.name) || !c.mounted) return;
                  data.meds.removeWhere((x) => x.id == med.id);
                  data.reminders.removeWhere((x) => x.medId == med.id);
                  onChanged();
                  Navigator.pop(c);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
            bottom: TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: tx(c, 'Apžvalga', 'Overview')),
                Tab(text: tx(c, 'Vartojimas', 'Use')),
                Tab(text: tx(c, 'Įspėjimai', 'Warnings')),
                Tab(text: tx(c, 'Sąveikos', 'Interactions')),
                Tab(text: tx(c, 'Daugiau', 'More')),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  if (filling) ...[
                    const LinearProgressIndicator(),
                    const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Pildoma vaisto informacija…')),
                  ],
                  if (fillMessage.isNotEmpty) Text(fillMessage),
                  SizedBox(
                    height: 210,
                    width: double.infinity,
                    child:
                        med.imagePath.isNotEmpty &&
                            File(med.imagePath).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Image.file(
                              File(med.imagePath),
                              fit: BoxFit.cover,
                            ),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: mint,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(
                              Icons.medication_rounded,
                              color: green,
                              size: 78,
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => MedicineEditor(
                            data: data,
                            medicine: med,
                            onChanged: onChanged,
                          ),
                        ),
                      );
                      setPageState(() {});
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(
                      tx(c, 'Redaguoti vaisto kortelę', 'Edit medicine card'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: data.aiConsentGranted
                        ? () async {
                            if (!await requirePremium(c) || !c.mounted) return;
                            await Navigator.push(
                              c,
                              MaterialPageRoute(
                                builder: (_) => MedicineAiPage(
                                  data: data,
                                  medicine: med,
                                  initialQuestion:
                                      'Paaiškink šį vaistą: kam jis skirtas, kaip vartojamas ir į ką svarbiausia atkreipti dėmesį.',
                                ),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      tx(c, 'AI paaiškina vaistą', 'AI explains this medicine'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${med.name} ${med.strength}',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${tx(c, 'Veiklioji medžiaga', 'Active ingredient')}: ${med.substance}',
                        ),
                        Chip(
                          label: Text(
                            med.prescription
                                ? tx(c, 'Receptinis', 'Prescription')
                                : tx(c, 'Nereceptinis', 'Non-prescription'),
                          ),
                        ),
                        if (med.registryVerified)
                          const Chip(
                            avatar: Icon(
                              Icons.verified_rounded,
                              size: 18,
                              color: green,
                            ),
                            label: Text('Patikrinta VVKT'),
                          ),
                        const Divider(),
                        Text(med.information('purpose', Localizations.localeOf(c).languageCode)),
                        if (med.manufacturer.isNotEmpty)
                          Text(
                            '${tx(c, 'Gamintojas', 'Manufacturer')}: ${med.manufacturer}',
                          ),
                        if (med.dosageForm.isNotEmpty)
                          Text(
                            '${tx(c, 'Vaisto forma', 'Dosage form')}: ${med.dosageForm}',
                          ),
                        if (med.category.isNotEmpty)
                          Text(
                            '${tx(c, 'Kategorija', 'Category')}: ${med.category}',
                          ),
                      ],
                    ),
                  ),
                  MedicinePriceCard(medicine: med),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          final today = data.reminders
                              .where(
                                (item) =>
                                    item.medId == med.id &&
                                    reminderAppliesOn(item, DateTime.now()) &&
                                    !item.takenDates.contains(dateKey()),
                              )
                              .firstOrNull;
                          if (today == null) {
                            ScaffoldMessenger.of(c).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tx(
                                    c,
                                    'Šiandien nepažymėtų dozių nėra.',
                                    'No untaken doses today.',
                                  ),
                                ),
                              ),
                            );
                            return;
                          }
                          markDoseTaken(data, today, DateTime.now());
                          onChanged();
                          setPageState(() {});
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(tx(c, 'Išgėriau', 'Taken')),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => Navigator.push(
                          c,
                          MaterialPageRoute(
                            builder: (_) => ReminderEditor(
                              data: data,
                              initialMedId: med.id,
                              onChanged: onChanged,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.add_alarm),
                        label: Text(tx(c, 'Priminimas', 'Reminder')),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          if (!data.shopping.any(
                            (item) => item.medId == med.id && !item.purchased,
                          )) {
                            data.shopping.add(
                              ShoppingItem(
                                id: newId(),
                                medId: med.id,
                                name: '${med.name} ${med.strength}'.trim(),
                                prescription: med.prescription,
                              ),
                            );
                            onChanged();
                          }
                          ScaffoldMessenger.of(c).showSnackBar(
                            SnackBar(
                              content: Text(
                                tx(
                                  c,
                                  'Įtraukta į pirkinių sąrašą.',
                                  'Added to shopping list.',
                                ),
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.add_shopping_cart),
                        label: Text(tx(c, 'Pirkti', 'Buy')),
                      ),
                    ],
                  ),
                  card(
                    Column(
                      children: [
                        Text(
                          '${tx(c, 'Likutis', 'Stock')}: ${quantityLabel(med.stock)} ${doseUnitLabel(c, med.stockUnit)}',
                        ),
                        Text(
                          '${tx(c, 'Perspėjimo riba', 'Warning threshold')}: ${quantityLabel(med.lowStockThreshold)}',
                        ),
                        if (daysRemaining != null)
                          Text(
                            tx(
                              c,
                              'Pagal priminimus užteks maždaug $daysRemaining d. (iki ${DateFormat('yyyy-MM-dd').format(estimatedEnd!)})',
                              'Based on reminders, about $daysRemaining days remain (until ${DateFormat('yyyy-MM-dd').format(estimatedEnd)})',
                            ),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: med.stock > 0
                                  ? () {
                                      med.stock--;
                                      onChanged();
                                    }
                                  : null,
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            IconButton(
                              onPressed: () {
                                med.stock++;
                                onChanged();
                              },
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                        Text(
                          '${tx(c, 'Galioja iki', 'Expires')}: ${med.expiry}',
                        ),
                        if (med.prescriptionValidUntil.isNotEmpty)
                          Text(
                            '${tx(c, 'Receptas galioja iki', 'Prescription valid until')}: ${med.prescriptionValidUntil}',
                          ),
                        if (med.treatmentUntil.isNotEmpty)
                          Text(
                            '${tx(c, 'Vaisto turi užtekti iki', 'Medicine should last until')}: ${med.treatmentUntil}',
                          ),
                        if (med.batchNumber.isNotEmpty)
                          Text(
                            '${tx(c, 'Partijos numeris', 'Batch number')}: ${med.batchNumber}',
                          ),
                        if (med.barcode.isNotEmpty)
                          Text(
                            '${tx(c, 'Brūkšninis kodas', 'Barcode')}: ${med.barcode}',
                          ),
                        if (med.storageLocation.isNotEmpty)
                          Text(
                            '${tx(c, 'Laikymo vieta', 'Storage location')}: ${med.storageLocation}',
                          ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              c,
                              MaterialPageRoute(
                                builder: (_) => MedicineInventoryPage(
                                  medicine: med,
                                  onChanged: onChanged,
                                ),
                              ),
                            );
                            setPageState(() {});
                          },
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: Text(
                            tx(
                              c,
                              'Pakuotės ir laikymo vietos',
                              'Packages and storage',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.health_and_safety_outlined,
                          color: green,
                          size: 30,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tx(
                            c,
                            'Vartojimas pasirinktam asmeniui',
                            'Use for a selected person',
                          ),
                          style: const TextStyle(
                            color: navy,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tx(
                            c,
                            'Peržiūrėkite kortelėje ir lapelyje įrašytą vartojimą, asmens svorį bei svarbius perspėjimus.',
                            'Review the recorded and leaflet directions, the person\'s weight, and important warnings.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => Navigator.push(
                            c,
                            MaterialPageRoute(
                              builder: (_) => PersonalizedMedicineGuidancePage(
                                data: data,
                                medicine: med,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.person_search_outlined),
                          label: Text(
                            tx(c, 'Rodyti patarimus', 'Show guidance'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (med.leafletRecord != null &&
                      med.leafletRecord!.identity.matches(
                        LeafletIdentity(med.name, med.strength, med.dosageForm),
                      ))
                    LeafletRecordCard(record: med.leafletRecord!),
                  if (med.leaflet.isNotEmpty || med.notes.isNotEmpty)
                    card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (med.leaflet.isNotEmpty)
                            Text(
                              '${tx(c, 'Informacinis lapelis', 'Leaflet')}: ${med.leaflet}',
                            ),
                          if (med.notes.isNotEmpty) ...[
                            if (med.leaflet.isNotEmpty) const Divider(),
                            Text('${tx(c, 'Pastabos', 'Notes')}: ${med.notes}'),
                          ],
                        ],
                      ),
                    ),
                  if (med.aiSourceUrls.isNotEmpty)
                    card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tx(c, 'AI naudoti interneto šaltiniai', 'Web sources used by AI'),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          if (med.aiUpdatedAt.length >= 10)
                            Text('${tx(c, 'Atnaujinta', 'Updated')}: ${med.aiUpdatedAt.substring(0, 10)}'),
                          ...List.generate(med.aiSourceUrls.length, (i) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(i < med.aiSourceTitles.length
                                ? med.aiSourceTitles[i] : med.aiSourceUrls[i]),
                            trailing: const Icon(Icons.open_in_new),
                            onTap: () => launchUrl(Uri.parse(med.aiSourceUrls[i]),
                                mode: LaunchMode.externalApplication),
                          )),
                        ],
                      ),
                    ),
                ],
              ),
              _medicineSectionsTab(c, [
                (tx(c, 'Kaip vartoti?', 'How to use?'), med.information('dosage', Localizations.localeOf(c).languageCode)),
                (
                  tx(c, 'Priminimai', 'Reminders'),
                  data.reminders
                      .where((r) => r.medId == med.id)
                      .map(
                        (r) =>
                            '${r.time} — ${r.dose} ${doseUnitLabel(context, r.doseUnit)}'
                                .trim(),
                      )
                      .join('\n'),
                ),
              ]),
              _medicineSectionsTab(c, [
                (tx(c, 'Svarbu žinoti', 'Important'), med.information('warnings', Localizations.localeOf(c).languageCode)),
                (
                  tx(c, 'Dažnesni šalutiniai poveikiai', 'Common side effects'),
                  med.information('sideEffects', Localizations.localeOf(c).languageCode),
                ),
              ]),
              _medicineSectionsTab(c, [
                (
                  tx(
                    c,
                    'Sąveikos su kitais vaistais',
                    'Interactions with medicines',
                  ),
                  med.information('interactions', Localizations.localeOf(c).languageCode),
                ),
              ]),
              _medicineSectionsTab(c, [
                (tx(c, 'Pakuotės dydis', 'Package size'), med.packageSize),
                (tx(c, 'Gamintojas', 'Manufacturer'), med.manufacturer),
                (tx(c, 'ATC kodas', 'ATC code'), med.atcCode),
                (
                  tx(c, 'Registracijos numeris', 'Registration number'),
                  med.registrationNumber,
                ),
                (tx(c, 'Tiekimo būsena', 'Supply status'), med.supplyStatus),
                (tx(c, 'Informacinis lapelis', 'Package leaflet'), med.leaflet),
                (tx(c, 'Pastabos', 'Notes'), med.notes),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class PersonalizedMedicineGuidancePage extends StatefulWidget {
  final AppData data;
  final Med medicine;
  const PersonalizedMedicineGuidancePage({
    super.key,
    required this.data,
    required this.medicine,
  });

  @override
  State<PersonalizedMedicineGuidancePage> createState() =>
      _PersonalizedMedicineGuidancePageState();
}

class _PersonalizedMedicineGuidancePageState
    extends State<PersonalizedMedicineGuidancePage> {
  late String selectedMemberId;

  @override
  void initState() {
    super.initState();
    final assigned = widget.data.members
        .where((member) => widget.medicine.memberIds.contains(member.id))
        .toList();
    selectedMemberId = assigned.isNotEmpty
        ? assigned.first.id
        : (widget.data.members.isNotEmpty ? widget.data.members.first.id : '');
  }

  int? _age(String value) {
    final birth = DateTime.tryParse(value);
    if (birth == null) return null;
    final now = DateTime.now();
    var years = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      years--;
    }
    return years >= 0 ? years : null;
  }

  bool _mentionsMedicine(String value) {
    final text = value.toLowerCase();
    if (text.trim().isEmpty) return false;
    final candidates = <String>{
      widget.medicine.name.toLowerCase().trim(),
      widget.medicine.substance.toLowerCase().trim(),
    }.where((item) => item.length >= 4);
    return candidates.any(text.contains);
  }

  Future<void> _openLeaflet(BuildContext context) async {
    final uri = Uri.tryParse(widget.medicine.leaflet.trim());
    if (uri == null || !uri.hasScheme || !await launchUrl(uri)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tx(
              context,
              'Nepavyko atidaryti informacinio lapelio nuorodos.',
              'The package leaflet link could not be opened.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.data.members;
    final member = members
        .where((item) => item.id == selectedMemberId)
        .firstOrNull;
    final medicine = widget.medicine;
    final age = member == null ? null : _age(member.birthDate);
    final allergyAlert =
        member != null &&
        (_mentionsMedicine(member.allergies) ||
            _mentionsMedicine(member.intolerantMedicines));
    final doseGuidance = member == null
        ? null
        : calculateDoseGuidance(medicine, member);
    return Scaffold(
      backgroundColor: const Color(0xfff6fbfa),
      appBar: AppBar(
        title: Text(tx(context, 'Vartojimo patarimai', 'Use guidance')),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          MediaQuery.paddingOf(context).bottom + 30,
        ),
        children: [
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${medicine.name} ${medicine.strength}'.trim(),
                  style: const TextStyle(
                    color: navy,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (medicine.substance.isNotEmpty)
                  Text(
                    '${tx(context, 'Veiklioji medžiaga', 'Active ingredient')}: ${medicine.substance}',
                  ),
                if (medicine.dosageForm.isNotEmpty)
                  Text(
                    '${tx(context, 'Forma', 'Form')}: ${medicine.dosageForm}',
                  ),
              ],
            ),
          ),
          if (members.isEmpty)
            card(
              Text(
                tx(
                  context,
                  'Pirmiausia sukurkite šeimos narį ir jo kortelėje įrašykite amžių, svorį bei alergijas.',
                  'First create a family member and record age, weight, and allergies in their profile.',
                ),
              ),
            )
          else ...[
            Text(
              tx(
                context,
                'Kam skirtas patarimas?',
                'Who is this guidance for?',
              ),
              style: const TextStyle(
                color: navy,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: members
                  .map(
                    (item) => ChoiceChip(
                      selected: selectedMemberId == item.id,
                      onSelected: (_) =>
                          setState(() => selectedMemberId = item.id),
                      avatar: Text(_memberEmoji(item.gender, item.ageGroup)),
                      label: Text(item.name),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member!.name,
                    style: const TextStyle(
                      color: navy,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    [
                      member.ageGroup == 'child'
                          ? tx(context, 'Vaikas', 'Child')
                          : tx(context, 'Suaugęs', 'Adult'),
                      if (age != null) tx(context, '$age m.', 'Age $age'),
                      if (member.weight.trim().isNotEmpty)
                        '${member.weight.trim()} kg',
                    ].join(' • '),
                  ),
                  if (member.weight.trim().isEmpty)
                    Text(
                      tx(
                        context,
                        'Svoris neįvestas asmens kortelėje.',
                        'Weight is missing from the profile.',
                      ),
                      style: const TextStyle(
                        color: Colors.deepOrange,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            if (allergyAlert)
              Card(
                color: const Color(0xffffe8e8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tx(
                            context,
                            'Dėmesio: asmens alergijų arba netoleruojamų vaistų įraše aptiktas šio vaisto pavadinimas ar veiklioji medžiaga. Nevartokite nepasitarę su gydytoju ar vaistininku.',
                            'Warning: this medicine or its active ingredient appears in the person\'s allergy or intolerance record. Do not use it without consulting a doctor or pharmacist.',
                          ),
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(context, 'Kaip vartoti', 'How to use'),
                  style: const TextStyle(
                    color: navy,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  medicine.dosage.trim().isEmpty
                      ? tx(
                          context,
                          'Vartojimo informacija kortelėje neįvesta. Vadovaukitės receptu ir oficialiu informaciniu lapeliu.',
                          'No use directions are recorded. Follow the prescription and official package leaflet.',
                        )
                      : medicine.dosage.trim(),
                ),
                const SizedBox(height: 10),
                if (doseGuidance != null && !allergyAlert) ...[
                  const Divider(),
                  Text(
                    tx(
                      context,
                      'Pagal patvirtintą lapelio taisyklę',
                      'From the approved leaflet rule',
                    ),
                    style: const TextStyle(
                      color: green,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '${quantityLabel(doseGuidance.doseMg)} mg'
                    '${doseGuidance.volumeMl == null ? '' : ' • ${quantityLabel(doseGuidance.volumeMl!)} ml'}'
                    '${doseGuidance.units == null ? '' : ' • ${quantityLabel(doseGuidance.units!)} ${tx(context, 'vnt.', 'units')}'}',
                    style: const TextStyle(
                      color: navy,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (doseGuidance.intervalHours != null)
                    Text(
                      tx(
                        context,
                        'Ne dažniau kaip kas ${quantityLabel(doseGuidance.intervalHours!)} val.',
                        'Not more often than every ${quantityLabel(doseGuidance.intervalHours!)} hours.',
                      ),
                    ),
                  if (doseGuidance.maxDailyMg != null)
                    Text(
                      tx(
                        context,
                        'Didžiausia paros dozė: ${quantityLabel(doseGuidance.maxDailyMg!)} mg.',
                        'Maximum daily dose: ${quantityLabel(doseGuidance.maxDailyMg!)} mg.',
                      ),
                    ),
                  Text(
                    tx(
                      context,
                      'Šaltinis: ${doseGuidance.source}',
                      'Source: ${doseGuidance.source}',
                    ),
                  ),
                ] else
                  Text(
                    tx(
                      context,
                      'Dozė neskaičiuojama, kol nėra su oficialiu lapeliu palygintos struktūrizuotos taisyklės, tikslaus svorio arba yra alergijos įspėjimas.',
                      'A dose is not calculated without a structured rule checked against the official leaflet, an exact weight, or when an allergy warning exists.',
                    ),
                    style: const TextStyle(color: Color(0xff5b6870)),
                  ),
              ],
            ),
          ),
          if (medicine.warnings.isNotEmpty || medicine.interactions.isNotEmpty)
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx(
                      context,
                      'Svarbu prieš vartojant',
                      'Important before use',
                    ),
                    style: const TextStyle(
                      color: navy,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (medicine.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(medicine.warnings),
                  ],
                  if (medicine.interactions.isNotEmpty) ...[
                    const Divider(),
                    Text(
                      '${tx(context, 'Sąveikos', 'Interactions')}: ${medicine.interactions}',
                    ),
                  ],
                ],
              ),
            ),
          if (medicine.leaflet.trim().isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => _openLeaflet(context),
              icon: const Icon(Icons.description_outlined),
              label: Text(
                tx(
                  context,
                  'Atidaryti oficialų lapelį',
                  'Open official leaflet',
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            tx(
              context,
              'Ši informacija yra pagalbinė ir nepakeičia gydytojo, vaistininko, recepto ar oficialaus informacinio lapelio nurodymų.',
              'This information is supportive and does not replace advice from a doctor or pharmacist, the prescription, or the official package leaflet.',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff5b6870), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class MedicineInventoryPage extends StatefulWidget {
  final Med medicine;
  final VoidCallback onChanged;
  const MedicineInventoryPage({
    super.key,
    required this.medicine,
    required this.onChanged,
  });
  @override
  State<MedicineInventoryPage> createState() => _MedicineInventoryPageState();
}

class _MedicineInventoryPageState extends State<MedicineInventoryPage> {
  Future<void> _addBatch() async {
    final quantity = TextEditingController();
    final expiry = TextEditingController();
    final batch = TextEditingController();
    final location = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tx(context, 'Pridėti pakuotę', 'Add package')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(context, quantity, 'Kiekis', 'Quantity', number: true),
              dateField(
                context,
                expiry,
                'Galioja iki YYYY-MM-DD',
                'Expiry YYYY-MM-DD',
              ),
              field(context, batch, 'Partijos numeris', 'Batch number'),
              field(context, location, 'Laikymo vieta', 'Storage location'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tx(context, 'Atšaukti', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(
                quantity.text.replaceAll(',', '.'),
              );
              if (parsed == null || parsed <= 0) return;
              widget.medicine.batches.add(
                MedicineStockBatch(
                  id: newId(),
                  quantity: parsed,
                  expiry: expiry.text.trim(),
                  batchNumber: batch.text.trim(),
                  storageLocation: location.text.trim(),
                ),
              );
              widget.medicine.stock = widget.medicine.batches.fold(
                0,
                (total, item) => total + item.quantity,
              );
              widget.onChanged();
              Navigator.pop(dialogContext);
              setState(() {});
            },
            child: Text(tx(context, 'Išsaugoti', 'Save')),
          ),
        ],
      ),
    );
    quantity.dispose();
    expiry.dispose();
    batch.dispose();
    location.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tx(context, 'Vaisto pakuotės', 'Medicine packages')),
    ),
    body: ListView(
      padding: scrollPagePadding(context),
      children: [
        card(
          Text(
            '${widget.medicine.name} ${widget.medicine.strength}\n'
            '${tx(context, 'Bendras likutis', 'Total stock')}: ${quantityLabel(widget.medicine.stock)} ${doseUnitLabel(context, widget.medicine.stockUnit)}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        if (widget.medicine.batches.isEmpty)
          card(
            Text(
              tx(
                context,
                'Atskiros pakuotės dar nesuvestos. Dabartinis bendras likutis išsaugotas.',
                'No individual packages yet. The current total stock is preserved.',
              ),
            ),
          ),
        ...widget.medicine.batches.map(
          (item) => Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.inventory_2_outlined, color: green),
              ),
              title: Text(
                '${quantityLabel(item.quantity)} ${doseUnitLabel(context, widget.medicine.stockUnit)}',
              ),
              subtitle: Text(
                [
                  if (item.expiry.isNotEmpty)
                    '${tx(context, 'Galioja iki', 'Expires')}: ${item.expiry}',
                  if (item.batchNumber.isNotEmpty)
                    '${tx(context, 'Partija', 'Batch')}: ${item.batchNumber}',
                  if (item.storageLocation.isNotEmpty)
                    '${tx(context, 'Vieta', 'Location')}: ${item.storageLocation}',
                ].join('\n'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  widget.medicine.batches.remove(item);
                  widget.medicine.stock = widget.medicine.batches.fold(
                    0,
                    (total, batch) => total + batch.quantity,
                  );
                  widget.onChanged();
                  setState(() {});
                },
              ),
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: _addBatch,
          icon: const Icon(Icons.add),
          label: Text(tx(context, 'Pridėti pakuotę', 'Add package')),
        ),
      ],
    ),
  );
}

Widget _medicineSectionsTab(BuildContext c, List<(String, String)> sections) =>
    ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(c).bottom + 28,
      ),
      children: sections
          .map(
            (section) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.$1,
                      style: const TextStyle(
                        color: navy,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      section.$2.trim().isEmpty
                          ? tx(
                              c,
                              'Informacija dar neįvesta.',
                              'Information has not been entered yet.',
                            )
                          : section.$2.trim(),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );

class MedicineEditor extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  final String sourceText;
  final String initialImagePath;
  final String initialMemberId;
  final Med? medicine;
  final VvktMedicine? registryMedicine;
  const MedicineEditor({
    super.key,
    required this.data,
    required this.onChanged,
    this.sourceText = '',
    this.initialImagePath = '',
    this.initialMemberId = '',
    this.medicine,
    this.registryMedicine,
  });
  State<MedicineEditor> createState() => _MedicineEditor();
}

class _MedicineEditor extends State<MedicineEditor> {
  late final name = TextEditingController(
        text:
            widget.medicine?.name ??
            widget.registryMedicine?.name ??
            _guessName(widget.sourceText),
      ),
      sub = TextEditingController(
        text:
            widget.medicine?.substance ??
            widget.registryMedicine?.substance ??
            '',
      ),
      strength = TextEditingController(
        text:
            widget.medicine?.strength ??
            widget.registryMedicine?.strength ??
            _guessStrength(widget.sourceText),
      ),
      manufacturer = TextEditingController(
        text:
            widget.medicine?.manufacturer ??
            widget.registryMedicine?.registrant ??
            '',
      ),
      dosageForm = TextEditingController(
        text:
            widget.medicine?.dosageForm ??
            widget.registryMedicine?.dosageForm ??
            '',
      ),
      packageSize = TextEditingController(
        text:
            widget.medicine?.packageSize ??
            widget.registryMedicine?.packageDescription ??
            _guessPackageSize(widget.sourceText),
      ),
      purpose = TextEditingController(text: _initialInfo('purpose')),
      dosage = TextEditingController(text: _initialInfo('dosage')),
      warnings = TextEditingController(text: _initialInfo('warnings')),
      sideEffects = TextEditingController(
        text: _initialInfo('sideEffects'),
      ),
      interactions = TextEditingController(
        text: _initialInfo('interactions'),
      ),
      expiry = TextEditingController(
        text:
            widget.medicine?.expiry ??
            MedicineMatcher.expiry(widget.sourceText) ??
            '',
      ),
      prescriptionValidUntil = TextEditingController(
        text: widget.medicine?.prescriptionValidUntil ?? '',
      ),
      treatmentUntil = TextEditingController(text: widget.medicine?.treatmentUntil ?? ''),
      stock = TextEditingController(text: quantityLabel(widget.medicine?.stock ?? 1)),
      lowStockThreshold = TextEditingController(text: quantityLabel(widget.medicine?.lowStockThreshold ?? 10)),
      batchNumber = TextEditingController(text: widget.medicine?.batchNumber ?? ''),
      barcode = TextEditingController(text: widget.medicine?.barcode ?? ''),
      storageLocation = TextEditingController(text: widget.medicine?.storageLocation ?? ''),
      leaflet = TextEditingController(text: widget.medicine?.leaflet ?? ''),
      doseMgPerKg = TextEditingController(text: widget.medicine?.doseMgPerKg ?? ''),
      doseFixedMg = TextEditingController(text: widget.medicine?.doseFixedMg ?? ''),
      doseMaxSingleMg = TextEditingController(text: widget.medicine?.doseMaxSingleMg ?? ''),
      doseMaxDailyMg = TextEditingController(text: widget.medicine?.doseMaxDailyMg ?? ''),
      doseIntervalHours = TextEditingController(text: widget.medicine?.doseIntervalHours ?? ''),
      concentrationMgPerMl = TextEditingController(text: widget.medicine?.concentrationMgPerMl ?? ''),
      unitStrengthMg = TextEditingController(text: widget.medicine?.unitStrengthMg ?? ''),
      doseRuleSource = TextEditingController(text: widget.medicine?.doseRuleSource ?? ''),
      notes = TextEditingController(text: widget.medicine?.notes ?? '');
  late bool prescription =
      widget.medicine?.prescription ??
      (widget.registryMedicine?.prescriptionStatus.toLowerCase() ==
          'receptinis');
  late bool doseRuleVerified = widget.medicine?.doseRuleVerified ?? false;
  late String stockUnit =
      widget.medicine?.stockUnit ??
      suggestedMedicineQuantityUnit(
        widget.registryMedicine?.dosageForm ?? '',
      );
  late final Set<String> selectedCategories = {
    ..._splitCategories(widget.medicine?.category ?? ''),
    if (widget.medicine == null)
      ..._suggestMedicineCategories(
        widget.registryMedicine?.atcCode ?? '',
        '${widget.registryMedicine?.name ?? ''} ${widget.registryMedicine?.substance ?? ''} ${widget.sourceText}',
      ),
  };
  late final Set<String> selectedMemberIds = {
    ...?widget.medicine?.memberIds,
    if (widget.initialMemberId.isNotEmpty) widget.initialMemberId,
  };
  final newCategory = TextEditingController();
  Timer? _vvktDebounce;
  bool _applyingVvkt = false;
  bool _vvktSearchBusy = false;
  bool _aiProfileBusy = false;
  String _aiProfileMessage = '';
  String _lastAiRegistration = '';
  String _vvktSearchError = '';
  List<VvktMedicine> _vvktSearchResults = [];
  late VvktMedicine? _registryMedicine = widget.registryMedicine;
  late String imagePath = widget.medicine?.imagePath ?? widget.initialImagePath;
  late String expiryMode = expiry.text.length == 10 ? 'day' : 'month';
  late LeafletRecord? _leafletRecord = widget.medicine?.leafletRecord;
  late List<String> _aiSourceTitles = [...?widget.medicine?.aiSourceTitles];
  late List<String> _aiSourceUrls = [...?widget.medicine?.aiSourceUrls];
  late String _aiSearchHtml = widget.medicine?.aiSearchHtml ?? '';
  late String _aiUpdatedAt = widget.medicine?.aiUpdatedAt ?? '';
  late Map<String, Map<String, String>> _aiLocalized = widget.medicine?.aiLocalized ?? {};
  String _initialInfo(String field) => widget.medicine?.information(
    field, Localizations.localeOf(context).languageCode) ?? '';

  @override
  void initState() {
    super.initState();
    name.addListener(_scheduleVvktSearch);
    final existing = widget.medicine;
    if (_registryMedicine == null && existing != null && existing.registryVerified) {
      _registryMedicine = AiMedicineProfileService.identity(existing);
    }
    if (widget.data.aiConsentGranted &&
        SubscriptionService.instance.hasPremium &&
        _registryMedicine != null &&
        (existing == null || AiMedicineProfileService.needsInformation(existing))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoFillProfile(_registryMedicine!);
      });
    }
    if (widget.medicine == null &&
        widget.registryMedicine == null &&
        name.text.trim().length >= 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleVvktSearch();
      });
    }
  }

  @override
  void dispose() {
    _vvktDebounce?.cancel();
    name.removeListener(_scheduleVvktSearch);
    for (final x in [
      name,
      sub,
      strength,
      manufacturer,
      dosageForm,
      packageSize,
      newCategory,
      purpose,
      dosage,
      warnings,
      sideEffects,
      interactions,
      expiry,
      prescriptionValidUntil,
      treatmentUntil,
      stock,
      lowStockThreshold,
      batchNumber,
      barcode,
      storageLocation,
      leaflet,
      notes,
      doseMgPerKg,
      doseFixedMg,
      doseMaxSingleMg,
      doseMaxDailyMg,
      doseIntervalHours,
      concentrationMgPerMl,
      unitStrengthMg,
      doseRuleSource,
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  void _scheduleVvktSearch() {
    if (_applyingVvkt) return;
    _vvktDebounce?.cancel();
    final query = name.text.trim();
    if (query.length < 3) {
      if (mounted) setState(() => _vvktSearchResults = []);
      return;
    }
    _vvktDebounce = Timer(
      const Duration(milliseconds: 650),
      () => _searchVvktByName(query),
    );
  }

  Future<void> _searchVvktByName(String query) async {
    if (!mounted || name.text.trim() != query) return;
    setState(() {
      _vvktSearchBusy = true;
      _vvktSearchError = '';
    });
    try {
      var results = await VvktService.search(query);
      if (results.isEmpty) {
        final variants = {
          query,
          _registryTitleCase(query),
          query.toUpperCase(),
        };
        for (final variant in variants) {
          results = await VvktService.searchByPrefix(variant);
          if (results.isNotEmpty) break;
        }
      }
      if (!mounted || name.text.trim() != query) return;
      final best = VvktService.bestMatch(results, strength.text);
      setState(() => _vvktSearchResults = results);
      if (best != null) _applyVvktMedicine(best);
    } catch (_) {
      if (mounted) {
        setState(() {
          _vvktSearchResults = [];
          _vvktSearchError = tx(
            context,
            'Nepavyko prisijungti prie VVKT.',
            'Could not connect to VVKT.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _vvktSearchBusy = false);
    }
  }

  void _applyVvktMedicine(VvktMedicine medicine) {
    _applyingVvkt = true;
    name.text = medicine.name;
    sub.text = medicine.substance;
    strength.text = medicine.strength;
    manufacturer.text = medicine.registrant;
    dosageForm.text = medicine.dosageForm;
    if (widget.medicine == null) {
      stockUnit = suggestedMedicineQuantityUnit(medicine.dosageForm);
    }
    packageSize.text = medicine.packageDescription;
    prescription = medicine.prescriptionStatus.toLowerCase() == 'receptinis';
    if (dosage.text.trim().isEmpty && medicine.administrationRoute.isNotEmpty) {
      dosage.text =
          '${tx(context, 'Vartojimo būdas', 'Administration route')}: '
          '${medicine.administrationRoute}';
    }
    selectedCategories.remove('Kita');
    selectedCategories.addAll(
      _suggestMedicineCategories(
        medicine.atcCode,
        '${medicine.name} ${medicine.substance}',
      ),
    );
    _registryMedicine = medicine;
    _applyingVvkt = false;
    if (mounted) setState(() {});
    if (widget.data.aiConsentGranted && SubscriptionService.instance.hasPremium) {
      _autoFillProfile(medicine);
    }
  }

  Future<void> _autoFillProfile(VvktMedicine medicine) async {
    if (_aiProfileBusy ||
        _lastAiRegistration == medicine.registrationNumber ||
        !FirebaseLeafletService.supported)
      return;
    _lastAiRegistration = medicine.registrationNumber;
    setState(() {
      _aiProfileBusy = true;
      _aiProfileMessage = tx(
        context,
        'AI pildo vaisto kortelę…',
        'AI is filling the medicine card…',
      );
    });
    try {
      final profile = await AiMedicineProfileService.generate(
        medicine: medicine,
        recognizedPackageText: widget.sourceText,
      );
      if (!mounted ||
          _registryMedicine?.registrationNumber != medicine.registrationNumber)
        return;
      void fill(TextEditingController target, String value) {
        if (target.text.trim().isEmpty && value.trim().isNotEmpty) {
          target.text = value.trim();
        }
      }
      final values =
          profile.localized[Localizations.localeOf(context).languageCode] ??
              profile.fields;
      final downloadedImage = imagePath.isEmpty && profile.imageUrl.isNotEmpty
          ? await MedicineImageService.fetchAndStore(
              imageUrl: profile.imageUrl,
              identity:
                  '${medicine.registrationNumber}-${medicine.name}-${medicine.strength}',
            )
          : null;
      if (!mounted ||
          _registryMedicine?.registrationNumber != medicine.registrationNumber) {
        return;
      }
      setState(() {
        fill(purpose, values['purpose'] ?? '');
        if (dosage.text.startsWith('Vartojimo būdas:') ||
            dosage.text.startsWith('Administration route:')) {
          if ((values['dosage'] ?? '').isNotEmpty) dosage.text = values['dosage']!;
        } else {
          fill(dosage, values['dosage'] ?? '');
        }
        fill(warnings, values['warnings'] ?? '');
        fill(sideEffects, values['sideEffects'] ?? '');
        fill(interactions, values['interactions'] ?? '');
        fill(storageLocation, values['storage'] ?? '');
        selectedCategories.addAll(profile.categories);
        _aiSourceTitles = profile.sourceTitles;
        _aiSourceUrls = profile.sourceUrls;
        _aiLocalized = profile.localized;
        _aiSearchHtml = profile.searchHtml;
        if (leaflet.text.trim().isEmpty && profile.sourceUrls.isNotEmpty) {
          leaflet.text = profile.sourceUrls.first;
        }
        _aiUpdatedAt = DateTime.now().toUtc().toIso8601String();
        if (downloadedImage != null) imagePath = downloadedImage;
        _aiProfileMessage = tx(
          context,
          'Kortelės informacija užpildyta automatiškai. Patikrinkite ir išsaugokite.',
          'Card information was filled automatically. Review and save.',
        );
      });
    } catch (_) {
      _lastAiRegistration = '';
      if (mounted)
        setState(
          () => _aiProfileMessage = tx(
            context,
            'Informacijos internete gauti nepavyko. Papildomi laukai dar neužpildyti.',
            'Online information could not be retrieved. Additional fields have not been filled.',
          ),
        );
    } finally {
      if (mounted) setState(() => _aiProfileBusy = false);
    }
  }

  Widget _vvktNameResults(BuildContext c) {
    if (_vvktSearchBusy) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: LinearProgressIndicator(),
      );
    }
    if (_vvktSearchError.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          _vvktSearchError,
          style: const TextStyle(color: Color(0xffb45309)),
        ),
      );
    }
    if (_vvktSearchResults.isEmpty) return const SizedBox.shrink();
    return Card(
      color: const Color(0xffe5f7f0),
      child: ExpansionTile(
        initiallyExpanded: _registryMedicine == null,
        leading: const Icon(Icons.verified_outlined, color: green),
        title: Text(
          tx(
            c,
            'VVKT rasta: ${_vvktSearchResults.length}',
            'VVKT results: ${_vvktSearchResults.length}',
          ),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: _registryMedicine == null
            ? null
            : Text('${_registryMedicine!.name} ${_registryMedicine!.strength}'),
        children: _vvktSearchResults
            .take(10)
            .map(
              (medicine) => ListTile(
                title: Text('${medicine.name} ${medicine.strength}'),
                subtitle: Text(
                  '${medicine.dosageForm} • ${medicine.packageDescription}',
                ),
                trailing:
                    medicine.registrationNumber ==
                        _registryMedicine?.registrationNumber
                    ? const Icon(Icons.check_circle, color: green)
                    : null,
                onTap: () => _applyVvktMedicine(medicine),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (source == ImageSource.camera &&
        !await _cameraAvailable(context, widget.data)) return;
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (picked == null) return;
    final directory = await getApplicationDocumentsDirectory();
    final extension = picked.path.contains('.')
        ? picked.path.split('.').last
        : 'jpg';
    final id = widget.medicine?.id ?? newId();
    final saved = await File(picked.path)
        .copy('${directory.path}/medicine_$id.$extension');
    final optimized = await MedicineImageService.optimizeLocal(
      saved.path,
      '${widget.medicine?.id ?? id}-${name.text}-${strength.text}',
    );
    if (mounted) setState(() => imagePath = optimized ?? saved.path);
  }

  Widget _categoryPicker(BuildContext c) {
    final categories = <String>{
      ...defaultMedicineCategories,
      ...widget.data.meds.expand((m) => _splitCategories(m.category)),
      ...selectedCategories,
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tx(c, 'Kategorijos', 'Categories'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: categories
              .map(
                (category) => FilterChip(
                  label: Text(category),
                  selected: selectedCategories.contains(category),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      if (category == 'Kita') {
                        selectedCategories.clear();
                      } else {
                        selectedCategories.remove('Kita');
                      }
                      selectedCategories.add(category);
                    } else {
                      selectedCategories.remove(category);
                    }
                  }),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(c, newCategory, 'Nauja kategorija', 'New category'),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: tx(c, 'Pridėti kategoriją', 'Add category'),
              onPressed: () {
                final value = newCategory.text.trim();
                if (value.isEmpty) return;
                setState(() {
                  selectedCategories.remove('Kita');
                  selectedCategories.add(value);
                  newCategory.clear();
                });
              },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  Widget _memberPicker(BuildContext c) {
    final medicineTerms = '${name.text} ${sub.text}'.toLowerCase();
    final warningsForMembers = widget.data.members.where((member) {
      if (!selectedMemberIds.contains(member.id)) return false;
      final risks = '${member.allergies} ${member.intolerantMedicines}'
          .toLowerCase()
          .split(RegExp(r'[,;\n]'))
          .map((value) => value.trim())
          .where((value) => value.length >= 3);
      return risks.any(medicineTerms.contains);
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.home_outlined, color: green),
          title: Text(
            tx(c, 'Bendra vaistinėlė', 'Shared medicine cabinet'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text(tx(
            c,
            'Vaistas visada saugomas bendroje vaistinėlėje',
            'Every medicine is always kept in the shared cabinet',
          )),
          trailing: const Icon(Icons.check_circle, color: green),
        ),
        if (widget.data.members.isNotEmpty) ...[
          Text(
            tx(c, 'Papildomai priskirti šeimos nariams', 'Also assign to family members'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
          spacing: 8,
          children: widget.data.members
              .map(
                (member) => FilterChip(
                  avatar: Text(_memberEmoji(member.gender, member.ageGroup)),
                  label: Text(member.name),
                  selected: selectedMemberIds.contains(member.id),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      selectedMemberIds.add(member.id);
                    } else {
                      selectedMemberIds.remove(member.id);
                    }
                  }),
                ),
              )
              .toList(),
          ),
        ],
        if (warningsForMembers.isNotEmpty)
          Card(
            color: const Color(0xffffe9e8),
            child: ListTile(
              leading: const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xffc62828),
              ),
              title: Text(
                tx(
                  c,
                  'Patikrinkite alergijas ir netoleravimą',
                  'Check allergies and intolerances',
                ),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                warningsForMembers.map((member) => member.name).join(', '),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.medicine == null
            ? tx(c, 'Pridėti vaistą', 'Add medicine')
            : tx(c, 'Redaguoti vaistą', 'Edit medicine'),
      ),
    ),
    backgroundColor: const Color(0xfff6fbfa),
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(c).bottom + 36,
      ),
      children: [
        if (imagePath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(imagePath),
                height: 190,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(tx(c, 'Fotografuoti', 'Take photo')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(tx(c, 'Galerija', 'Gallery')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        field(c, name, 'Pavadinimas', 'Name'),
        _vvktNameResults(c),
        field(c, sub, 'Veiklioji medžiaga', 'Active ingredient'),
        field(c, strength, 'Stiprumas', 'Strength'),
        field(c, manufacturer, 'Gamintojas', 'Manufacturer'),
        field(
          c,
          dosageForm,
          'Vaisto forma (tabletės, sirupas...)',
          'Dosage form',
        ),
        field(c, packageSize, 'Pakuotės dydis', 'Package size'),
        if (_aiProfileBusy) const LinearProgressIndicator(),
        if (_aiProfileMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _aiProfileMessage,
              style: const TextStyle(color: green),
            ),
          ),
        if (_aiSearchHtml.isNotEmpty) GroundingSearchWidget(html: _aiSearchHtml),
        if (_aiSourceUrls.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: const Icon(Icons.language, color: green),
            title: Text(tx(c, 'AI naudoti interneto šaltiniai', 'Web sources used by AI')),
            children: List.generate(_aiSourceUrls.length, (i) => ListTile(
              title: Text(i < _aiSourceTitles.length ? _aiSourceTitles[i] : _aiSourceUrls[i]),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(Uri.parse(_aiSourceUrls[i]), mode: LaunchMode.externalApplication),
            )),
          ),
        if (_leafletRecord != null) ...[
          LeafletRecordCard(record: _leafletRecord!),
          TextButton(
            onPressed: () => setState(() => _leafletRecord = null),
            child: Text(
              tx(c, 'Pašalinti lapelio ištraukas', 'Remove leaflet extracts'),
            ),
          ),
        ],
        _categoryPicker(c),
        _memberPicker(c),
        field(
          c,
          purpose,
          'Paskirtis / kam vartojamas',
          'Purpose / use',
          lines: 2,
        ),
        field(c, dosage, 'Kaip vartoti', 'How to use', lines: 3),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            tx(c, 'Patvirtinta dozavimo taisyklė', 'Approved dosing rule'),
          ),
          subtitle: Text(
            tx(
              c,
              'Naudojama tik skaičiavimui pagal oficialų lapelį',
              'Used only for calculation from an official leaflet',
            ),
          ),
          children: [
            field(
              c,
              doseMgPerKg,
              'Vienkartinė dozė mg/kg',
              'Single dose mg/kg',
              number: true,
            ),
            field(
              c,
              doseFixedMg,
              'Fiksuota vienkartinė dozė mg',
              'Fixed single dose mg',
              number: true,
            ),
            field(
              c,
              doseMaxSingleMg,
              'Didžiausia vienkartinė dozė mg',
              'Maximum single dose mg',
              number: true,
            ),
            field(
              c,
              doseMaxDailyMg,
              'Didžiausia paros dozė mg',
              'Maximum daily dose mg',
              number: true,
            ),
            field(
              c,
              doseIntervalHours,
              'Mažiausias intervalas valandomis',
              'Minimum interval in hours',
              number: true,
            ),
            field(
              c,
              concentrationMgPerMl,
              'Skysčio koncentracija mg/ml',
              'Liquid concentration mg/ml',
              number: true,
            ),
            field(
              c,
              unitStrengthMg,
              'Vienos tabletės / vieneto stiprumas mg',
              'Tablet / unit strength mg',
              number: true,
            ),
            field(
              c,
              doseRuleSource,
              'Oficialaus lapelio HTTPS nuoroda',
              'Official leaflet HTTPS URL',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: doseRuleVerified,
              onChanged: (value) => setState(() => doseRuleVerified = value),
              title: Text(
                tx(
                  c,
                  'Taisyklė palyginta su oficialiu lapeliu',
                  'Rule checked against official leaflet',
                ),
              ),
            ),
          ],
        ),
        field(c, warnings, 'Svarbūs įspėjimai', 'Important warnings', lines: 3),
        field(
          c,
          sideEffects,
          'Dažnesni šalutiniai poveikiai',
          'Common side effects',
          lines: 3,
        ),
        field(
          c,
          interactions,
          'Sąveikos su kitais vaistais',
          'Interactions',
          lines: 3,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tx(c, 'Receptinis vaistas', 'Prescription medicine')),
          value: prescription,
          onChanged: (value) => setState(() => prescription = value),
        ),
        Text(
          tx(c, 'Galiojimo datos tikslumas', 'Expiry date precision'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'month',
              label: Text(tx(c, 'Metai ir mėnuo', 'Year and month')),
            ),
            ButtonSegment(
              value: 'day',
              label: Text(tx(c, 'Tiksli diena', 'Exact day')),
            ),
          ],
          selected: {expiryMode},
          onSelectionChanged: (v) {
            setState(() {
              expiryMode = v.first;
              if (expiryMode == 'month' && expiry.text.length > 7) {
                expiry.text = expiry.text.substring(0, 7);
              }
            });
          },
        ),
        const SizedBox(height: 12),
        dateField(
          c,
          expiry,
          expiryMode == 'month'
              ? 'Galioja iki YYYY-MM'
              : 'Galioja iki YYYY-MM-DD',
          expiryMode == 'month' ? 'Expires YYYY-MM' : 'Expires YYYY-MM-DD',
          monthOnly: expiryMode == 'month',
        ),
        if (prescription)
          dateField(
            c,
            prescriptionValidUntil,
            'Receptas galioja iki YYYY-MM-DD',
            'Prescription valid until YYYY-MM-DD',
          ),
        dateField(
          c,
          treatmentUntil,
          'Vaisto turi užtekti iki YYYY-MM-DD',
          'Medicine should last until YYYY-MM-DD',
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(c, stock, 'Kiekis', 'Quantity', number: true),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(stockUnit),
                initialValue: stockUnit,
                decoration: InputDecoration(
                  labelText: tx(c, 'Likučio vienetas', 'Stock unit'),
                ),
                items: medicineQuantityUnits
                    .map(
                      (unit) => DropdownMenuItem(
                        value: unit,
                        child: Text(doseUnitLabel(c, unit)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => stockUnit = value!),
              ),
            ),
          ],
        ),
        field(
          c,
          lowStockThreshold,
          'Perspėti, kai lieka mažiau nei',
          'Warn when stock is below',
          number: true,
        ),
        field(c, batchNumber, 'Partijos numeris', 'Batch number'),
        field(c, barcode, 'Brūkšninis kodas', 'Barcode', number: true),
        field(c, storageLocation, 'Laikymo vieta', 'Storage location'),
        field(c, notes, 'Pastabos', 'Notes', lines: 3),
        if (widget.sourceText.isNotEmpty)
          ExpansionTile(
            title: Text(tx(c, 'Atpažintas tekstas', 'Recognized text')),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(widget.sourceText),
              ),
            ],
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty ||
                !_validDate(expiry.text, monthOnly: expiryMode == 'month') ||
                (prescriptionValidUntil.text.isNotEmpty &&
                    DateTime.tryParse(prescriptionValidUntil.text) == null) ||
                (treatmentUntil.text.isNotEmpty &&
                    DateTime.tryParse(treatmentUntil.text) == null)) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      c,
                      'Patikrink pavadinimą ir datų formatą.',
                      'Check the name and date formats.',
                    ),
                  ),
                ),
              );
              return;
            }
            if (doseRuleVerified &&
                (!isLeafletUrl(doseRuleSource.text) ||
                    (doseMgPerKg.text.trim().isEmpty &&
                        doseFixedMg.text.trim().isEmpty))) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      c,
                      'Patvirtintai dozavimo taisyklei reikia oficialios HTTPS '
                          'nuorodos ir mg/kg arba fiksuotos dozės.',
                      'An approved dosing rule needs an official HTTPS source and '
                          'either mg/kg or a fixed dose.',
                    ),
                  ),
                ),
              );
              return;
            }
            final parsedStock =
                double.tryParse(stock.text.trim().replaceAll(',', '.')) ?? 1;
            final parsedThreshold =
                double.tryParse(
                  lowStockThreshold.text.trim().replaceAll(',', '.'),
                ) ??
                10;
            final existing = widget.medicine;
            final leafletRecord =
                _leafletRecord?.identity.matches(
                      LeafletIdentity(
                        name.text,
                        strength.text,
                        dosageForm.text,
                      ),
                    ) ==
                    true
                ? _leafletRecord
                : null;
            if (existing == null) {
              widget.data.meds.add(
                Med(
                  id: newId(),
                  name: name.text.trim(),
                  substance: sub.text.trim(),
                  strength: strength.text.trim(),
                  purpose: purpose.text.trim(),
                  category: selectedCategories.isEmpty
                      ? 'Kita'
                      : selectedCategories.join('; '),
                  expiry: expiry.text.trim(),
                  prescriptionValidUntil: prescriptionValidUntil.text.trim(),
                  treatmentUntil: treatmentUntil.text.trim(),
                  stock: parsedStock,
                  stockUnit: stockUnit,
                  lowStockThreshold: parsedThreshold,
                  prescription: prescription,
                  leaflet: leaflet.text.trim(),
                  imagePath: imagePath,
                  manufacturer: manufacturer.text.trim(),
                  dosageForm: dosageForm.text.trim(),
                  packageSize: packageSize.text.trim(),
                  dosage: dosage.text.trim(),
                  warnings: warnings.text.trim(),
                  sideEffects: sideEffects.text.trim(),
                  interactions: interactions.text.trim(),
                  doseMgPerKg: doseMgPerKg.text.trim(),
                  doseFixedMg: doseFixedMg.text.trim(),
                  doseMaxSingleMg: doseMaxSingleMg.text.trim(),
                  doseMaxDailyMg: doseMaxDailyMg.text.trim(),
                  doseIntervalHours: doseIntervalHours.text.trim(),
                  concentrationMgPerMl: concentrationMgPerMl.text.trim(),
                  unitStrengthMg: unitStrengthMg.text.trim(),
                  doseRuleSource: doseRuleSource.text.trim(),
                  doseRuleVerified: doseRuleVerified,
                  atcCode: _registryMedicine?.atcCode ?? '',
                  registrationNumber:
                      _registryMedicine?.registrationNumber ?? '',
                  supplyStatus: _registryMedicine?.supplyStatus ?? '',
                  registryVerified: _registryMedicine != null,
                  leafletRecord: leafletRecord,
                  memberIds: selectedMemberIds.toList(),
                  batchNumber: batchNumber.text.trim(),
                  barcode: barcode.text.trim(),
                  storageLocation: storageLocation.text.trim(),
                  notes: notes.text.trim(),
                  aiSourceTitles: _aiSourceTitles,
                  aiSourceUrls: _aiSourceUrls,
                  aiSearchHtml: _aiSearchHtml,
                  aiLocalized: _aiLocalized,
                  aiUpdatedAt: _aiUpdatedAt,
                ),
              );
            } else {
              existing.memberIds = selectedMemberIds.toList();
              existing
                ..leafletRecord = leafletRecord
                ..name = name.text.trim()
                ..substance = sub.text.trim()
                ..strength = strength.text.trim()
                ..manufacturer = manufacturer.text.trim()
                ..dosageForm = dosageForm.text.trim()
                ..packageSize = packageSize.text.trim()
                ..category = (selectedCategories.isEmpty
                    ? 'Kita'
                    : selectedCategories.join('; '))
                ..purpose = purpose.text.trim()
                ..dosage = dosage.text.trim()
                ..warnings = warnings.text.trim()
                ..sideEffects = sideEffects.text.trim()
                ..interactions = interactions.text.trim()
                ..doseMgPerKg = doseMgPerKg.text.trim()
                ..doseFixedMg = doseFixedMg.text.trim()
                ..doseMaxSingleMg = doseMaxSingleMg.text.trim()
                ..doseMaxDailyMg = doseMaxDailyMg.text.trim()
                ..doseIntervalHours = doseIntervalHours.text.trim()
                ..concentrationMgPerMl = concentrationMgPerMl.text.trim()
                ..unitStrengthMg = unitStrengthMg.text.trim()
                ..aiSourceTitles = _aiSourceTitles
                ..aiSourceUrls = _aiSourceUrls
                ..aiSearchHtml = _aiSearchHtml
                ..aiLocalized = _aiLocalized
                ..aiUpdatedAt = _aiUpdatedAt
                ..doseRuleSource = doseRuleSource.text.trim()
                ..doseRuleVerified = doseRuleVerified
                ..atcCode = (_registryMedicine?.atcCode ?? existing.atcCode)
                ..registrationNumber =
                    (_registryMedicine?.registrationNumber ??
                    existing.registrationNumber)
                ..supplyStatus =
                    (_registryMedicine?.supplyStatus ?? existing.supplyStatus)
                ..registryVerified =
                    (existing.registryVerified || _registryMedicine != null)
                ..expiry = expiry.text.trim()
                ..prescriptionValidUntil = prescriptionValidUntil.text.trim()
                ..treatmentUntil = treatmentUntil.text.trim()
                ..stock = parsedStock
                ..stockUnit = stockUnit
                ..lowStockThreshold = parsedThreshold
                ..prescription = prescription
                ..batchNumber = batchNumber.text.trim()
                ..barcode = barcode.text.trim()
                ..storageLocation = storageLocation.text.trim()
                ..leaflet = leaflet.text.trim()
                ..notes = notes.text.trim()
                ..imagePath = imagePath;
            }
            widget.onChanged();
            Navigator.pop(c);
          },
          child: Text(tx(c, 'Išsaugoti', 'Save')),
        ),
      ],
    ),
  );
}

String _guessName(String source) {
  if (source.trim().isEmpty) return '';
  final lines = source
      .split('\n')
      .map((x) => x.trim())
      .where((x) => x.length >= 3 && x.length <= 90 && !x.contains('http'))
      .toList();
  final dose = RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|µg|g|ml)\b',
    caseSensitive: false,
  );
  final selected =
      lines.where((x) => dose.hasMatch(x)).firstOrNull ??
      lines.firstOrNull ??
      '';
  return selected.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _guessRegistryName(String source) {
  final guessed = _guessName(source);
  if (guessed.isEmpty) return '';
  final strength = RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|µg|μg|g|ml)\b',
    caseSensitive: false,
  ).firstMatch(guessed);
  final withoutStrength = strength == null
      ? guessed
      : guessed.substring(0, strength.start);
  return withoutStrength
      .replaceAll(RegExp(r'[^\p{L}\d -]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _registryTitleCase(String value) => value
    .split(' ')
    .map(
      (word) => word.isEmpty
          ? word
          : '${word.substring(0, 1).toUpperCase()}${word.substring(1).toLowerCase()}',
    )
    .join(' ');

String _guessStrength(String source) =>
    RegExp(
      r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|µg|g|ml)\b',
      caseSensitive: false,
    ).firstMatch(source)?.group(0) ??
    '';

String _guessPackageSize(String source) =>
    RegExp(
      r'\bN\s?\d+\b',
      caseSensitive: false,
    ).firstMatch(source)?.group(0)?.replaceAll(' ', '') ??
    '';

const defaultMedicineCategories = <String>{
  'Skausmas ir karščiavimas',
  'Alergija',
  'Virškinimas',
  'Kvėpavimo sistema',
  'Širdis ir kraujotaka',
  'Kraujas',
  'Nervų sistema',
  'Infekcijos',
  'Hormonai ir skydliaukė',
  'Oda',
  'Akys ir ausys',
  'Vitaminai ir papildai',
  'Kita',
};

Set<String> _splitCategories(String value) => value
    .split(RegExp(r'[;,]'))
    .map((x) => x.trim())
    .where((x) => x.isNotEmpty)
    .toSet();

Set<String> _suggestMedicineCategories(String atcCode, String source) {
  final result = <String>{};
  final atc = atcCode.trim().toUpperCase();
  if (atc.isNotEmpty) {
    final byAtc = {
      'A': 'Virškinimas',
      'B': 'Kraujas',
      'C': 'Širdis ir kraujotaka',
      'D': 'Oda',
      'H': 'Hormonai ir skydliaukė',
      'J': 'Infekcijos',
      'M': 'Skausmas ir karščiavimas',
      'N': 'Nervų sistema',
      'R': 'Kvėpavimo sistema',
      'S': 'Akys ir ausys',
    };
    final category = byAtc[atc.substring(0, 1)];
    if (category != null) result.add(category);
  }
  final text = source.toLowerCase();
  if (RegExp(r'ibuprofen|paracetamol|skausm|karščiav').hasMatch(text)) {
    result.add('Skausmas ir karščiavimas');
  }
  if (RegExp(r'loratadin|cetirizin|alerg').hasMatch(text)) {
    result.add('Alergija');
  }
  if (RegExp(r'levotiroks|euthyrox|skydliauk').hasMatch(text)) {
    result.add('Hormonai ir skydliaukė');
  }
  if (RegExp(r'vitamin|magn|papild').hasMatch(text)) {
    result.add('Vitaminai ir papildai');
  }
  if (result.isEmpty) result.add('Kita');
  return result;
}

class FamilyPage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  const FamilyPage({super.key, required this.data, required this.onChanged});
  @override
  Widget build(c) => ColoredBox(
    color: const Color(0xfff6fbfa),
    child: ListView(
      padding: scrollPagePadding(c),
      children: [
        title(tx(c, 'Mano šeima', 'My family')),
        const SizedBox(height: 16),
        if (data.members.isEmpty)
          card(
            Text(
              tx(
                c,
                'Šeimos narių dar nėra. Pridėk žmogų ir pasirink, kas jis tau.',
                'No family members yet. Add a person and choose their relationship.',
              ),
            ),
          ),
        if (data.members.any((m) => m.ageGroup != 'child')) ...[
          _familyGroupTitle(c, 'Suaugusieji', 'Adults'),
          ...data.members
              .where((m) => m.ageGroup != 'child')
              .map((m) => _familyMemberCard(c, data, m, onChanged)),
        ],
        if (data.members.any((m) => m.ageGroup == 'child')) ...[
          const SizedBox(height: 8),
          _familyGroupTitle(c, 'Vaikai', 'Children'),
          ...data.members
              .where((m) => m.ageGroup == 'child')
              .map((m) => _familyMemberCard(c, data, m, onChanged)),
        ],
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            if (!await requirePremium(c) || !c.mounted) return;
            await Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => MemberEditor(data: data, onChanged: onChanged),
              ),
            );
          },
          icon: const Icon(Icons.person_add),
          label: Text(tx(c, 'Pridėti šeimos narį', 'Add family member')),
        ),
      ],
    ),
  );
}

Widget _familyGroupTitle(BuildContext c, String lt, String en) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
  child: Text(
    tx(c, lt, en),
    style: const TextStyle(
      color: navy,
      fontSize: 17,
      height: 1.25,
      fontFamily: 'sans-serif',
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.none,
    ),
  ),
);

Widget _familyMemberCard(
  BuildContext c,
  AppData data,
  Member member,
  VoidCallback onChanged,
) {
  final medicineCount = data.meds
      .where((medicine) => medicine.memberIds.contains(member.id))
      .length;
  return Card(
  child: ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    leading: _FamilyAvatar(
      member: member,
      fallbackIndex: data.members.indexOf(member),
    ),
    title: Text(
      member.name,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    subtitle: Text(
      '${memberRelationName(c, data, member)} • '
      '${tx(c, '$medicineCount vaistai', '$medicineCount medicines')}',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      if (!await requirePremium(c) || !c.mounted) return;
      await Navigator.push(
        c,
        MaterialPageRoute(
          builder: (_) =>
              MemberEditor(data: data, member: member, onChanged: onChanged),
        ),
      );
    },
  ),
  );
}

const relations = [
  'self',
  'member',
  'child',
  'partner',
  'mother',
  'father',
  'sister',
  'brother',
  'grandparent',
  'other',
];
String relationName(BuildContext c, String r) {
  final lt = {
    'self': 'Aš pats / Aš pati',
    'member': 'Šeimos narys',
    'child': 'Vaikas',
    'partner': 'Partneris / partnerė',
    'mother': 'Mama',
    'father': 'Tėtis',
    'sister': 'Sesuo',
    'brother': 'Brolis',
    'grandparent': 'Senelis / močiutė',
    'other': 'Kitas asmuo',
  };
  final en = {
    'self': 'Myself',
    'member': 'Family member',
    'child': 'Child',
    'partner': 'Partner',
    'mother': 'Mother',
    'father': 'Father',
    'sister': 'Sister',
    'brother': 'Brother',
    'grandparent': 'Grandparent',
    'other': 'Other',
  };
  return Localizations.localeOf(c).languageCode == 'en'
      ? (en[r] ?? r)
      : (lt[r] ?? r);
}

String memberRelationName(BuildContext c, AppData data, Member member) {
  if (member.id == data.linkedMemberId) {
    return tx(c, 'Aš pats / Aš pati', 'Myself');
  }
  // Older household data stored the creator's device-local "self" marker in
  // the shared member record. On every other account it is a normal member.
  if (member.relation == 'self' && data.householdId.isNotEmpty) {
    return tx(c, 'Šeimos narys', 'Family member');
  }
  return relationName(c, member.relation);
}

String accountDisplayName(AppData data) {
  if (data.linkedMemberId.isNotEmpty) {
    final linked = data.members.where(
      (member) => member.id == data.linkedMemberId,
    );
    if (linked.isNotEmpty && linked.first.name.trim().isNotEmpty) {
      return linked.first.name.trim();
    }
  }
  return data.profile.name.trim();
}

class MemberEditor extends StatefulWidget {
  final AppData data;
  final Member? member;
  final String initialRelation;
  final VoidCallback onChanged;
  const MemberEditor({
    super.key,
    required this.data,
    this.member,
    this.initialRelation = 'self',
    required this.onChanged,
  });
  State<MemberEditor> createState() => _MemberEditor();
}

class _MemberEditor extends State<MemberEditor> {
  late final name = TextEditingController(text: widget.member?.name ?? ''),
      birth = TextEditingController(text: widget.member?.birthDate ?? ''),
      bloodType = TextEditingController(text: widget.member?.bloodType ?? ''),
      height = TextEditingController(text: widget.member?.height ?? ''),
      weight = TextEditingController(text: widget.member?.weight ?? ''),
      allergies = TextEditingController(text: widget.member?.allergies ?? ''),
      conditions = TextEditingController(text: widget.member?.conditions ?? ''),
      intolerantMedicines = TextEditingController(
        text: widget.member?.intolerantMedicines ?? '',
      ),
      healthcareFacility = TextEditingController(
        text: widget.member?.healthcareFacility ?? '',
      ),
      familyDoctor = TextEditingController(
        text: widget.member?.familyDoctor ?? '',
      ),
      facilityPhone = TextEditingController(
        text: widget.member?.facilityPhone ?? '',
      ),
      facilityAddress = TextEditingController(
        text: widget.member?.facilityAddress ?? '',
      ),
      notes = TextEditingController(text: widget.member?.notes ?? '');
  late String relation = widget.member?.relation ?? widget.initialRelation;
  late String gender = widget.member?.gender ?? 'unspecified';
  late String ageGroup =
      widget.member?.ageGroup ??
      (widget.member?.relation == 'child' ? 'child' : 'adult');
  late String imagePath = widget.member?.imagePath ?? '';
  @override
  void dispose() {
    for (final x in [
      name,
      birth,
      bloodType,
      height,
      weight,
      allergies,
      conditions,
      intolerantMedicines,
      healthcareFacility,
      familyDoctor,
      facilityPhone,
      facilityAddress,
      notes,
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _pickMemberPhoto(ImageSource source) async {
    if (source == ImageSource.camera &&
        !await _cameraAvailable(context, widget.data)) return;
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1200,
    );
    if (picked == null) return;
    final directory = await getApplicationDocumentsDirectory();
    final extension = picked.path.contains('.')
        ? picked.path.split('.').last
        : 'jpg';
    final id = widget.member?.id ?? newId();
    final saved = await File(picked.path)
        .copy('${directory.path}/member_$id.$extension');
    if (mounted) setState(() => imagePath = saved.path);
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.member == null
            ? tx(c, 'Naujas šeimos narys', 'New family member')
            : tx(c, 'Redaguoti narį', 'Edit member'),
      ),
      actions: [
        if (widget.member != null &&
            widget.member!.id != widget.data.linkedMemberId)
          IconButton(
            onPressed: () async {
              if (!await confirmDelete(c, widget.member!.name) || !c.mounted) {
                return;
              }
              widget.data.members.removeWhere((x) => x.id == widget.member!.id);
              widget.data.reminders.removeWhere(
                (x) => x.memberId == widget.member!.id,
              );
              for (final medicine in widget.data.meds) {
                medicine.memberIds.remove(widget.member!.id);
              }
              widget.onChanged();
              Navigator.pop(c);
            },
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    backgroundColor: const Color(0xfff6fbfa),
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(c).bottom + 32,
      ),
      children: [
        Center(
          child: CircleAvatar(
            radius: 54,
            backgroundColor: mint,
            backgroundImage: imagePath.isNotEmpty
                ? FileImage(File(imagePath))
                : null,
            child: imagePath.isEmpty
                ? Text(
                    _memberEmoji(gender, ageGroup),
                    style: const TextStyle(fontSize: 58),
                  )
                : null,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickMemberPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(tx(c, 'Fotografuoti', 'Take photo')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickMemberPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(tx(c, 'Galerija', 'Gallery')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        field(c, name, 'Vardas', 'Name'),
        Text(
          tx(c, 'Amžiaus grupė', 'Age group'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'adult',
              icon: const Icon(Icons.person_outline),
              label: Text(tx(c, 'Suaugęs', 'Adult')),
            ),
            ButtonSegment(
              value: 'child',
              icon: const Icon(Icons.child_care_outlined),
              label: Text(tx(c, 'Vaikas', 'Child')),
            ),
          ],
          selected: {ageGroup},
          onSelectionChanged: (values) =>
              setState(() => ageGroup = values.first),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: gender,
          decoration: InputDecoration(labelText: tx(c, 'Lytis', 'Gender')),
          items: [
            DropdownMenuItem(
              value: 'female',
              child: Text(tx(c, 'Moteris / mergaitė', 'Female')),
            ),
            DropdownMenuItem(
              value: 'male',
              child: Text(tx(c, 'Vyras / berniukas', 'Male')),
            ),
            DropdownMenuItem(
              value: 'unspecified',
              child: Text(tx(c, 'Nenurodyta', 'Not specified')),
            ),
          ],
          onChanged: (value) => setState(() => gender = value!),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: relation,
          decoration: InputDecoration(
            labelText: tx(c, 'Kas jis / ji?', 'Relationship'),
          ),
          items: relations
              .map(
                (r) =>
                    DropdownMenuItem(value: r, child: Text(relationName(c, r))),
              )
              .toList(),
          onChanged: (v) => setState(() {
            relation = v!;
            if (relation == 'child') ageGroup = 'child';
          }),
        ),
        const SizedBox(height: 12),
        dateField(
          c,
          birth,
          'Gimimo data YYYY-MM-DD',
          'Date of birth YYYY-MM-DD',
        ),
        field(c, bloodType, 'Kraujo grupė', 'Blood type'),
        Row(
          children: [
            Expanded(
              child: field(c, height, 'Ūgis (cm)', 'Height (cm)', number: true),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: field(
                c,
                weight,
                'Svoris (kg)',
                'Weight (kg)',
                number: true,
              ),
            ),
          ],
        ),
        field(c, allergies, 'Alergijos', 'Allergies', lines: 2),
        field(
          c,
          conditions,
          'Sveikatos būklės',
          'Medical conditions',
          lines: 2,
        ),
        field(
          c,
          intolerantMedicines,
          'Netoleruojami vaistai',
          'Intolerant medicines',
          lines: 2,
        ),
        const SizedBox(height: 4),
        Text(
          tx(c, 'Gydymo įstaiga', 'Healthcare facility'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        field(
          c,
          healthcareFacility,
          'Gydymo įstaigos pavadinimas',
          'Facility name',
        ),
        field(c, familyDoctor, 'Šeimos gydytojas', 'Family doctor'),
        field(c, facilityPhone, 'Gydymo įstaigos telefonas', 'Facility phone'),
        field(
          c,
          facilityAddress,
          'Gydymo įstaigos adresas',
          'Facility address',
        ),
        field(c, notes, 'Pastabos', 'Notes', lines: 3),
        if (widget.member != null) ...[
          const SizedBox(height: 4),
          Text(
            tx(
              c,
              'Priskirti vaistai ir priminimai',
              'Assigned medicines and reminders',
            ),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (widget.data.meds.isEmpty)
            Text(tx(c, 'Bendra vaistinėlė tuščia.', 'The shared cabinet is empty.')),
          ...widget.data.meds.map(
            (m) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.medication_outlined, color: green),
              title: Text('${m.name} ${m.strength}'.trim()),
              subtitle: Text(tx(c, 'Bendra vaistinėlė', 'Shared cabinet')),
              value: m.memberIds.contains(widget.member!.id),
              onChanged: (selected) {
                setState(() {
                  if (selected == true) {
                    if (!m.memberIds.contains(widget.member!.id)) {
                      m.memberIds.add(widget.member!.id);
                    }
                  } else {
                    m.memberIds.remove(widget.member!.id);
                  }
                });
                widget.onChanged();
              },
            ),
          ),
          ...widget.data.reminders
              .where((r) => r.memberId == widget.member!.id)
              .map(
                (r) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.alarm_outlined, color: green),
                  title: Text(r.title),
                  subtitle: Text(r.time),
                ),
              ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) => MedicineEditor(
                          data: widget.data,
                          initialMemberId: widget.member!.id,
                          onChanged: widget.onChanged,
                        ),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.medication_outlined),
                  label: Text(tx(c, 'Pridėti vaistą', 'Add medicine')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) => ReminderEditor(
                          data: widget.data,
                          initialMemberId: widget.member!.id,
                          onChanged: widget.onChanged,
                        ),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.add_alarm_outlined),
                  label: Text(tx(c, 'Priminimas', 'Reminder')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            final m =
                widget.member ??
                Member(id: newId(), name: '', relation: relation);
            m.name = name.text.trim();
            m.relation = relation;
            m.gender = gender;
            m.ageGroup = ageGroup;
            m.birthDate = birth.text.trim();
            m.imagePath = imagePath;
            m.bloodType = bloodType.text.trim();
            m.height = height.text.trim();
            m.weight = weight.text.trim();
            m.allergies = allergies.text.trim();
            m.conditions = conditions.text.trim();
            m.intolerantMedicines = intolerantMedicines.text.trim();
            m.healthcareFacility = healthcareFacility.text.trim();
            m.familyDoctor = familyDoctor.text.trim();
            m.facilityPhone = facilityPhone.text.trim();
            m.facilityAddress = facilityAddress.text.trim();
            m.notes = notes.text.trim();
            if (relation == 'self') {
              final duplicate = widget.data.members.any(
                (x) => x.relation == 'self' && x.id != m.id,
              );
              if (duplicate) {
                ScaffoldMessenger.of(c).showSnackBar(
                  SnackBar(
                    content: Text(
                      tx(
                        c,
                        'Asmuo „Aš pats / Aš pati“ jau yra pridėtas.',
                        'A “Myself” member already exists.',
                      ),
                    ),
                  ),
                );
                return;
              }
              widget.data.profile.name = m.name;
              widget.data.profile.birthDate = m.birthDate;
              widget.data.profile.allergies = m.allergies;
              widget.data.profile.conditions = m.conditions;
              widget.data.profile.notes = m.notes;
            }
            if (m.id == widget.data.linkedMemberId) {
              widget.data.profile
                ..name = m.name
                ..birthDate = m.birthDate
                ..bloodType = m.bloodType
                ..allergies = m.allergies
                ..conditions = m.conditions
                ..medications = m.intolerantMedicines
                ..notes = m.notes;
            }
            if (widget.member == null) widget.data.members.add(m);
            widget.onChanged();
            Navigator.pop(c);
          },
          child: Text(tx(c, 'Išsaugoti', 'Save')),
        ),
      ],
    ),
  );
}

class MediBoxCalendarSelection {
  final DateTime date;
  final String memberId;

  const MediBoxCalendarSelection(this.date, this.memberId);
}

Future<MediBoxCalendarSelection?> showMediBoxCalendar({
  required BuildContext context,
  required DateTime initialDate,
  required List<HealthAppointment> appointments,
  required List<Member> members,
  String memberId = '',
}) {
  var month = DateTime(initialDate.year, initialDate.month);
  var selectedMemberId = memberId;
  return showDialog<MediBoxCalendarSelection>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final firstDay = DateTime(month.year, month.month, 1);
        final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
        final leadingEmptyDays = firstDay.weekday - DateTime.monday;
        final cellCount = ((leadingEmptyDays + daysInMonth + 6) ~/ 7) * 7;
        final locale = Localizations.localeOf(context).languageCode;
        final today = dateKey();
        final appointmentDates = appointments
            .where(
              (item) =>
                  selectedMemberId.isEmpty ||
                  item.memberId == selectedMemberId,
            )
            .map((item) => item.date)
            .toSet();
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tx(context, 'Pasirinkite datą', 'Choose a date'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: navy,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (members.isNotEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: Text(
                              tx(context, 'Visa šeima', 'Whole family'),
                            ),
                            selected: selectedMemberId.isEmpty,
                            onSelected: (_) => setDialogState(
                              () => selectedMemberId = '',
                            ),
                          ),
                          const SizedBox(width: 7),
                          ...members.map(
                            (member) => Padding(
                              padding: const EdgeInsets.only(right: 7),
                              child: ChoiceChip(
                                avatar: Text(
                                  _memberEmoji(
                                    member.gender,
                                    member.ageGroup,
                                  ),
                                ),
                                label: Text(member.name),
                                selected: selectedMemberId == member.id,
                                onSelected: (_) => setDialogState(
                                  () => selectedMemberId = member.id,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (members.isNotEmpty) const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const Icon(
                        Icons.local_hospital_outlined,
                        size: 16,
                        color: appointmentBlue,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        tx(context, 'Vizitas', 'Appointment'),
                        style: const TextStyle(
                          color: appointmentBlue,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: tx(context, 'Ankstesnis mėnuo', 'Previous month'),
                        onPressed: () => setDialogState(
                          () => month = DateTime(month.year, month.month - 1),
                        ),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          DateFormat('LLLL yyyy', locale).format(month),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tx(context, 'Kitas mėnuo', 'Next month'),
                        onPressed: () => setDialogState(
                          () => month = DateTime(month.year, month.month + 1),
                        ),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final label in (locale == 'en'
                          ? const ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                          : const ['P', 'A', 'T', 'K', 'P', 'Š', 'S']))
                        Expanded(
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      childAspectRatio: .82,
                    ),
                    itemCount: cellCount,
                    itemBuilder: (context, index) {
                      final dayNumber = index - leadingEmptyDays + 1;
                      if (dayNumber < 1 || dayNumber > daysInMonth) {
                        return const SizedBox.shrink();
                      }
                      final day = DateTime(month.year, month.month, dayNumber);
                      final key = dateKey(day);
                      final selected = key == dateKey(initialDate);
                      final hasVisit = appointmentDates.contains(key);
                      return Padding(
                        padding: const EdgeInsets.all(2),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(
                            dialogContext,
                            MediBoxCalendarSelection(day, selectedMemberId),
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            decoration: BoxDecoration(
                              color: selected ? green : null,
                              borderRadius: BorderRadius.circular(14),
                              border: key == today && !selected
                                  ? Border.all(color: green)
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$dayNumber',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: selected ? Colors.white : navy,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                if (hasVisit)
                                  Icon(
                                    Icons.local_hospital_outlined,
                                    size: 14,
                                    color: selected
                                        ? Colors.white
                                        : appointmentBlue,
                                  )
                                else
                                  const SizedBox(height: 14),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(
                        dialogContext,
                        MediBoxCalendarSelection(
                          DateTime.now(),
                          selectedMemberId,
                        ),
                      ),
                      child: Text(tx(context, 'Šiandien', 'Today')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class HealthCalendarPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  final DateTime? initialDate;
  final String initialMemberId;
  const HealthCalendarPage({
    super.key,
    required this.data,
    required this.onChanged,
    this.initialDate,
    this.initialMemberId = '',
  });
  @override
  State<HealthCalendarPage> createState() => _HealthCalendarPageState();
}

class _HealthCalendarPageState extends State<HealthCalendarPage> {
  late DateTime selectedDay;
  late String memberId;

  @override
  void initState() {
    super.initState();
    selectedDay = widget.initialDate ?? DateTime.now();
    memberId = widget.initialMemberId;
  }

  @override
  Widget build(BuildContext context) {
    final key = dateKey(selectedDay);
    final doses =
        widget.data.reminders
            .where(
              (item) =>
                  reminderAppliesOn(item, selectedDay) &&
                  reminderMatchesMember(widget.data, item, memberId),
            )
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final appointments =
        widget.data.appointments
            .where(
              (item) =>
                  item.date == key &&
                  (memberId.isEmpty || item.memberId == memberId),
            )
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final scheduledEvents = <(String, int, Object)>[
      ...doses.map((item) => (item.time, 1, item as Object)),
      ...appointments.map((item) => (item.time, 0, item as Object)),
    ]..sort((a, b) {
      final timeOrder = a.$1.compareTo(b.$1);
      return timeOrder == 0 ? a.$2.compareTo(b.$2) : timeOrder;
    });
    final medicineDeadlines = <(Med, String, String)>[];
    for (final medicine in widget.data.meds) {
      if (memberId.isNotEmpty &&
          medicine.memberIds.isNotEmpty &&
          !medicine.memberIds.contains(memberId))
        continue;
      if (medicine.prescriptionValidUntil == key) {
        medicineDeadlines.add((
          medicine,
          'receptas',
          tx(context, 'Baigiasi recepto galiojimas', 'Prescription expires'),
        ));
      }
      if (medicine.treatmentUntil == key) {
        medicineDeadlines.add((
          medicine,
          'gydymas',
          tx(
            context,
            'Vaisto turi užtekti iki šios dienos',
            'Medicine should last until this day',
          ),
        ));
      }
    }
    final days = List.generate(7, (index) {
      return DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day + index - 3,
      );
    });
    return ListView(
      padding: scrollPagePadding(context),
      children: [
        Row(
          children: [
            Expanded(
              child: title(
                tx(context, 'Šeimos kalendorius', 'Family calendar'),
              ),
            ),
            IconButton(
              tooltip: tx(context, 'Pasirinkti datą', 'Choose date'),
              onPressed: () async {
                final value = await showMediBoxCalendar(
                  context: context,
                  initialDate: selectedDay,
                  appointments: widget.data.appointments,
                  members: widget.data.members,
                  memberId: memberId,
                );
                if (value != null) {
                  setState(() {
                    selectedDay = value.date;
                    memberId = value.memberId;
                  });
                }
              },
              icon: const Icon(Icons.date_range_outlined),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.data.members.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(tx(context, 'Visa šeima', 'Whole family')),
                  selected: memberId.isEmpty,
                  onSelected: (_) => setState(() => memberId = ''),
                ),
                const SizedBox(width: 7),
                ...widget.data.members.map(
                  (member) => Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      avatar: Text(
                        _memberEmoji(member.gender, member.ageGroup),
                      ),
                      label: Text(member.name),
                      selected: memberId == member.id,
                      onSelected: (_) => setState(() => memberId = member.id),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 72,
          child: Row(
            children: days.map((day) {
              final selected = dateKey(day) == key;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => selectedDay = day),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xffcceee4)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? green
                              : const Color(0xffd8e4e1),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            DateFormat(
                              'E',
                              Localizations.localeOf(context).languageCode,
                            ).format(day),
                            style: TextStyle(
                              color: selected ? green : navy,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${day.day}',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: selected ? green : navy,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Text(
          DateFormat(
            'y MMMM d, EEEE',
            Localizations.localeOf(context).languageCode,
          ).format(selectedDay),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: navy,
          ),
        ),
        const SizedBox(height: 8),
        if (doses.isEmpty && appointments.isEmpty && medicineDeadlines.isEmpty)
          card(
            Text(
              tx(
                context,
                'Šiai dienai įvykių nėra.',
                'No events for this day.',
              ),
            ),
          ),
        ...medicineDeadlines.map(
          (entry) => Card(
            color: const Color(0xfffff3df),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  Icons.event_busy_outlined,
                  color: Color(0xffff9f1c),
                ),
              ),
              title: Text(
                '${entry.$1.name} ${entry.$1.strength}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                '${entry.$3}\n${tx(context, 'Paspauskite suplanuoti vizitą pas gydytoją.', 'Tap to schedule a doctor appointment.')}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.add_circle_outline),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppointmentEditor(
                    data: widget.data,
                    initialDate: key,
                    initialMemberId: memberId.isNotEmpty
                        ? memberId
                        : entry.$1.memberIds.firstOrNull ?? '',
                    initialTitle: tx(
                      context,
                      'Vizitas dėl recepto',
                      'Prescription appointment',
                    ),
                    initialReason:
                        '${entry.$1.name} ${entry.$1.strength}: ${entry.$3}',
                    onChanged: widget.onChanged,
                  ),
                ),
              ),
            ),
          ),
        ),
        ...scheduledEvents.map((event) {
          if (event.$3 is HealthAppointment) {
            final item = event.$3 as HealthAppointment;
            return Opacity(
              opacity: item.completed ? .62 : 1,
              child: Card(
                color: appointmentBlueSoft,
                child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  Icons.local_hospital_outlined,
                  color: appointmentBlue,
                ),
              ),
              title: Text(
                '${item.time} • ${item.title}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                [
                  _memberName(widget.data, item.memberId),
                  item.doctor,
                  item.facility,
                ].where((x) => x.isNotEmpty).join(' • '),
              ),
              trailing: Icon(
                item.completed ? Icons.check_circle : Icons.chevron_right,
                color: appointmentBlue,
              ),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AppointmentEditor(
                      data: widget.data,
                      appointment: item,
                      onChanged: widget.onChanged,
                    ),
                  ),
                );
                setState(() {});
              },
            ),
              ),
            );
          }
          final item = event.$3 as Reminder;
          final taken = item.takenDates.contains(key);
          final today = DateTime.now();
          final selectedDate = DateTime(
            selectedDay.year,
            selectedDay.month,
            selectedDay.day,
          );
          final canMarkTaken = !selectedDate.isAfter(
            DateTime(today.year, today.month, today.day),
          );
          final parts = item.time.split(':');
          final occurrence = DateTime(
            selectedDay.year,
            selectedDay.month,
            selectedDay.day,
            int.tryParse(parts.firstOrNull ?? '') ?? 0,
            int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
          );
          return Card(
            child: ListTile(
              leading: Icon(
                taken ? Icons.check_circle : Icons.medication_outlined,
                color: taken ? green : const Color(0xffff9f1c),
              ),
              title: Text(
                '${item.time} • ${item.title}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                [
                  _who(widget.data, item, tx(context, 'Aš', 'Me')),
                  '${quantityLabel(item.quantityPerDose)} ${doseUnitLabel(context, item.doseUnit)}',
                ].where((value) => value.isNotEmpty).join(' • '),
              ),
              trailing: canMarkTaken
                  ? IconButton(
                      tooltip: taken
                          ? tx(
                              context,
                              'Atšaukti suvartojimą',
                              'Undo consumption',
                            )
                          : tx(
                              context,
                              'Pažymėti suvartojimą',
                              'Mark as taken',
                            ),
                      onPressed: () {
                        if (taken) {
                          undoDoseTaken(widget.data, item, occurrence);
                        } else {
                          markDoseTaken(widget.data, item, occurrence);
                        }
                        widget.onChanged();
                        setState(() {});
                      },
                      icon: Icon(
                        taken
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: taken ? green : const Color(0xff7b8ba1),
                      ),
                    )
                  : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReminderEditor(
                    data: widget.data,
                    reminder: item,
                    onChanged: widget.onChanged,
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AppointmentEditor(
                  data: widget.data,
                  initialDate: key,
                  initialMemberId: memberId,
                  onChanged: widget.onChanged,
                ),
              ),
            );
            setState(() {});
          },
          icon: const Icon(Icons.add),
          label: Text(tx(context, 'Planuoti vizitą', 'Schedule appointment')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReminderRoutePage(
                data: widget.data,
                onChanged: widget.onChanged,
              ),
            ),
          ),
          icon: const Icon(Icons.notifications_outlined),
          label: Text(
            tx(
              context,
              'Tvarkyti vaistų priminimus',
              'Manage medicine reminders',
            ),
          ),
        ),
      ],
    );
  }
}

String _memberName(AppData data, String id) =>
    data.members
        .where((member) => member.id == id)
        .map((member) => member.name)
        .firstOrNull ??
    '';

class AppointmentEditor extends StatefulWidget {
  final AppData data;
  final HealthAppointment? appointment;
  final String initialDate, initialMemberId, initialTitle, initialReason;
  final VoidCallback onChanged;
  const AppointmentEditor({
    super.key,
    required this.data,
    this.appointment,
    this.initialDate = '',
    this.initialMemberId = '',
    this.initialTitle = '',
    this.initialReason = '',
    required this.onChanged,
  });
  @override
  State<AppointmentEditor> createState() => _AppointmentEditorState();
}

class _AppointmentEditorState extends State<AppointmentEditor> {
  late final titleC = TextEditingController(
        text: widget.appointment?.title ?? widget.initialTitle,
      ),
      doctor = TextEditingController(text: widget.appointment?.doctor ?? ''),
      facility = TextEditingController(
        text: widget.appointment?.facility ?? '',
      ),
      address = TextEditingController(text: widget.appointment?.address ?? ''),
      date = TextEditingController(
        text: widget.appointment?.date ?? widget.initialDate,
      ),
      reason = TextEditingController(
        text: widget.appointment?.reason ?? widget.initialReason,
      ),
      notes = TextEditingController(text: widget.appointment?.notes ?? '');
  late String time = widget.appointment?.time ?? '09:00';
  late String memberId = widget.appointment?.memberId ?? widget.initialMemberId;
  late int remindBefore = widget.appointment?.remindBeforeMinutes ?? 1440;
  late bool completed = widget.appointment?.completed ?? false;

  @override
  void dispose() {
    for (final item in [
      titleC,
      doctor,
      facility,
      address,
      date,
      reason,
      notes,
    ]) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.appointment == null
            ? tx(context, 'Naujas vizitas', 'New appointment')
            : tx(context, 'Redaguoti vizitą', 'Edit appointment'),
      ),
      actions: [
        if (widget.appointment != null)
          IconButton(
            onPressed: () async {
              if (!await confirmDelete(context, widget.appointment!.title) ||
                  !context.mounted)
                return;
              widget.data.appointments.remove(widget.appointment);
              widget.onChanged();
              Navigator.pop(context);
            },
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(context).bottom + 30,
      ),
      children: [
        field(
          context,
          titleC,
          'Vizitas / specialistas',
          'Appointment / specialist',
        ),
        if (widget.data.members.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: widget.data.members.any((x) => x.id == memberId)
                ? memberId
                : null,
            decoration: InputDecoration(
              labelText: tx(context, 'Šeimos narys', 'Family member'),
            ),
            items: widget.data.members
                .map(
                  (member) => DropdownMenuItem(
                    value: member.id,
                    child: Text(
                      '${_memberEmoji(member.gender, member.ageGroup)} ${member.name}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => memberId = value ?? ''),
          ),
        const SizedBox(height: 12),
        field(context, doctor, 'Gydytojas', 'Doctor'),
        field(context, facility, 'Gydymo įstaiga', 'Healthcare facility'),
        field(context, address, 'Adresas / kabinetas', 'Address / room'),
        dateField(
          context,
          date,
          'Vizito data YYYY-MM-DD',
          'Appointment date YYYY-MM-DD',
        ),
        ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xff808b89)),
          ),
          leading: const Icon(Icons.schedule),
          title: Text('${tx(context, 'Laikas', 'Time')}: $time'),
          onTap: () async {
            final parts = time.split(':');
            final value = await showTimePicker(
              context: context,
              initialTime: TimeOfDay(
                hour: int.parse(parts[0]),
                minute: int.parse(parts[1]),
              ),
            );
            if (value != null)
              setState(
                () => time =
                    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}',
              );
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: remindBefore,
          decoration: InputDecoration(
            labelText: tx(context, 'Priminti prieš', 'Remind before'),
          ),
          items: [
            DropdownMenuItem(
              value: 60,
              child: Text(tx(context, '1 valandą', '1 hour')),
            ),
            DropdownMenuItem(
              value: 180,
              child: Text(tx(context, '3 valandas', '3 hours')),
            ),
            DropdownMenuItem(
              value: 1440,
              child: Text(tx(context, '1 dieną', '1 day')),
            ),
            DropdownMenuItem(
              value: 2880,
              child: Text(tx(context, '2 dienas', '2 days')),
            ),
            DropdownMenuItem(
              value: 10080,
              child: Text(tx(context, '1 savaitę', '1 week')),
            ),
          ],
          onChanged: (value) => setState(() => remindBefore = value ?? 1440),
        ),
        const SizedBox(height: 12),
        field(context, reason, 'Vizito priežastis', 'Reason', lines: 2),
        field(
          context,
          notes,
          'Ką pasiimti / pastabos',
          'What to bring / notes',
          lines: 3,
        ),
        if (widget.appointment != null)
          SwitchListTile(
            value: completed,
            title: Text(tx(context, 'Vizitas įvyko', 'Appointment completed')),
            onChanged: (value) => setState(() => completed = value),
          ),
        FilledButton(
          onPressed: () {
            if (titleC.text.trim().isEmpty ||
                DateTime.tryParse(date.text) == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      context,
                      'Įveskite vizitą ir teisingą datą.',
                      'Enter an appointment and valid date.',
                    ),
                  ),
                ),
              );
              return;
            }
            final item =
                widget.appointment ??
                HealthAppointment(
                  id: newId(),
                  title: titleC.text.trim(),
                  date: date.text,
                  time: time,
                );
            item
              ..memberId = memberId
              ..title = titleC.text.trim()
              ..doctor = doctor.text.trim()
              ..facility = facility.text.trim()
              ..address = address.text.trim()
              ..date = date.text.trim()
              ..time = time
              ..reason = reason.text.trim()
              ..notes = notes.text.trim()
              ..remindBeforeMinutes = remindBefore
              ..completed = completed;
            if (widget.appointment == null) widget.data.appointments.add(item);
            widget.onChanged();
            Navigator.pop(context);
          },
          child: Text(tx(context, 'Išsaugoti vizitą', 'Save appointment')),
        ),
      ],
    ),
  );
}

class RemindersPage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  final bool showTitle;
  const RemindersPage({
    super.key,
    required this.data,
    required this.onChanged,
    this.showTitle = true,
  });
  @override
  Widget build(c) {
    final rs = [...data.reminders]..sort((a, b) => a.time.compareTo(b.time));
    return ListView(
      padding: scrollPagePadding(c),
      children: [
        if (showTitle) ...[
          title(tx(c, 'Priminimai', 'Reminders')),
          const SizedBox(height: 10),
        ],
        FutureBuilder<bool>(
          future: ReminderNotifications.notificationsEnabled(),
          builder: (context, snapshot) {
            final enabled = snapshot.data;
            return Card(
              color: enabled == false
                  ? const Color(0xfffff3df)
                  : const Color(0xffe8f7f3),
              child: ListTile(
                leading: Icon(
                  enabled == false
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_active_outlined,
                  color: enabled == false
                      ? const Color(0xffff8a00)
                      : green,
                ),
                title: Text(
                  enabled == null
                      ? tx(c, 'Tikrinami leidimai…', 'Checking permissions…')
                      : enabled
                      ? tx(c, 'Pranešimai leidžiami', 'Notifications allowed')
                      : tx(c, 'Pranešimai užblokuoti', 'Notifications blocked'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: enabled == false
                    ? Text(
                        tx(
                          c,
                          'Atidarykite telefono nustatymus ir leiskite „MediBox“ pranešimus.',
                          'Open phone settings and allow MediBox notifications.',
                        ),
                      )
                    : null,
                trailing: enabled == false
                    ? TextButton(
                        onPressed: () => openAppSettings(),
                        child: Text(tx(c, 'Nustatymai', 'Settings')),
                      )
                    : null,
              ),
            );
          },
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  if (!data.medicationNotificationsGranted &&
                      !data.appointmentNotificationsGranted) {
                    ScaffoldMessenger.of(c).showSnackBar(SnackBar(
                      content: Text(tx(
                        c,
                        'Pranešimus pirmiausia įjunkite profilio skiltyje „Sutikimai ir leidimai“.',
                        'First enable notifications in Profile → Permissions and consent.',
                      )),
                    ));
                    return;
                  }
                  final requested =
                      await ReminderNotifications.requestPermissions();
                  final enabled = requested ||
                      await ReminderNotifications.notificationsEnabled();
                  if (!enabled && c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(
                      SnackBar(
                        content: Text(
                          tx(
                            c,
                            'Telefonas blokuoja „MediBox“ pranešimus.',
                            'Your phone is blocking MediBox notifications.',
                          ),
                        ),
                        action: SnackBarAction(
                          label: tx(c, 'Nustatymai', 'Settings'),
                          onPressed: () => openAppSettings(),
                        ),
                      ),
                    );
                    return;
                  }
                  await ReminderNotifications.scheduleAll(data);
                  await ReminderNotifications.showTest(data);
                },
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text(
                  tx(c, 'Patikrinti pranešimus', 'Test notifications'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: tx(c, 'Vartojimo istorija', 'Dose history'),
              onPressed: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) =>
                      DoseHistoryPage(data: data, onChanged: onChanged),
                ),
              ),
              icon: const Icon(Icons.history),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (rs.isEmpty)
          card(
            Text(
              tx(
                c,
                'Priminimų nėra. Sukurk pirmąjį ir pasirink vaistą, žmogų, laiką bei dienas.',
                'No reminders yet. Add one and choose medicine, person, time, and days.',
              ),
            ),
          ),
        ...rs.map(
          (r) => Card(
            child: ListTile(
              leading: Switch(
                value: r.enabled,
                onChanged: (v) {
                  r.enabled = v;
                  onChanged();
                },
              ),
              title: Text('${r.time} • ${r.title}'),
              subtitle: Text(
                '${_who(data, r, tx(c, 'Aš', 'Me'))}${r.dose.isEmpty ? '' : ' • ${r.dose}'}\n${daysLabel(c, r.weekdays)}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => ReminderEditor(
                    data: data,
                    reminder: r,
                    onChanged: onChanged,
                  ),
                ),
              ),
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) => ReminderEditor(data: data, onChanged: onChanged),
            ),
          ),
          icon: const Icon(Icons.add_alarm),
          label: Text(tx(c, 'Pridėti priminimą', 'Add reminder')),
        ),
      ],
    );
  }
}

class ReminderRoutePage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  const ReminderRoutePage({
    super.key,
    required this.data,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff6fbfa),
    appBar: AppBar(
      title: Text(tx(context, 'Priminimai', 'Reminders')),
      backgroundColor: const Color(0xfff6fbfa),
    ),
    body: SafeArea(
      top: false,
      child: RemindersPage(data: data, onChanged: onChanged, showTitle: false),
    ),
  );
}

String daysLabel(BuildContext c, List<int> d) {
  if (d.length == 7) return tx(c, 'Kasdien', 'Every day');
  const lt = ['Pr', 'An', 'Tr', 'Kt', 'Pn', 'Št', 'Sk'],
      en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final a = Localizations.localeOf(c).languageCode == 'en' ? en : lt;
  return d.map((x) => a[x - 1]).join(', ');
}

class ReminderEditor extends StatefulWidget {
  final AppData data;
  final Reminder? reminder;
  final String initialMemberId;
  final String initialMedId;
  final VoidCallback onChanged;
  const ReminderEditor({
    super.key,
    required this.data,
    this.reminder,
    this.initialMemberId = '',
    this.initialMedId = '',
    required this.onChanged,
  });
  State<ReminderEditor> createState() => _ReminderEditor();
}

class _ReminderEditor extends State<ReminderEditor> {
  String _initialMemberId() {
    final requested = widget.reminder?.memberId ?? widget.initialMemberId;
    if (widget.data.members.any((member) => member.id == requested)) {
      return requested;
    }
    if (widget.data.members.any(
      (member) => member.id == widget.data.linkedMemberId,
    )) {
      return widget.data.linkedMemberId;
    }
    return widget.data.members.firstOrNull?.id ?? '';
  }

  Med? get selectedMedicine =>
      widget.data.meds.where((medicine) => medicine.id == medId).firstOrNull;

  String _initialDoseUnit() {
    final existing = widget.reminder;
    final requested = existing?.medId ?? widget.initialMedId;
    return widget.data.meds
            .where((medicine) => medicine.id == requested)
            .map((medicine) => medicine.stockUnit)
            .firstOrNull ??
        existing?.doseUnit ??
        'vnt.';
  }

  late final titleC = TextEditingController(text: widget.reminder?.title ?? ''),
      dose = TextEditingController(text: widget.reminder?.dose ?? ''),
      quantity = TextEditingController(
        text: '${widget.reminder?.quantityPerDose ?? 1}',
      ),
      startDate = TextEditingController(
        text: widget.reminder?.startDate ?? dateKey(),
      ),
      endDate = TextEditingController(text: widget.reminder?.endDate ?? ''),
      instructions = TextEditingController(
        text: widget.reminder?.instructions ?? '',
      );
  late String medId = widget.reminder?.medId ?? widget.initialMedId,
      memberId = _initialMemberId(),
      time = widget.reminder?.time ?? '08:00';
  late String doseUnit = _initialDoseUnit();
  late List<int> days = [
    ...(widget.reminder?.weekdays ?? [1, 2, 3, 4, 5, 6, 7]),
  ];
  late bool enabled = widget.reminder?.enabled ?? true;
  @override
  void dispose() {
    titleC.dispose();
    dose.dispose();
    quantity.dispose();
    startDate.dispose();
    endDate.dispose();
    instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.reminder == null
            ? tx(c, 'Naujas priminimas', 'New reminder')
            : tx(c, 'Redaguoti priminimą', 'Edit reminder'),
      ),
      actions: [
        if (widget.reminder != null)
          IconButton(
            onPressed: () {
              widget.data.reminders.removeWhere(
                (x) => x.id == widget.reminder!.id,
              );
              widget.onChanged();
              Navigator.pop(c);
            },
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(c).bottom + 36,
      ),
      children: [
        field(c, titleC, 'Pavadinimas', 'Title'),
        DropdownButtonFormField<String>(
          initialValue: medId,
          decoration: InputDecoration(
            labelText: tx(c, 'Vaistas (nebūtina)', 'Medicine (optional)'),
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(tx(c, 'Nepasirinkta', 'None')),
            ),
            ...widget.data.meds.map(
              (m) => DropdownMenuItem(
                value: m.id,
                child: Text('${m.name} ${m.strength}'),
              ),
            ),
          ],
          onChanged: (v) {
            setState(() {
              medId = v!;
              final medicine = selectedMedicine;
              if (medicine != null) doseUnit = medicine.stockUnit;
            });
            if (medId.isNotEmpty) {
              final medicine = widget.data.meds.firstWhere(
                (x) => x.id == medId,
              );
              if (titleC.text.isEmpty) titleC.text = medicine.name;
              if (endDate.text.isEmpty && medicine.treatmentUntil.isNotEmpty) {
                endDate.text = medicine.treatmentUntil;
              }
            }
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: memberId,
          decoration: InputDecoration(labelText: tx(c, 'Kam', 'For whom')),
          items: [
            if (widget.data.members.isEmpty)
              DropdownMenuItem(
                value: '',
                child: Text(tx(c, 'Profilis nesusietas', 'Profile not linked')),
              ),
            ...widget.data.members.map(
              (m) => DropdownMenuItem(
                value: m.id,
                child: Text(
                  m.id == widget.data.linkedMemberId
                      ? tx(c, '${m.name} (aš)', '${m.name} (me)')
                      : m.name,
                ),
              ),
            ),
          ],
          onChanged: (v) => setState(() => memberId = v!),
        ),
        const SizedBox(height: 12),
        ListTile(
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.grey),
          ),
          leading: const Icon(Icons.schedule),
          title: Text(tx(c, 'Laikas', 'Time')),
          trailing: Text(
            time,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          onTap: () async {
            final p = time.split(':');
            final t = await showTimePicker(
              context: c,
              initialTime: TimeOfDay(
                hour: int.parse(p[0]),
                minute: int.parse(p[1]),
              ),
            );
            if (t != null)
              setState(
                () => time =
                    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
              );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: dateField(
                c,
                startDate,
                'Pradžios data YYYY-MM-DD',
                'Start date YYYY-MM-DD',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: dateField(
                c,
                endDate,
                'Pabaigos data (nebūtina)',
                'End date (optional)',
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tx(c, 'Savaitės dienos', 'Weekdays'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 6,
          children: List.generate(
            7,
            (i) => FilterChip(
              label: Text(daysLabel(c, [i + 1])),
              selected: days.contains(i + 1),
              onSelected: (v) => setState(() {
                if (v) {
                  days.add(i + 1);
                  days.sort();
                } else {
                  days.remove(i + 1);
                }
              }),
            ),
          ),
        ),
        const SizedBox(height: 12),
        field(c, dose, 'Dozės aprašymas', 'Dose description'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tx(c, 'Kiekis vienai dozei', 'Amount per dose'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('$medId-$doseUnit'),
                initialValue: doseUnit,
                decoration: InputDecoration(
                  labelText: tx(c, 'Vienetas', 'Unit'),
                ),
                items: medicineQuantityUnits
                    .map(
                      (unit) => DropdownMenuItem(
                        value: unit,
                        child: Text(doseUnitLabel(c, unit)),
                      ),
                    )
                    .toList(),
                onChanged: selectedMedicine == null
                    ? (value) => setState(() => doseUnit = value!)
                    : null,
              ),
            ),
          ],
        ),
        if (selectedMedicine != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tx(
                c,
                'Pažymėjus suvartojimą, pasirinktas kiekis bus atimtas iš „${selectedMedicine!.name}“ likučio (${doseUnitLabel(c, selectedMedicine!.stockUnit)}).',
                'When marked as taken, the selected amount will be deducted from “${selectedMedicine!.name}” stock (${doseUnitLabel(c, selectedMedicine!.stockUnit)}).',
              ),
              style: const TextStyle(color: Color(0xff526874)),
            ),
          ),
        const SizedBox(height: 12),
        field(
          c,
          instructions,
          'Instrukcija (pvz., po valgio)',
          'Instructions (e.g. after food)',
          lines: 2,
        ),
        SwitchListTile(
          value: enabled,
          onChanged: (v) => setState(() => enabled = v),
          title: Text(tx(c, 'Priminimas įjungtas', 'Reminder enabled')),
        ),
        FilledButton(
          onPressed: () async {
            final amount = double.tryParse(
              quantity.text.trim().replaceAll(',', '.'),
            );
            final start = DateTime.tryParse(startDate.text);
            final end = DateTime.tryParse(endDate.text);
            if (titleC.text.trim().isEmpty ||
                days.isEmpty ||
                amount == null ||
                amount <= 0 ||
                (startDate.text.isNotEmpty && start == null) ||
                (endDate.text.isNotEmpty && end == null) ||
                (start != null && end != null && end.isBefore(start))) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      c,
                      'Patikrink pavadinimą, datas, kiekį ir pasirink bent vieną dieną.',
                      'Check the title, dates, amount and select at least one day.',
                    ),
                  ),
                ),
              );
              return;
            }
            final r =
                widget.reminder ?? Reminder(id: newId(), title: '', time: time);
            r.title = titleC.text.trim();
            r.medId = medId;
            r.memberId = memberId;
            r.time = time;
            r.dose = dose.text.trim();
            r.doseUnit = selectedMedicine?.stockUnit ?? doseUnit;
            r.quantityPerDose = amount;
            r.instructions = instructions.text.trim();
            r.startDate = startDate.text.trim();
            r.endDate = endDate.text.trim();
            r.weekdays = [...days];
            r.enabled = enabled;
            if (widget.reminder == null) widget.data.reminders.add(r);
            widget.onChanged();
            await ReminderNotifications.scheduleAll(widget.data);
            if (!c.mounted) return;
            Navigator.pop(c);
          },
          child: Text(tx(c, 'Išsaugoti', 'Save')),
        ),
      ],
    ),
  );
}

Widget _profileToolTile(
  BuildContext c,
  IconData icon,
  String lt,
  String en,
  VoidCallback onTap,
) => Card(
  child: ListTile(
    leading: CircleAvatar(
      backgroundColor: mint,
      child: Icon(icon, color: green),
    ),
    title: Text(
      tx(c, lt, en),
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  ),
);

class DoseHistoryPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const DoseHistoryPage({
    super.key,
    required this.data,
    required this.onChanged,
  });
  @override
  State<DoseHistoryPage> createState() => _DoseHistoryPageState();
}

class _DoseHistoryPageState extends State<DoseHistoryPage> {
  String memberId = '';
  String medicineId = '';
  int periodDays = 30;

  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final entries = <(DateTime, Reminder, DoseStatus)>[];
    for (var offset = 0; offset < periodDays; offset++) {
      final day = DateTime(now.year, now.month, now.day - offset);
      for (final reminder in widget.data.reminders) {
        if (memberId.isNotEmpty && reminder.memberId != memberId) continue;
        if (medicineId.isNotEmpty && reminder.medId != medicineId) continue;
        if (!reminderAppliesOn(reminder, day)) continue;
        final key = dateKey(day);
        final status = reminder.takenDates.contains(key)
            ? DoseStatus.taken
            : reminder.skippedDates.contains(key)
            ? DoseStatus.skipped
            : day.isBefore(DateTime(now.year, now.month, now.day))
            ? DoseStatus.missed
            : reminderStatus(reminder, now);
        entries.add((day, reminder, status));
      }
    }
    final taken = entries.where((entry) => entry.$3 == DoseStatus.taken).length;
    final completed = entries
        .where(
          (entry) =>
              entry.$3 == DoseStatus.taken ||
              entry.$3 == DoseStatus.skipped ||
              entry.$3 == DoseStatus.missed,
        )
        .length;
    final percent = completed == 0 ? 0 : (taken * 100 / completed).round();
    return Scaffold(
      appBar: AppBar(title: Text(tx(c, 'Vartojimo istorija', 'Dose history'))),
      body: ListView(
        padding: scrollPagePadding(c),
        children: [
          DropdownButtonFormField<int>(
            initialValue: periodDays,
            decoration: InputDecoration(
              labelText: tx(c, 'Laikotarpis', 'Period'),
            ),
            items: [7, 30, 90]
                .map(
                  (days) => DropdownMenuItem(
                    value: days,
                    child: Text(tx(c, '$days dienų', '$days days')),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => periodDays = value ?? 30),
          ),
          const SizedBox(height: 8),
          if (widget.data.members.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: memberId,
              decoration: InputDecoration(
                labelText: tx(c, 'Šeimos narys', 'Family member'),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(tx(c, 'Visa šeima', 'Whole family')),
                ),
                ...widget.data.members.map(
                  (member) => DropdownMenuItem(
                    value: member.id,
                    child: Text(member.name),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => memberId = value ?? ''),
            ),
          const SizedBox(height: 8),
          if (widget.data.meds.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: medicineId,
              decoration: InputDecoration(
                labelText: tx(c, 'Vaistas', 'Medicine'),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(tx(c, 'Visi vaistai', 'All medicines')),
                ),
                ...widget.data.meds.map(
                  (medicine) => DropdownMenuItem(
                    value: medicine.id,
                    child: Text('${medicine.name} ${medicine.strength}'),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => medicineId = value ?? ''),
            ),
          const SizedBox(height: 12),
          card(
            Row(
              children: [
                const Icon(Icons.insights, color: green, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tx(
                      c,
                      'Per $periodDays dienų išgerta $taken iš $completed dozių ($percent %).',
                      '$taken of $completed doses taken in $periodDays days ($percent%).',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
          ...entries.map((entry) {
            final (day, reminder, status) = entry;
            final statusText = switch (status) {
              DoseStatus.taken => tx(c, 'Išgerta', 'Taken'),
              DoseStatus.skipped => tx(c, 'Praleista', 'Skipped'),
              DoseStatus.missed => tx(c, 'Neišgerta', 'Missed'),
              DoseStatus.late => tx(c, 'Vėluoja', 'Late'),
              _ => tx(c, 'Suplanuota', 'Scheduled'),
            };
            final color = status == DoseStatus.taken
                ? green
                : status == DoseStatus.upcoming
                ? const Color(0xff7b8ba1)
                : const Color(0xffc62828);
            return Card(
              child: ListTile(
                leading: Icon(
                  status == DoseStatus.taken
                      ? Icons.check_circle
                      : Icons.schedule,
                  color: color,
                ),
                title: Text(
                  '${DateFormat('yyyy-MM-dd').format(day)} • ${reminder.time} • ${reminder.title}',
                ),
                subtitle: Text(statusText),
                trailing: status == DoseStatus.taken
                    ? IconButton(
                        tooltip: tx(c, 'Atšaukti pažymėjimą', 'Undo'),
                        icon: const Icon(Icons.undo),
                        onPressed: () {
                          undoDoseTaken(widget.data, reminder, day);
                          widget.onChanged();
                          setState(() {});
                        },
                      )
                    : null,
              ),
            );
          }),
        ],
      ),
    );
  }
}

class ShoppingPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const ShoppingPage({super.key, required this.data, required this.onChanged});
  @override
  State<ShoppingPage> createState() => _ShoppingPageState();
}

class _ShoppingPageState extends State<ShoppingPage> {
  Future<void> _editItem([ShoppingItem? item]) async {
    final name = TextEditingController(text: item?.name ?? '');
    final quantity = TextEditingController(
      text: quantityLabel(item?.quantity ?? 1),
    );
    var prescription = item?.prescription ?? false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(item == null
              ? tx(context, 'Pridėti į sąrašą', 'Add to list')
              : tx(context, 'Redaguoti pirkinį', 'Edit item')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(context, name, 'Vaistas ar prekė', 'Medicine or item'),
              field(context, quantity, 'Kiekis', 'Quantity', number: true),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: prescription,
                title: Text(
                  tx(context, 'Reikalingas receptas', 'Prescription required'),
                ),
                onChanged: (value) =>
                    setDialogState(() => prescription = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tx(context, 'Atšaukti', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final value = double.tryParse(
                  quantity.text.replaceAll(',', '.'),
                );
                if (name.text.trim().isEmpty || value == null || value <= 0)
                  return;
                if (item == null) {
                  final duplicate = widget.data.shopping
                      .where((existing) =>
                          !existing.purchased &&
                          existing.name.toLowerCase() ==
                              name.text.trim().toLowerCase())
                      .firstOrNull;
                  if (duplicate == null) {
                    widget.data.shopping.add(ShoppingItem(
                      id: newId(),
                      name: name.text.trim(),
                      quantity: value,
                      prescription: prescription,
                    ));
                  } else {
                    duplicate.quantity += value;
                    duplicate.prescription =
                        duplicate.prescription || prescription;
                  }
                } else {
                  final delta = value - item.quantity;
                  if (item.purchased) _adjustMedicineStock(item, delta);
                  item
                    ..name = name.text.trim()
                    ..quantity = value
                    ..prescription = prescription;
                }
                widget.onChanged();
                Navigator.pop(dialogContext);
                setState(() {});
              },
              child: Text(item == null
                  ? tx(context, 'Pridėti', 'Add')
                  : tx(context, 'Išsaugoti', 'Save')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    quantity.dispose();
  }

  void _adjustMedicineStock(ShoppingItem item, double delta) {
    final medicine = widget.data.meds
        .where((med) => med.id == item.medId)
        .firstOrNull;
    if (medicine != null) {
      medicine.stock = (medicine.stock + delta)
          .clamp(0, double.infinity)
          .toDouble();
    }
  }

  void _changeQuantity(ShoppingItem item, double delta) {
    final next = (item.quantity + delta).clamp(1, 999).toDouble();
    final applied = next - item.quantity;
    if (applied == 0) return;
    if (item.purchased) _adjustMedicineStock(item, applied);
    item.quantity = next;
    widget.onChanged();
    setState(() {});
  }

  void _setPurchased(ShoppingItem item, bool purchased) {
    if (item.purchased == purchased) return;
    _adjustMedicineStock(item, purchased ? item.quantity : -item.quantity);
    item.purchased = purchased;
    widget.onChanged();
    setState(() {});
  }

  void _addLowStock() {
    for (final medicine in widget.data.meds.where(
      (medicine) => medicine.stock <= medicine.lowStockThreshold,
    )) {
      if (widget.data.shopping.any(
        (item) => item.medId == medicine.id && !item.purchased,
      ))
        continue;
      widget.data.shopping.add(
        ShoppingItem(
          id: newId(),
          medId: medicine.id,
          name: '${medicine.name} ${medicine.strength}'.trim(),
          prescription: medicine.prescription,
        ),
      );
    }
    widget.onChanged();
    setState(() {});
  }

  Future<void> _clearPurchased() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tx(context, 'Išvalyti nupirktus?', 'Clear purchased items?')),
        content: Text(tx(
          context,
          'Nupirkti įrašai bus pašalinti iš sąrašo. Vaistų likučiai išliks papildyti.',
          'Purchased entries will be removed. Updated medicine stock will remain.',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tx(context, 'Atšaukti', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tx(context, 'Išvalyti', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.data.shopping.removeWhere((item) => item.purchased);
    widget.onChanged();
    setState(() {});
  }

  Widget _shoppingCard(BuildContext c, ShoppingItem item) => Card(
    child: Column(
      children: [
        CheckboxListTile(
          value: item.purchased,
          title: Text(
            item.name,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              decoration: item.purchased ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: item.prescription
              ? Text(tx(c, 'Reikalingas receptas', 'Prescription required'))
              : null,
          secondary: IconButton(
            tooltip: tx(c, 'Redaguoti', 'Edit'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _editItem(item),
          ),
          onChanged: (checked) => _setPurchased(item, checked ?? false),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: tx(c, 'Ištrinti', 'Delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  widget.data.shopping.remove(item);
                  widget.onChanged();
                  setState(() {});
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: tx(c, 'Sumažinti', 'Decrease'),
                onPressed: () => _changeQuantity(item, -1),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text(
                quantityLabel(item.quantity),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              IconButton(
                tooltip: tx(c, 'Padidinti', 'Increase'),
                onPressed: () => _changeQuantity(item, 1),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Pirkinių sąrašas', 'Shopping list'))),
    body: ListView(
      padding: scrollPagePadding(c),
      children: [
        OutlinedButton.icon(
          onPressed: _addLowStock,
          icon: const Icon(Icons.playlist_add),
          label: Text(
            tx(c, 'Įtraukti mažo likučio vaistus', 'Add low-stock medicines'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _editItem,
          icon: const Icon(Icons.add_shopping_cart),
          label: Text(tx(c, 'Pridėti rankiniu būdu', 'Add manually')),
        ),
        if (widget.data.shopping.isEmpty)
          card(
            Text(tx(c, 'Pirkinių sąrašas tuščias.', 'Shopping list is empty.')),
          ),
        if (widget.data.shopping.any((item) => !item.purchased)) ...[
          const SizedBox(height: 14),
          Text(tx(c, 'Reikia nupirkti', 'To buy'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ...widget.data.shopping
              .where((item) => !item.purchased)
              .map((item) => _shoppingCard(c, item)),
        ],
        if (widget.data.shopping.any((item) => item.purchased)) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(tx(c, 'Nupirkta', 'Purchased'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton.icon(
                onPressed: _clearPurchased,
                icon: const Icon(Icons.cleaning_services_outlined),
                label: Text(tx(c, 'Išvalyti', 'Clear')),
              ),
            ],
          ),
          ...widget.data.shopping
              .where((item) => item.purchased)
              .map((item) => _shoppingCard(c, item)),
        ],
      ],
    ),
  );
}

List<Reminder> _summaryReminders(AppData data, String memberId) => data.reminders
    .where(
      (item) =>
          memberId.isEmpty || reminderMatchesMember(data, item, memberId),
    )
    .toList();

List<Med> _summaryMedicines(AppData data, String memberId) {
  if (memberId.isEmpty) return data.meds;
  final reminderMedicineIds = data.reminders
      .where(
        (item) =>
            reminderMatchesMember(data, item, memberId) &&
            item.medId.isNotEmpty,
      )
      .map((item) => item.medId)
      .toSet();
  return data.meds
      .where(
        (medicine) =>
            medicine.memberIds.contains(memberId) ||
            reminderMedicineIds.contains(medicine.id),
      )
      .toList();
}

class _DosePeriodStats {
  final int planned, taken;
  final double consumed;
  final List<double> dailyPercent;
  const _DosePeriodStats({
    required this.planned,
    required this.taken,
    required this.consumed,
    required this.dailyPercent,
  });
  int get percent => planned == 0 ? 0 : (taken * 100 / planned).round();
}

_DosePeriodStats _dosePeriodStats(
  AppData data,
  String memberId,
  int periodDays,
) {
  final reminders = _summaryReminders(data, memberId);
  final now = DateTime.now();
  var planned = 0;
  var taken = 0;
  var consumed = 0.0;
  final daily = <double>[];
  for (var offset = periodDays - 1; offset >= 0; offset--) {
    final day = DateTime(now.year, now.month, now.day - offset);
    final key = dateKey(day);
    var dayPlanned = 0;
    var dayTaken = 0;
    for (final reminder in reminders) {
      if (!reminderAppliesOn(reminder, day)) continue;
      if (dateKey(day) == dateKey(now) &&
          reminderStatus(reminder, now) == DoseStatus.upcoming) {
        continue;
      }
      dayPlanned++;
      if (reminder.takenDates.contains(key)) {
        dayTaken++;
        consumed += reminder.quantityPerDose;
      }
    }
    planned += dayPlanned;
    taken += dayTaken;
    daily.add(dayPlanned == 0 ? 0 : dayTaken / dayPlanned);
  }
  return _DosePeriodStats(
    planned: planned,
    taken: taken,
    consumed: consumed,
    dailyPercent: daily,
  );
}

double _consumedMedicineAmount(
  AppData data,
  String memberId,
  String medicineId,
  int periodDays,
) {
  final firstDay = DateTime.now().subtract(Duration(days: periodDays - 1));
  var consumed = 0.0;
  for (final reminder in _summaryReminders(data, memberId)) {
    if (reminder.medId != medicineId) continue;
    for (final key in reminder.takenDates) {
      final day = DateTime.tryParse(key);
      if (day != null && !day.isBefore(DateTime(firstDay.year, firstDay.month, firstDay.day))) {
        consumed += reminder.quantityPerDose;
      }
    }
  }
  return consumed;
}

String _doctorSummary(AppData data, String memberId, int periodDays) {
  final member = data.members.where((item) => item.id == memberId).firstOrNull;
  if (member == null) return '';
  final medicines = _summaryMedicines(data, memberId);
  final prescriptions = medicines.where((item) => item.prescription).toList();
  final stats = _dosePeriodStats(data, memberId, periodDays);
  final buffer = StringBuffer('MEDIBOX – SVEIKATOS SANTRAUKA\n\n')
    ..writeln('ASMUO: ${member.name}')
    ..writeln('Gimimo data: ${member.birthDate}')
    ..writeln('Kraujo grupė: ${member.bloodType}')
    ..writeln('Alergijos: ${member.allergies}')
    ..writeln('Sveikatos būklės: ${member.conditions}')
    ..writeln('Netoleruojami vaistai: ${member.intolerantMedicines}');
  if (member.id == data.linkedMemberId) {
    buffer.writeln(
      'Skubios pagalbos kontaktas: ${data.profile.emergencyName} ${data.profile.emergencyPhone}',
    );
  }
  buffer
    ..writeln('\nVARTOJIMO SUVESTINĖ ($periodDays D.)')
    ..writeln(
      'Pažymėta išgerta: ${stats.taken} iš ${stats.planned} dozių (${stats.percent} %)',
    )
    ..writeln('Pažymėtas suvartotas kiekis: ${quantityLabel(stats.consumed)} vnt.')
    ..writeln('\nPRISKIRTI VAISTAI');
  if (medicines.isEmpty) buffer.writeln('• Nėra priskirtų vaistų');
  for (final medicine in medicines) {
    buffer.writeln(
      '• ${medicine.name} ${medicine.strength}'
      '${medicine.dosage.isEmpty ? '' : ' – ${medicine.dosage}'}',
    );
  }
  buffer.writeln('\nRECEPTINIAI VAISTAI IR RECEPTŲ GALIOJIMAS');
  if (prescriptions.isEmpty) buffer.writeln('• Duomenų nėra');
  for (final medicine in prescriptions) {
    buffer.writeln(
      '• ${medicine.name} ${medicine.strength} – ${medicine.prescriptionValidUntil.isEmpty ? 'galiojimo data neįvesta' : 'galioja iki ${medicine.prescriptionValidUntil}'}',
    );
  }
  final upcoming = data.appointments.where((item) {
    final at = DateTime.tryParse('${item.date}T${item.time}');
    return item.memberId == memberId &&
        !item.completed &&
        at != null &&
        at.isAfter(DateTime.now());
  }).toList()..sort(
    (a, b) => '${a.date}${a.time}'.compareTo('${b.date}${b.time}'),
  );
  if (upcoming.isNotEmpty) {
    buffer.writeln('\nARTĖJANTYS VIZITAI');
    for (final item in upcoming) {
      buffer.writeln(
        '• ${item.date} ${item.time} – ${item.title}'
        '${item.doctor.isEmpty ? '' : ', ${item.doctor}'}'
        '${item.facility.isEmpty ? '' : ', ${item.facility}'}',
      );
    }
  }
  buffer
    ..writeln('\nPastaba: suvartojimas skaičiuojamas tik iš programėlėje pažymėtų dozių.')
    ..writeln('Sukurta: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
  return buffer.toString();
}

class DoctorSummaryPage extends StatefulWidget {
  final AppData data;
  const DoctorSummaryPage({super.key, required this.data});
  @override
  State<DoctorSummaryPage> createState() => _DoctorSummaryPageState();
}

class _DoctorSummaryPageState extends State<DoctorSummaryPage> {
  late String memberId;
  int periodDays = 30;
  bool household = false;

  @override
  void initState() {
    super.initState();
    memberId = widget.data.members.any(
      (member) => member.id == widget.data.linkedMemberId,
    )
        ? widget.data.linkedMemberId
        : widget.data.members.firstOrNull?.id ?? '';
  }

  @override
  Widget build(BuildContext c) {
    final data = widget.data;
    final stats = _dosePeriodStats(data, household ? '' : memberId, periodDays);
    final medicines = _summaryMedicines(data, household ? '' : memberId);
    final prescriptionMedicines = medicines
        .where((item) => item.prescription)
        .toList();
    final lowStock = medicines
        .where((item) => item.stock < item.lowStockThreshold)
        .length;
    final summary = household ? '' : _doctorSummary(data, memberId, periodDays);
    return Scaffold(
      appBar: AppBar(
        title: Text(tx(c, 'Sveikatos suvestinė', 'Health summary')),
      ),
      body: ListView(
        padding: scrollPagePadding(c),
        children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                label: Text(tx(c, 'Asmuo', 'Person')),
                icon: const Icon(Icons.person_outline),
              ),
              ButtonSegment(
                value: true,
                label: Text(tx(c, 'Namų ūkis', 'Household')),
                icon: const Icon(Icons.groups_outlined),
              ),
            ],
            selected: {household},
            onSelectionChanged: (value) =>
                setState(() => household = value.first),
          ),
          const SizedBox(height: 12),
          if (!household && data.members.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: memberId,
              decoration: InputDecoration(
                labelText: tx(c, 'Šeimos narys', 'Family member'),
              ),
              items: data.members
                  .map(
                    (member) => DropdownMenuItem(
                      value: member.id,
                      child: Text(member.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => memberId = value ?? ''),
            ),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7 d.')),
              ButtonSegment(value: 30, label: Text('30 d.')),
              ButtonSegment(value: 90, label: Text('90 d.')),
            ],
            selected: {periodDays},
            onSelectionChanged: (value) =>
                setState(() => periodDays = value.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _summaryMetric(
                  tx(c, 'Išgerta', 'Taken'),
                  '${stats.percent} %',
                  Icons.check_circle_outline,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _summaryMetric(
                  tx(c, 'Suvartota', 'Consumed'),
                  '${quantityLabel(stats.consumed)} ${tx(c, 'vnt.', 'units')}',
                  Icons.medication_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _summaryMetric(
                  tx(c, 'Receptiniai', 'Prescription'),
                  '${prescriptionMedicines.length}',
                  Icons.receipt_long_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _summaryMetric(
                  tx(c, 'Mažas likutis', 'Low stock'),
                  '$lowStock',
                  Icons.warning_amber_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(c, 'Dozių laikymosi kreivė', 'Dose adherence trend'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 150,
                  child: CustomPaint(
                    painter: _AdherenceChartPainter(stats.dailyPercent),
                    child: const SizedBox.expand(),
                  ),
                ),
                Text(
                  tx(
                    c,
                    'Kreivė paremta programėlėje pažymėtomis dozėmis.',
                    'The trend uses doses marked in the app.',
                  ),
                  style: const TextStyle(fontSize: 12, color: Color(0xff60747f)),
                ),
              ],
            ),
          ),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(
                    c,
                    'Suvartojimas pagal vaistą',
                    'Consumption by medicine',
                  ),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                if (medicines.isEmpty)
                  Text(tx(c, 'Vaistų nepriskirta.', 'No medicines assigned.')),
                ...medicines.map(
                  (medicine) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.medication_outlined, color: green),
                    title: Text('${medicine.name} ${medicine.strength}'.trim()),
                    subtitle: Text(
                      tx(
                        c,
                        'Likutis: ${quantityLabel(medicine.stock)} ${doseUnitLabel(c, medicine.stockUnit)}',
                        'Stock: ${quantityLabel(medicine.stock)} ${doseUnitLabel(c, medicine.stockUnit)}',
                      ),
                    ),
                    trailing: Text(
                      '${quantityLabel(_consumedMedicineAmount(data, household ? '' : memberId, medicine.id, periodDays))} ${doseUnitLabel(c, medicine.stockUnit)}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(
                    c,
                    'Receptiniai vaistai ir receptų galiojimas',
                    'Prescription medicines and validity',
                  ),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                if (prescriptionMedicines.isEmpty)
                  Text(tx(c, 'Duomenų nėra.', 'No data.')),
                ...prescriptionMedicines.map(
                  (medicine) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_long_outlined, color: green),
                    title: Text('${medicine.name} ${medicine.strength}'.trim()),
                    subtitle: Text(
                      medicine.prescriptionValidUntil.isEmpty
                          ? tx(
                              c,
                              'Recepto galiojimo data neįvesta',
                              'Prescription validity not entered',
                            )
                          : tx(
                              c,
                              'Receptas galioja iki ${medicine.prescriptionValidUntil}',
                              'Prescription valid until ${medicine.prescriptionValidUntil}',
                            ),
                  ),
                ),
                ),
              ],
            ),
          ),
          if (household) ...[
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx(c, 'Namų ūkio situacija', 'Household situation'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tx(
                      c,
                      '${data.members.length} nariai • ${medicines.length} vaistai • ${stats.taken}/${stats.planned} išgertų dozių',
                      '${data.members.length} members • ${medicines.length} medicines • ${stats.taken}/${stats.planned} doses taken',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const Divider(),
                  ...data.members.map((member) {
                    final memberStats = _dosePeriodStats(
                      data,
                      member.id,
                      periodDays,
                    );
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Text(
                        _memberEmoji(member.gender, member.ageGroup),
                        style: const TextStyle(fontSize: 26),
                      ),
                      title: Text(member.name),
                      subtitle: Text(
                        '${memberStats.taken}/${memberStats.planned} ${tx(c, 'dozių', 'doses')}',
                      ),
                      trailing: Text(
                        '${memberStats.percent} %',
                        style: const TextStyle(
                          color: green,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ] else if (summary.isNotEmpty) ...[
            card(SelectableText(summary)),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: summary));
                if (c.mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(
                    SnackBar(
                      content: Text(
                        tx(c, 'Santrauka nukopijuota.', 'Summary copied.'),
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy),
              label: Text(tx(c, 'Kopijuoti santrauką', 'Copy summary')),
            ),
          ],
        ],
      ),
    );
  }
}

Widget _summaryMetric(String label, String value, IconData icon) => Card(
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        Icon(icon, color: green),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: navy,
          ),
        ),
        Text(label, textAlign: TextAlign.center),
      ],
    ),
  ),
);

class _AdherenceChartPainter extends CustomPainter {
  final List<double> values;
  const _AdherenceChartPainter(this.values);
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xffdce8e5)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1 ? 0.0 : size.width * i / (values.length - 1);
      final y = size.height * (1 - values[i].clamp(0, 1));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = green
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }
  @override
  bool shouldRepaint(covariant _AdherenceChartPainter oldDelegate) =>
      oldDelegate.values != values;
}

class EmergencyInfoPage extends StatelessWidget {
  final AppData data;
  const EmergencyInfoPage({super.key, required this.data});
  @override
  Widget build(BuildContext c) {
    final p = data.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(tx(c, 'Kritinė informacija', 'Emergency information')),
      ),
      body: ListView(
        padding: scrollPagePadding(c),
        children: [
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    color: navy,
                  ),
                ),
                const Divider(),
                Text('${tx(c, 'Kraujo grupė', 'Blood type')}: ${p.bloodType}'),
                Text('${tx(c, 'Alergijos', 'Allergies')}: ${p.allergies}'),
                Text('${tx(c, 'Būklės', 'Conditions')}: ${p.conditions}'),
                Text(
                  '${tx(c, 'Vaistai', 'Medicines')}: ${data.meds.map((m) => '${m.name} ${m.strength}').join(', ')}',
                ),
                const Divider(),
                Text('${tx(c, 'Kontaktas', 'Contact')}: ${p.emergencyName}'),
                SelectableText(
                  p.emergencyPhone,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _backupMap(AppData data) => {
  'format': 'medibox-backup-v1',
  'createdAt': DateTime.now().toIso8601String(),
  'meds': data.meds.map((item) => item.toJson()).toList(),
  'members': data.members.map((item) => item.toJson()).toList(),
  'reminders': data.reminders.map((item) => item.toJson()).toList(),
  'shopping': data.shopping.map((item) => item.toJson()).toList(),
  'appointments': data.appointments.map((item) => item.toJson()).toList(),
  'profile': data.profile.toJson(),
  'language': data.language,
  'privacyLock': data.privacyLock,
};

class DataTransferPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const DataTransferPage({
    super.key,
    required this.data,
    required this.onChanged,
  });
  @override
  State<DataTransferPage> createState() => _DataTransferPageState();
}

class _DataTransferPageState extends State<DataTransferPage> {
  final importController = TextEditingController();
  @override
  void dispose() {
    importController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: Text(tx(c, 'Atsarginė kopija', 'Backup and restore')),
    ),
    body: ListView(
      padding: scrollPagePadding(c),
      children: [
        card(
          Text(
            tx(
              c,
              'Kopijoje yra vaistai, šeimos nariai, priminimai, istorija, profilis ir pirkinių sąrašas. Saugokite ją privačiai.',
              'The backup contains medicines, family, reminders, history, profile and shopping data. Keep it private.',
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: jsonEncode(_backupMap(widget.data))),
            );
            if (c.mounted)
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(c, 'Atsarginė kopija nukopijuota.', 'Backup copied.'),
                  ),
                ),
              );
          },
          icon: const Icon(Icons.copy_all),
          label: Text(tx(c, 'Kopijuoti atsarginę kopiją', 'Copy backup')),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: importController,
          minLines: 4,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: tx(c, 'Įklijuokite atsarginę kopiją', 'Paste backup'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            try {
              final decoded = Map<String, dynamic>.from(
                jsonDecode(importController.text),
              );
              if (decoded['format'] != 'medibox-backup-v1')
                throw const FormatException();
              widget.data.meds = (decoded['meds'] as List)
                  .map((x) => Med.fromJson(Map<String, dynamic>.from(x)))
                  .toList();
              widget.data.members = (decoded['members'] as List)
                  .map((x) => Member.fromJson(Map<String, dynamic>.from(x)))
                  .toList();
              widget.data.reminders = (decoded['reminders'] as List)
                  .map((x) => Reminder.fromJson(Map<String, dynamic>.from(x)))
                  .toList();
              widget.data.shopping = (decoded['shopping'] as List? ?? [])
                  .map(
                    (x) => ShoppingItem.fromJson(Map<String, dynamic>.from(x)),
                  )
                  .toList();
              widget.data.appointments =
                  (decoded['appointments'] as List? ?? [])
                      .map(
                        (x) => HealthAppointment.fromJson(
                          Map<String, dynamic>.from(x),
                        ),
                      )
                      .toList();
              widget.data.profile = UserProfile.fromJson(
                Map<String, dynamic>.from(decoded['profile']),
              );
              widget.data.language = '${decoded['language'] ?? 'system'}';
              widget.data.privacyLock = decoded['privacyLock'] == true;
              widget.onChanged();
              if (c.mounted)
                ScaffoldMessenger.of(c).showSnackBar(
                  SnackBar(
                    content: Text(tx(c, 'Duomenys atkurti.', 'Data restored.')),
                  ),
                );
            } catch (_) {
              if (c.mounted)
                ScaffoldMessenger.of(c).showSnackBar(
                  SnackBar(
                    content: Text(
                      tx(c, 'Netinkama atsarginė kopija.', 'Invalid backup.'),
                    ),
                  ),
                );
            }
          },
          icon: const Icon(Icons.restore),
          label: Text(tx(c, 'Atkurti duomenis', 'Restore data')),
        ),
      ],
    ),
  );
}

class CloudAccountPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const CloudAccountPage({super.key, required this.data, required this.onChanged});
  @override
  State<CloudAccountPage> createState() => _CloudAccountPageState();
}

class _CloudAccountPageState extends State<CloudAccountPage> {
  bool busy = false;
  String message = '';

  Future<void> _run(Future<void> Function() action) async {
    setState(() { busy = true; message = ''; });
    try {
      await action();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => message = CloudSyncService.instance.readableError(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = CloudSyncService.instance.user;
    final signedIn = account != null;
    return Scaffold(
      appBar: AppBar(title: Text(tx(context, 'Google paskyra ir sinchronizavimas', 'Google account and sync'))),
      body: ListView(
        padding: scrollPagePadding(context),
        children: [
          card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: mint,
                backgroundImage: account?.photoURL == null ? null : NetworkImage(account!.photoURL!),
                child: account?.photoURL == null ? const Icon(Icons.account_circle_outlined, color: green, size: 31) : null,
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(signedIn ? (account.displayName ?? tx(context, 'Google naudotojas', 'Google user')) : tx(context, 'Neprisijungta', 'Signed out'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                if (signedIn) Text(account.email ?? '', style: const TextStyle(color: Color(0xff526874))),
              ])),
              Icon(signedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: signedIn ? green : Colors.grey),
            ]),
            const SizedBox(height: 12),
            Text(tx(context, 'Sinchronizuojami vaistai, jų nuotraukos, šeimos nariai, priminimai, vartojimo istorija, vizitai, profilis ir pirkinių sąrašas.', 'Medicines, photos, family members, reminders, dose history, appointments, profile and shopping list are synchronized.')),
          ])),
          if (message.isNotEmpty) ...[const SizedBox(height: 10), Text(message, style: const TextStyle(color: Colors.red))],
          const SizedBox(height: 14),
          if (!signedIn)
            FilledButton.icon(
              onPressed: busy ? null : () => _run(() async {
                await CloudSyncService.instance.signIn(widget.data, onRemoteApplied: () async => widget.onChanged());
                widget.onChanged();
              }),
              icon: const Icon(Icons.login),
              label: Text(tx(context, 'Prisijungti su Google', 'Sign in with Google')),
            )
          else ...[
            FilledButton.icon(
              onPressed: busy ? null : () => _run(() async {
                await CloudSyncService.instance.syncNow(widget.data);
                setState(() => message = tx(context, 'Duomenys sinchronizuoti.', 'Data synchronized.'));
              }),
              icon: const Icon(Icons.sync),
              label: Text(tx(context, 'Sinchronizuoti dabar', 'Sync now')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () async {
                if (!await requirePremium(context) || !context.mounted) return;
                await Navigator.push(context, MaterialPageRoute(builder: (_) => HouseholdSettingsPage(data: widget.data, onChanged: widget.onChanged)));
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.family_restroom),
              label: Text(tx(context, 'Šeimos bendrinimas', 'Family sharing')),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: busy ? null : () => _run(() async {
                await CloudSyncService.instance.signOut();
                widget.onChanged();
              }),
              icon: const Icon(Icons.logout),
              label: Text(tx(context, 'Atsijungti', 'Sign out')),
            ),
            const Divider(height: 30),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: busy ? null : () async {
                final confirmed = await confirmDelete(context, tx(context, 'Google paskyrą ir debesies duomenis', 'Google account and cloud data'));
                if (!confirmed || !mounted) return;
                await _run(() async {
                  await CloudSyncService.instance.deleteAccountAndCloudData(widget.data);
                  widget.onChanged();
                });
              },
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text(tx(context, 'Ištrinti paskyrą ir debesies duomenis', 'Delete account and cloud data')),
            ),
          ],
          if (busy) const Padding(padding: EdgeInsets.only(top: 14), child: LinearProgressIndicator()),
        ],
      ),
    );
  }
}

class HouseholdSettingsPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const HouseholdSettingsPage({super.key, required this.data, required this.onChanged});
  @override
  State<HouseholdSettingsPage> createState() => _HouseholdSettingsPageState();
}

class _HouseholdSettingsPageState extends State<HouseholdSettingsPage> {
  final householdName = TextEditingController(text: 'Mano namai');
  final inviteCode = TextEditingController();
  bool shareExisting = true;
  bool busy = false;
  String error = '';
  HouseholdInfo? info;

  @override
  void initState() {
    super.initState();
    if (widget.data.householdId.isNotEmpty) _load();
  }

  @override
  void dispose() {
    householdName.dispose();
    inviteCode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await CloudSyncService.instance.householdInfo(widget.data);
      if (mounted) setState(() => info = value);
    } catch (e) {
      if (mounted) setState(() => error = CloudSyncService.instance.readableError(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() { busy = true; error = ''; });
    try {
      await action();
      widget.onChanged();
      if (widget.data.householdId.isNotEmpty) await _load();
    } catch (e) {
      if (mounted) setState(() => error = CloudSyncService.instance.readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tx(context, 'Šeimos bendrinimas', 'Family sharing'))),
    body: ListView(
      padding: scrollPagePadding(context),
      children: widget.data.householdId.isEmpty ? _setup(context) : _manage(context),
    ),
  );

  List<Widget> _setup(BuildContext context) => [
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tx(context, 'Sukurti namų ūkį', 'Create a household'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(tx(context, 'Bendra vaistinėlė, šeimos nariai, priminimai, pirkinių sąrašas ir kalendorius bus matomi prisijungusiems šeimos nariams.', 'The shared cabinet, family members, reminders, shopping list and calendar will be visible to joined family members.')),
      const SizedBox(height: 12),
      TextField(controller: householdName, decoration: InputDecoration(labelText: tx(context, 'Namų ūkio pavadinimas', 'Household name'))),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: shareExisting,
        onChanged: (value) => setState(() => shareExisting = value ?? true),
        title: Text(tx(context, 'Perkelti dabartinius duomenis', 'Move current data')),
      ),
      FilledButton(
        onPressed: busy ? null : () => _run(() async {
          if (householdName.text.trim().isEmpty) throw StateError('name_required');
          info = await CloudSyncService.instance.createHousehold(householdName.text, widget.data, shareExistingData: shareExisting, onRemoteApplied: () async => widget.onChanged());
        }),
        child: Text(tx(context, 'Sukurti bendrą vaistinėlę', 'Create shared cabinet')),
      ),
    ])),
    const SizedBox(height: 14),
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tx(context, 'Prisijungti su kodu', 'Join with a code'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      TextField(
        controller: inviteCode,
        textCapitalization: TextCapitalization.characters,
        maxLength: 8,
        decoration: InputDecoration(labelText: tx(context, '8 simbolių kvietimo kodas', '8-character invite code')),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: shareExisting,
        onChanged: (value) => setState(() => shareExisting = value ?? true),
        title: Text(tx(context, 'Pridėti mano dabartinius duomenis į bendrą erdvę', 'Add my current data to the shared space')),
      ),
      FilledButton(
        onPressed: busy ? null : () => _run(() async {
          info = await CloudSyncService.instance.joinHousehold(inviteCode.text, widget.data, shareExistingData: shareExisting, onRemoteApplied: () async => widget.onChanged());
        }),
        child: Text(tx(context, 'Prisijungti', 'Join')),
      ),
    ])),
    if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error, style: const TextStyle(color: Colors.red))),
    if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
  ];

  List<Widget> _manage(BuildContext context) => [
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(info?.name ?? widget.data.householdName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(widget.data.householdRole == 'owner' ? tx(context, 'Administratorius', 'Administrator') : tx(context, 'Šeimos narys', 'Family member')),
      if (widget.data.householdRole == 'owner') ...[
        const Divider(height: 28),
        Text(tx(context, 'Kvietimo kodas', 'Invite code'), style: const TextStyle(fontWeight: FontWeight.w700)),
        SelectableText(info?.inviteCode ?? '••••••••', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3, color: green)),
        Text(tx(context, 'Kodą siųskite tik šeimos nariui. Jį bet kada galite pakeisti.', 'Share the code only with a family member. You can replace it at any time.')),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: busy ? null : () => _run(() async {
            await CloudSyncService.instance.regenerateInvite(widget.data);
          }),
          icon: const Icon(Icons.refresh),
          label: Text(tx(context, 'Sugeneruoti naują kodą', 'Generate a new code')),
        ),
      ],
    ])),
    const SizedBox(height: 14),
    Text(tx(context, 'Prisijungus nariai', 'Connected members'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
    const SizedBox(height: 6),
    if (info == null) const LinearProgressIndicator() else ...info!.accounts.map((account) => Card(child: ListTile(
      leading: const CircleAvatar(backgroundColor: mint, child: Icon(Icons.person_outline, color: green)),
      title: Text(account['name']!.isEmpty ? account['email']! : account['name']!),
      subtitle: account['name']!.isEmpty ? null : Text(account['email']!),
      trailing: widget.data.householdRole == 'owner' && account['uid'] != CloudSyncService.instance.user?.uid
          ? PopupMenuButton<String>(
              onSelected: (_) => _run(() async {
                await CloudSyncService.instance.transferOwnership(account['uid']!, widget.data);
              }),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'owner',
                  child: Text(tx(context, 'Padaryti administratoriumi', 'Make administrator')),
                ),
              ],
            )
          : null,
    ))),
    if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error, style: const TextStyle(color: Colors.red))),
    const SizedBox(height: 18),
    OutlinedButton.icon(
      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
      onPressed: busy ? null : () async {
        final confirmed = await confirmDelete(context, tx(context, 'bendrinimą šiame namų ūkyje', 'sharing in this household'));
        if (!confirmed || !mounted) return;
        await _run(() async {
          await CloudSyncService.instance.leaveHousehold(widget.data, onRemoteApplied: () async => widget.onChanged());
          if (mounted) Navigator.pop(context);
        });
      },
      icon: const Icon(Icons.exit_to_app),
      label: Text(tx(context, 'Išeiti iš namų ūkio', 'Leave household')),
    ),
    if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
  ];
}

class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tx(context, 'Planai', 'Plans'))),
    body: AnimatedBuilder(
      animation: SubscriptionService.instance,
      builder: (context, _) {
        final service = SubscriptionService.instance;
        final entitlement = service.entitlement;
        final plan = entitlement.effectivePlan;
        final user = CloudSyncService.instance.user;
        final validUntil = entitlement.validUntil;
        return ListView(
          padding: scrollPagePadding(context),
          children: [
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: plan == SubscriptionPlan.free
                            ? const Color(0xffeef3f2)
                            : mint,
                        child: Icon(
                          Icons.workspace_premium_rounded,
                          color: plan == SubscriptionPlan.free
                              ? Colors.grey
                              : green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tx(context, 'Dabartinis planas', 'Current plan'),
                              style: const TextStyle(color: Color(0xff526874)),
                            ),
                            Text(
                              service.loading
                                  ? tx(context, 'Tikrinama…', 'Checking…')
                                  : subscriptionPlanLabel(context, plan),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: navy,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: tx(context, 'Atnaujinti', 'Refresh'),
                        onPressed: service.loading ? null : service.refresh,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  if (validUntil != null && entitlement.plan != SubscriptionPlan.free) ...[
                    const SizedBox(height: 10),
                    Text(
                      '${tx(context, 'Galioja iki', 'Valid until')}: '
                      '${DateFormat.yMMMd(Localizations.localeOf(context).languageCode).format(validUntil.toLocal())}',
                    ),
                  ],
                  if (user == null) ...[
                    const SizedBox(height: 10),
                    Text(
                      tx(
                        context,
                        'Prisijunkite su „Google“, kad planas būtų susietas su jūsų paskyra.',
                        'Sign in with Google to link the plan to your account.',
                      ),
                    ),
                  ],
                  if (service.message.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      tx(
                        context,
                        'Plano patikrinti nepavyko. Saugumo sumetimais taikomas „Free“ planas.',
                        'The plan could not be checked. Free is applied for security.',
                      ),
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _subscriptionPlanCard(
              context,
              title: 'Free',
              price: '0 €',
              selected: plan == SubscriptionPlan.free,
              features: [
                tx(context, 'Asmeninė vaistinėlė', 'Personal medicine cabinet'),
                tx(context, 'Vaistų ir vizitų priminimai', 'Medicine and appointment reminders'),
                tx(context, 'Kalendorius, likučiai ir galiojimas', 'Calendar, stock and expiry'),
                tx(context, 'Vienas asmeninis profilis', 'One personal profile'),
              ],
            ),
            _subscriptionPlanCard(
              context,
              title: tx(context, 'Premium mėnesinis', 'Premium monthly'),
              price: tx(context, '1,99 € / mėn.', '€1.99 / month'),
              selected: plan == SubscriptionPlan.premiumMonthly,
              features: _premiumFeatures(context),
            ),
            _subscriptionPlanCard(
              context,
              title: tx(context, 'Premium metinis', 'Premium yearly'),
              price: tx(context, '19,99 € / metus', '€19.99 / year'),
              selected: plan == SubscriptionPlan.premiumYearly,
              badge: tx(context, '2 mėn. nemokamai', '2 months free'),
              features: _premiumFeatures(context),
            ),
            const SizedBox(height: 8),
            if (entitlement.hasPremium)
              card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx(context, 'Premium aktyvus', 'Premium is active'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: navy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tx(
                        context,
                        'Jūsų planas jau aktyvuotas. Dėl plano pakeitimo ar nutraukimo kreipkitės: andrius.grudinskas@gmail.com',
                        'Your plan is already active. To change or cancel it, contact: andrius.grudinskas@gmail.com',
                      ),
                    ),
                  ],
                ),
              )
            else
              card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx(context, 'Aktyvavimas', 'Activation'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: navy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tx(
                      context,
                      'Norite Premium plano? Kreipkitės:',
                      'Want a Premium plan? Contact:',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w800, color: navy),
                  ),
                  const SizedBox(height: 4),
                  const SelectableText('andrius.grudinskas@gmail.com'),
                  if (service.premiumRequestPending) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.schedule_rounded, color: green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tx(
                              context,
                              'Jūsų Premium užklausa laukia patvirtinimo.',
                              'Your Premium request is awaiting approval.',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ] else if (user != null) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        final choice = await _showPremiumRequestDialog(context);
                        if (choice == null || !context.mounted) return;
                        try {
                          await SubscriptionService.instance.requestPremium(choice);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tx(context, 'Užklausa išsiųsta.', 'Request sent.'))));
                        } catch (_) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tx(context, 'Nepavyko išsiųsti užklausos.', 'Could not send request.'))));
                        }
                      },
                      icon: const Icon(Icons.workspace_premium_rounded),
                      label: Text(tx(context, 'Noriu Premium', 'I want Premium')),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Text(tx(context, 'Norėdami pateikti užklausą, prisijunkite su „Google“.', 'Sign in with Google to send a request.')),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

Future<SubscriptionPlan?> _showPremiumRequestDialog(BuildContext context) {
  var plan = SubscriptionPlan.premiumMonthly;
  var accepted = false;
  return showDialog<SubscriptionPlan>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(tx(context, 'Premium užklausa', 'Premium request')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RadioGroup<SubscriptionPlan>(
                  groupValue: plan,
                  onChanged: (value) {
                    if (value != null) setState(() => plan = value);
                  },
                  child: Column(
                    children: [
                      RadioListTile<SubscriptionPlan>(
                        value: SubscriptionPlan.premiumMonthly,
                        title: Text(tx(context, 'Mėnesinis – 1,99 €', 'Monthly – €1.99')),
                      ),
                      RadioListTile<SubscriptionPlan>(
                        value: SubscriptionPlan.premiumYearly,
                        title: Text(tx(context, 'Metinis – 19,99 €', 'Annual – €19.99')),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Text(
                  tx(context, 'Pirkimo ir naudojimo sąlygos', 'Purchase and usage terms'),
                  style: const TextStyle(fontWeight: FontWeight.w900, color: navy),
                ),
                const SizedBox(height: 8),
                Text(
                  tx(
                    context,
                    'Užklausos pateikimas pats savaime pinigų nenuskaito. Mokėjimas ir aktyvavimo data suderinami el. paštu. Planas automatiškai nepratęsiamas. Premium pradedamas teikti iškart po patvirtinimo ir galioja iki nurodytos datos. Nutraukus planą anksčiau, sumokėta suma paprastai negrąžinama, išskyrus atvejus, kai grąžinimą numato privalomi teisės aktai arba paslauga neatitinka reikalavimų. Įstatymuose nustatytos vartotojo teisės nėra ribojamos.',
                    'Submitting a request does not charge you. Payment and the activation date are arranged by email. The plan does not renew automatically. Premium starts immediately after approval and remains valid until the stated date. If cancelled early, amounts paid are generally non-refundable, except where mandatory law requires a refund or the service is non-conforming. Statutory consumer rights are not limited.',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: accepted,
                  onChanged: (value) => setState(() => accepted = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    tx(
                      context,
                      'Perskaičiau, sutinku su sąlygomis ir prašau pradėti teikti paslaugą iškart po patvirtinimo.',
                      'I have read and accept the terms and request that the service begin immediately after approval.',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tx(context, 'Atšaukti', 'Cancel')),
          ),
          FilledButton(
            onPressed: accepted ? () => Navigator.pop(dialogContext, plan) : null,
            child: Text(tx(context, 'Siųsti užklausą', 'Send request')),
          ),
        ],
      ),
    ),
  );
}

List<String> _premiumFeatures(BuildContext context) => [
  tx(context, 'Viskas, kas yra „Free“ plane', 'Everything in Free'),
  tx(context, 'Šeimos nariai ir bendrinamas namų ūkis', 'Family members and household sharing'),
  tx(context, 'AI vaistų ir simptomų paaiškinimai', 'AI medicine and symptom explanations'),
  tx(context, 'Gydytojo suvestinė ir išplėstos ataskaitos', 'Doctor summary and advanced reports'),
  tx(context, 'Atsarginė kopija ir duomenų eksportas', 'Backup and data export'),
];

Widget _subscriptionPlanCard(
  BuildContext context, {
  required String title,
  required String price,
  required bool selected,
  required List<String> features,
  String badge = '',
}) => Card(
  color: selected ? mint : Colors.white,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: BorderSide(
      color: selected ? green : const Color(0xffe0eeeb),
      width: selected ? 2 : 1,
    ),
  ),
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: navy,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded, color: green),
          ],
        ),
        const SizedBox(height: 4),
        Text(price, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        if (badge.isNotEmpty) ...[
          const SizedBox(height: 6),
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xffffedca),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(badge, style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
        const Divider(height: 24),
        ...features.map(
          (feature) => Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_rounded, color: green, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(feature)),
              ],
            ),
          ),
        ),
      ],
    ),
  ),
);

class ProfilePage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const ProfilePage({super.key, required this.data, required this.onChanged});
  State<ProfilePage> createState() => _ProfilePage();
}

class _ProfilePage extends State<ProfilePage> {
  late final UserProfile p;
  late final TextEditingController phone;
  late final TextEditingController email;
  late final TextEditingController emergencyName;
  late final TextEditingController emergencyPhone;

  Member? get linkedMember => widget.data.members
      .where((member) => member.id == widget.data.linkedMemberId)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    p = widget.data.profile;
    phone = TextEditingController(text: p.phone);
    email = TextEditingController(text: p.email);
    emergencyName = TextEditingController(text: p.emergencyName);
    emergencyPhone = TextEditingController(text: p.emergencyPhone);
  }
  @override
  void dispose() {
    phone.dispose();
    email.dispose();
    emergencyName.dispose();
    emergencyPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(c) {
    final member = linkedMember;
    return Scaffold(
      appBar: AppBar(title: Text(tx(c, 'Mano profilis', 'My profile'))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          MediaQuery.paddingOf(c).bottom + 36,
        ),
        children: [
          Text(
            tx(c, 'Paskyra ir kontaktai', 'Account and contacts'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if ((CloudSyncService.instance.user?.email ?? '').isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_circle_outlined, color: green),
                title: Text(accountDisplayName(widget.data)),
                subtitle: Text(CloudSyncService.instance.user!.email!),
              ),
            ),
          AnimatedBuilder(
            animation: SubscriptionService.instance,
            builder: (context, _) {
              final service = SubscriptionService.instance;
              final plan = service.entitlement.effectivePlan;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: plan == SubscriptionPlan.free
                        ? const Color(0xffeef3f2)
                        : mint,
                    child: Icon(
                      plan == SubscriptionPlan.free
                          ? Icons.workspace_premium_outlined
                          : Icons.workspace_premium_rounded,
                      color: plan == SubscriptionPlan.free ? Colors.grey : green,
                    ),
                  ),
                  title: Text(
                    tx(context, 'Mano planas', 'My plan'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    service.loading
                        ? tx(context, 'Tikrinama…', 'Checking…')
                        : subscriptionPlanLabel(context, plan),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SubscriptionPage()),
                  ),
                ),
              );
            },
          ),
          field(c, phone, 'Telefonas', 'Phone'),
          field(c, email, 'Kontaktinis el. paštas', 'Contact email'),
          const SizedBox(height: 14),
          Text(
            tx(c, 'Mano sveikatos profilis', 'My health profile'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: mint,
                child: Text(
                  member == null
                      ? '👤'
                      : _memberEmoji(member.gender, member.ageGroup),
                ),
              ),
              title: Text(
                member?.name ?? tx(c, 'Profilis nesusietas', 'Profile not linked'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                member == null
                    ? tx(
                        c,
                        'Susiekite paskyrą su šeimos nariu.',
                        'Link the account to a family member.',
                      )
                    : [
                        if (member.birthDate.isNotEmpty) member.birthDate,
                        if (member.bloodType.isNotEmpty)
                          '${tx(c, 'Kraujo grupė', 'Blood type')}: ${member.bloodType}',
                        if (member.allergies.isNotEmpty)
                          '${tx(c, 'Alergijos', 'Allergies')}: ${member.allergies}',
                      ].join('\n'),
              ),
              isThreeLine: member != null,
              trailing: const Icon(Icons.edit_outlined),
              onTap: member == null
                  ? null
                  : () async {
                      await Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => MemberEditor(
                            data: widget.data,
                            member: member,
                            onChanged: widget.onChanged,
                          ),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
            ),
          ),
          const SizedBox(height: 14),
          Text(
            tx(c, 'Skubios pagalbos kontaktas', 'Emergency contact'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          field(c, emergencyName, 'Vardas ir pavardė', 'Full name'),
          field(c, emergencyPhone, 'Telefono numeris', 'Phone number'),
          FilledButton(
            onPressed: () {
              p.phone = phone.text.trim();
              p.email = email.text.trim();
              p.emergencyName = emergencyName.text.trim();
              p.emergencyPhone = emergencyPhone.text.trim();
              widget.onChanged();
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(tx(c, 'Profilis išsaugotas', 'Profile saved')),
                ),
              );
            },
            child: Text(tx(c, 'Išsaugoti profilį', 'Save profile')),
          ),
          const SizedBox(height: 18),
          Text(
            tx(c, 'Sveikata ir duomenys', 'Health and data'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _profileToolTile(
            c,
            Icons.history,
            'Vartojimo istorija',
            'Dose history',
            () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => DoseHistoryPage(
                  data: widget.data,
                  onChanged: widget.onChanged,
                ),
              ),
            ),
          ),
          _profileToolTile(
            c,
            Icons.shopping_cart_outlined,
            'Pirkinių sąrašas',
            'Shopping list',
            () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => ShoppingPage(
                  data: widget.data,
                  onChanged: widget.onChanged,
                ),
              ),
            ),
          ),
          _profileToolTile(
            c,
            Icons.medical_information_outlined,
            'Santrauka gydytojui',
            'Doctor summary',
            () async {
              if (!await requirePremium(c) || !c.mounted) return;
              await Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => DoctorSummaryPage(data: widget.data),
                ),
              );
            },
          ),
          _profileToolTile(
            c,
            Icons.emergency_outlined,
            'Kritinė informacija',
            'Emergency information',
            () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => EmergencyInfoPage(data: widget.data),
              ),
            ),
          ),
          _profileToolTile(
            c,
            Icons.backup_outlined,
            'Atsarginė kopija',
            'Backup and restore',
            () async {
              if (!await requirePremium(c) || !c.mounted) return;
              await Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => DataTransferPage(
                    data: widget.data,
                    onChanged: widget.onChanged,
                  ),
                ),
              );
            },
          ),
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.cloud_sync_outlined, color: green),
              ),
              title: Text(
                tx(c, 'Google paskyra ir sinchronizavimas', 'Google account and sync'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                widget.data.householdId.isEmpty
                    ? tx(c, 'Asmeninė erdvė arba šeimos bendrinimas', 'Personal space or family sharing')
                    : tx(c, 'Bendrinama: ${widget.data.householdName}', 'Shared: ${widget.data.householdName}'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => CloudAccountPage(data: widget.data, onChanged: widget.onChanged),
                  ),
                );
                if (mounted) setState(() {});
              },
            ),
          ),
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.admin_panel_settings_outlined, color: green),
              ),
              title: Text(
                tx(c, 'Sutikimai ir leidimai', 'Permissions and consent'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(tx(
                c,
                'Kamerą, vaistų ir vizitų pranešimus bei AI valdykite atskirai',
                'Manage camera, medicine and appointment alerts, and AI separately',
              )),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final changed = await _showPermissionsCenter(
                  context,
                  widget.data,
                  firstLaunch: false,
                );
                if (changed && mounted) {
                  setState(() {});
                  widget.onChanged();
                }
              },
            ),
          ),
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.system_update_alt_rounded, color: green),
              ),
              title: Text(
                tx(c, 'Programėlės atnaujinimas', 'App update'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'MediBox ${AppUpdateService.currentVersion}',
              ),
              trailing: const Icon(Icons.refresh_rounded),
              onTap: () =>
                  c.findAncestorStateOfType<_App>()?._checkForUpdate(
                    manual: true,
                  ),
            ),
          ),
          Card(
            child: SwitchListTile(
              secondary: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.fingerprint, color: green),
              ),
              value: widget.data.privacyLock,
              title: Text(
                tx(c, 'Programėlės užraktas', 'App lock'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                tx(
                  c,
                  'Naudoti telefono PIN, piršto atspaudą arba veido atpažinimą',
                  'Use device PIN, fingerprint or face authentication',
                ),
              ),
              onChanged: (value) {
                setState(() => widget.data.privacyLock = value);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(height: 18),
          Text(
            tx(c, 'Kalba', 'Language'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          RadioGroup<String>(
            groupValue: widget.data.language,
            onChanged: (v) {
              setState(() => widget.data.language = v!);
              widget.onChanged();
            },
            child: Column(
              children: [
                RadioListTile(
                  value: 'system',
                  title: Text(tx(c, 'Pagal telefoną', 'Use phone language')),
                ),
                const RadioListTile(value: 'lt', title: Text('Lietuvių')),
                const RadioListTile(value: 'en', title: Text('English')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: MediBoxLogo(size: 58)),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    tx(c, 'Kas yra „MediBox“?', 'What is MediBox?'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: navy,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  tx(
                    c,
                    '„MediBox“ – išmani asmeninė ir šeimos vaistinėlė, padedanti vienoje vietoje tvarkyti vaistus, jų vartojimą ir svarbiausią šeimos sveikatos informaciją.',
                    'MediBox is a smart personal and family medicine cabinet that helps you manage medicines, their use, and essential family health information in one place.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(height: 1.4),
                ),
                const SizedBox(height: 16),
                _aboutFeature(
                  c,
                  Icons.inventory_2_outlined,
                  'Bendra vaistinėlė',
                  'Shared medicine cabinet',
                  'Likučiai, galiojimas, receptai ir vaistų priskyrimas šeimos nariams.',
                  'Stock, expiry, prescriptions, and medicine assignments for family members.',
                ),
                _aboutFeature(
                  c,
                  Icons.alarm_outlined,
                  'Priminimai ir kalendorius',
                  'Reminders and calendar',
                  'Vaistų vartojimo planas, istorija ir gydytojų vizitai.',
                  'Medication schedules, history, and doctor appointments.',
                ),
                _aboutFeature(
                  c,
                  Icons.family_restroom_outlined,
                  'Šeimos bendrinimas',
                  'Family sharing',
                  'Sinchronizuojama namų ūkio informacija kiekvieno nario paskyroje.',
                  'Household information synchronized across each member’s account.',
                ),
                _aboutFeature(
                  c,
                  Icons.auto_awesome_outlined,
                  'AI pagalba',
                  'AI assistance',
                  'Padeda suprasti vaistų informaciją, tačiau nekeičia gydytojo sprendimų.',
                  'Helps explain medicine information without replacing clinical decisions.',
                ),
                const Divider(height: 28),
                Center(
                  child: Text(
                    'MediBox v${AppUpdateService.currentVersion}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    '${tx(c, 'Kūrėjas', 'Creator')}: Andrius Grudinskas',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xff526874)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  tx(
                    c,
                    'Svarbu: programėlė nepakeičia gydytojo ar vaistininko konsultacijos, recepto ir oficialaus pakuotės lapelio.',
                    'Important: the app does not replace advice from a doctor or pharmacist, a prescription, or the official package leaflet.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Color(0xff60747f),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _aboutFeature(
  BuildContext context,
  IconData icon,
  String titleLt,
  String titleEn,
  String textLt,
  String textEn,
) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CircleAvatar(
        radius: 20,
        backgroundColor: mint,
        child: Icon(icon, color: green, size: 21),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tx(context, titleLt, titleEn),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              tx(context, textLt, textEn),
              style: const TextStyle(
                height: 1.3,
                color: Color(0xff526874),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
);

Widget field(
  BuildContext c,
  TextEditingController controller,
  String lt,
  String en, {
  int lines = 1,
  bool number = false,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: TextField(
    controller: controller,
    maxLines: lines,
    keyboardType: number ? TextInputType.number : null,
    decoration: InputDecoration(labelText: tx(c, lt, en)),
  ),
);

Widget dateField(
  BuildContext c,
  TextEditingController controller,
  String lt,
  String en, {
  bool monthOnly = false,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [DateDashFormatter(monthOnly: monthOnly)],
    maxLength: monthOnly ? 7 : 10,
    decoration: InputDecoration(
      labelText: tx(c, lt, en),
      hintText: monthOnly ? 'YYYY-MM' : 'YYYY-MM-DD',
      counterText: '',
      prefixIcon: const Icon(Icons.calendar_month_outlined),
    ),
  ),
);

bool _validDate(String value, {bool monthOnly = false}) {
  final pattern = monthOnly
      ? RegExp(r'^\d{4}-(0[1-9]|1[0-2])$')
      : RegExp(r'^\d{4}-(0[1-9]|1[0-2])-([0-2]\d|3[01])$');
  if (!pattern.hasMatch(value)) return false;
  if (monthOnly) return true;
  final parts = value.split('-').map(int.parse).toList();
  final parsed = DateTime(parts[0], parts[1], parts[2]);
  return parsed.year == parts[0] &&
      parsed.month == parts[1] &&
      parsed.day == parts[2];
}

class ScanCaptureResult {
  final String text;
  final String imagePath;
  const ScanCaptureResult(this.text, this.imagePath);
}

class ScanPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  final bool openCameraImmediately;
  const ScanPage({
    super.key,
    required this.data,
    required this.onChanged,
    this.openCameraImmediately = false,
  });
  State<ScanPage> createState() => _ScanPage();
}

class _ScanPage extends State<ScanPage> {
  String text = '';
  String imagePath = '';
  bool busy = false;
  bool vvktBusy = false;
  bool vvktChecked = false;
  String vvktError = '';
  VvktMedicine? vvktMatch;
  List<VvktMedicine> vvktMatches = [];

  @override
  void initState() {
    super.initState();
    if (widget.openCameraImmediately) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openCamera();
      });
    }
  }

  Future<void> _lookupVvkt(String recognizedText) async {
    final query = _guessRegistryName(recognizedText);
    if (query.isEmpty) return;
    setState(() {
      vvktBusy = true;
      vvktChecked = false;
      vvktError = '';
      vvktMatch = null;
      vvktMatches = [];
    });
    try {
      var matches = <VvktMedicine>[];
      final candidates = {
        query,
        _registryTitleCase(query),
        if (query.contains(' ')) query.split(' ').first,
        if (query.contains(' ')) _registryTitleCase(query.split(' ').first),
      };
      for (final candidate in candidates) {
        matches = await VvktService.search(candidate);
        if (matches.isNotEmpty) break;
      }
      final match = VvktService.bestMatch(
        matches,
        _guessStrength(recognizedText),
      );
      if (mounted)
        setState(() {
          vvktMatches = matches;
          vvktMatch = match;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          vvktMatch = null;
          vvktError = '$error';
        });
    } finally {
      if (mounted) {
        setState(() {
          vvktBusy = false;
          vvktChecked = true;
        });
      }
    }
  }

  Future<void> _chooseVvktVariant() async {
    final selected = await showModalBottomSheet<VvktMedicine>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  tx(
                    sheetContext,
                    'Pasirinkite tikslų vaisto variantą',
                    'Choose the exact medicine variant',
                  ),
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: vvktMatches.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final item = vvktMatches[index];
                    return ListTile(
                      leading: Icon(
                        identical(item, vvktMatch)
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: green,
                      ),
                      title: Text('${item.name} ${item.strength}'),
                      subtitle: Text(
                        '${item.dosageForm}\n${item.packageDescription}',
                      ),
                      isThreeLine: true,
                      onTap: () => Navigator.pop(sheetContext, item),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) setState(() => vvktMatch = selected);
  }

  Future<void> ocr(ImageSource src) async {
    if (busy) return;
    if (src == ImageSource.camera &&
        !await _cameraAvailable(context, widget.data)) return;
    setState(() => busy = true);
    TextRecognizer? r;
    try {
      final f = await ImagePicker().pickImage(source: src, imageQuality: 90);
      if (f == null || !mounted) return;
      final directory = await getApplicationDocumentsDirectory();
      final saved = await File(f.path)
          .copy('${directory.path}/scan_${newId()}.jpg');
      r = TextRecognizer(script: TextRecognitionScript.latin);
      final out = await r.processImage(InputImage.fromFilePath(saved.path));
      if (mounted) {
        setState(() {
          text = out.text;
          imagePath = saved.path;
        });
        await _lookupVvkt(out.text);
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tx(context, 'Nepavyko nuskaityti.', 'Could not scan.'),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
      await r?.close();
    }
  }

  Future<void> openCamera() async {
    if (!await _cameraAvailable(context, widget.data)) return;
    final result = await Navigator.push<ScanCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CameraCapturePage(data: widget.data, onChanged: widget.onChanged),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        text = result.text;
        imagePath = result.imagePath;
      });
      await _lookupVvkt(result.text);
    }
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Skenuoti', 'Scan'))),
    body: ListView(
      padding: scrollPagePadding(c),
      children: [
        FilledButton.icon(
          onPressed: busy ? null : openCamera,
          icon: const Icon(Icons.camera_alt),
          label: Text(tx(c, 'Fotografuoti', 'Take photo')),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => ocr(ImageSource.gallery),
          icon: const Icon(Icons.photo_library),
          label: Text(tx(c, 'Pasirinkti nuotrauką', 'Choose photo')),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) =>
                  BarcodePage(data: widget.data, onChanged: widget.onChanged),
            ),
          ),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(tx(c, 'Skenuoti kodą', 'Scan code')),
        ),
        if (busy) const Center(child: CircularProgressIndicator()),
        if (text.isNotEmpty) ...[
          if (imagePath.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(imagePath),
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(c, 'Atpažinimo rezultatas', 'Recognition result'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_guessName(text)}\n${_guessStrength(text)}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Divider(),
                Text(
                  tx(
                    c,
                    'Duomenys nuskaityti nuo pakuotės. Prieš išsaugodami juos patikrinkite.',
                    'Data was read from the package. Check it before saving.',
                  ),
                  style: const TextStyle(color: Color(0xff526572)),
                ),
                const SizedBox(height: 8),
                Text(
                  '${tx(c, 'Galiojimo data', 'Expiry')}: ${MedicineMatcher.expiry(text) ?? tx(c, 'neatpažinta', 'not recognized')}',
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    tx(c, 'Visas atpažintas tekstas', 'All recognized text'),
                  ),
                  children: [SelectableText(text)],
                ),
              ],
            ),
          ),
          if (vvktBusy)
            card(
              Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tx(
                        c,
                        'Tikrinama VVKT registre…',
                        'Checking the VVKT register…',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!vvktBusy && vvktMatch != null)
            Card(
              color: const Color(0xffe5f7f0),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_rounded, color: green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tx(
                              c,
                              'Rastas oficialiame VVKT duomenų rinkinyje',
                              'Found in official VVKT data',
                            ),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${vvktMatch!.name} ${vvktMatch!.strength}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(vvktMatch!.substance),
                    Text(
                      '${vvktMatch!.dosageForm} • ${vvktMatch!.packageDescription}',
                    ),
                    Text(
                      '${tx(c, 'Tiekimas', 'Supply')}: ${vvktMatch!.supplyStatus}',
                    ),
                    Text(
                      '${tx(c, 'Registracijos Nr.', 'Registration No.')}: ${vvktMatch!.registrationNumber}',
                    ),
                    if (vvktMatches.length > 1)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _chooseVvktVariant,
                          icon: const Icon(Icons.swap_horiz),
                          label: Text(
                            tx(
                              c,
                              'Keisti variantą (${vvktMatches.length})',
                              'Change variant (${vvktMatches.length})',
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (!vvktBusy && vvktChecked && vvktMatch == null)
            Card(
              color: const Color(0xfffff4dc),
              child: ListTile(
                leading: Icon(
                  vvktError.isEmpty
                      ? Icons.info_outline
                      : Icons.cloud_off_outlined,
                  color: const Color(0xffbd7200),
                ),
                title: Text(
                  vvktError.isEmpty
                      ? tx(
                          c,
                          'VVKT registre automatiškai nepatvirtinta',
                          'Not automatically confirmed in VVKT',
                        )
                      : tx(
                          c,
                          'Nepavyko prisijungti prie VVKT',
                          'Could not connect to VVKT',
                        ),
                ),
                subtitle: Text(
                  vvktError.isEmpty
                      ? tx(
                          c,
                          'Patikrinkite nuskaitytą pavadinimą arba įveskite duomenis rankiniu būdu.',
                          'Check the recognized name or enter the details manually.',
                        )
                      : tx(
                          c,
                          'Patikrinkite interneto ryšį ir nuskaitykite dar kartą. Duomenis taip pat galite įvesti rankiniu būdu.',
                          'Check your connection and scan again. You can also enter the details manually.',
                        ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => MedicineEditor(
                  data: widget.data,
                  onChanged: widget.onChanged,
                  sourceText: text,
                  initialImagePath: imagePath,
                  registryMedicine: vvktMatch,
                ),
              ),
            ),
            icon: const Icon(Icons.add_circle_outline),
            label: Text(
              tx(
                c,
                'Patikrinti ir pridėti į vaistinėlę',
                'Review and add to medicine cabinet',
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class CameraCapturePage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const CameraCapturePage({
    super.key,
    required this.data,
    required this.onChanged,
  });
  State<CameraCapturePage> createState() => _CameraCapturePage();
}

class _CameraCapturePage extends State<CameraCapturePage> {
  String mode = 'box';
  bool busy = false;
  CameraController? camera;
  Future<void>? cameraReady;

  @override
  void initState() {
    super.initState();
    cameraReady = _startCamera();
  }

  Future<void> _startCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('No camera');
    final back = cameras.where(
      (x) => x.lensDirection == CameraLensDirection.back,
    );
    camera = CameraController(
      back.isEmpty ? cameras.first : back.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await camera!.initialize();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    camera?.dispose();
    super.dispose();
  }

  Future<void> capture() async {
    if (mode == 'barcode') {
      await camera?.dispose();
      camera = null;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              BarcodePage(data: widget.data, onChanged: widget.onChanged),
        ),
      );
      if (mounted) setState(() => cameraReady = _startCamera());
      return;
    }
    final controller = camera;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() => busy = true);
    TextRecognizer? recognizer;
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final result = await recognizer.processImage(
        InputImage.fromFilePath(file.path),
      );
      final directory = await getApplicationDocumentsDirectory();
      final saved = await File(file.path)
          .copy('${directory.path}/scan_${newId()}.jpg');
      if (mounted) {
        Navigator.pop(context, ScanCaptureResult(result.text, saved.path));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tx(context, 'Nepavyko nuskaityti.', 'Could not scan.'),
            ),
          ),
        );
      }
    } finally {
      await recognizer?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final modes = [
      ('box', Icons.medication_outlined, 'Dėžutė', 'Box'),
      ('receipt', Icons.receipt_long_outlined, 'Čekis', 'Receipt'),
      ('barcode', Icons.qr_code_scanner, 'Brūkšninis kodas', 'Barcode'),
      ('document', Icons.description_outlined, 'Dokumentas', 'Document'),
    ];
    return Scaffold(
      backgroundColor: const Color(0xff17211f),
      appBar: AppBar(
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        title: Text(tx(context, 'Fotografuoti', 'Take photo')),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
              child: Text(
                mode == 'barcode'
                    ? tx(
                        context,
                        'Sulygiuokite kodą rėmelyje',
                        'Align the code in the frame',
                      )
                    : tx(
                        context,
                        'Sutalpinkite objektą į rėmelį',
                        'Fit the object inside the frame',
                      ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<void>(
                future: cameraReady,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        tx(
                          context,
                          'Kamera nepasiekiama. Patikrinkite leidimą.',
                          'Camera unavailable. Check permission.',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }
                  if (snapshot.connectionState != ConnectionState.done ||
                      camera == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 22),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: Colors.white70, width: 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraPreview(camera!),
                          Center(
                            child: Icon(
                              mode == 'barcode'
                                  ? Icons.qr_code_2_rounded
                                  : Icons.center_focus_strong,
                              size: 115,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 82,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: modes.map((item) {
                  final selected = mode == item.$1;
                  return InkWell(
                    onTap: () => setState(() => mode = item.$1),
                    child: SizedBox(
                      width: 94,
                      child: Column(
                        children: [
                          Icon(
                            item.$2,
                            color: selected
                                ? const Color(0xff5ee2bf)
                                : Colors.white70,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            tx(context, item.$3, item.$4),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: selected
                                  ? const Color(0xff5ee2bf)
                                  : Colors.white70,
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: InkWell(
                onTap: busy ? null : capture,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: busy ? Colors.grey : Colors.white,
                    border: Border.all(
                      color: const Color(0xff5ee2bf),
                      width: 5,
                    ),
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: CircularProgressIndicator(),
                        )
                      : Icon(
                          mode == 'barcode'
                              ? Icons.qr_code_scanner
                              : Icons.camera_alt,
                          color: navy,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BarcodePage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const BarcodePage({super.key, required this.data, required this.onChanged});
  State<BarcodePage> createState() => _BarcodePage();
}

class _BarcodePage extends State<BarcodePage> {
  bool done = false;
  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Kodo skenavimas', 'Code scanner'))),
    body: MobileScanner(
      onDetect: (x) {
        if (done || !mounted) return;
        final v = x.barcodes.firstOrNull?.rawValue;
        if (v == null) return;
        done = true;
        Navigator.pushReplacement(
          c,
          MaterialPageRoute(
            builder: (_) => MedicineEditor(
              data: widget.data,
              onChanged: widget.onChanged,
              sourceText: v,
            ),
          ),
        );
      },
    ),
  );
}

class SymptomsPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const SymptomsPage({super.key, required this.data, required this.onChanged});
  @override
  State<SymptomsPage> createState() => _SymptomsPageState();
}

class _SymptomsPageState extends State<SymptomsPage> {
  String memberId = '';
  final customSymptom = TextEditingController();

  @override
  void dispose() {
    customSymptom.dispose();
    super.dispose();
  }

  @override
  Widget build(c) {
    final cats = <(String, String, IconData, Color)>[
      ('Skausmas', 'Pain', Icons.healing_rounded, const Color(0xffe53935)),
      (
        'Karščiavimas',
        'Fever',
        Icons.thermostat_rounded,
        const Color(0xffe53935),
      ),
      ('Peršalimas', 'Cold', Icons.sick_outlined, green),
      (
        'Pilvo problemos',
        'Stomach problems',
        Icons.health_and_safety_rounded,
        green,
      ),
      ('Alergija', 'Allergy', Icons.air_rounded, navy),
      (
        'Viduriavimas / užkietėjimas',
        'Diarrhea / constipation',
        Icons.wc_rounded,
        navy,
      ),
      ('Odos problemos', 'Skin problems', Icons.water_drop_outlined, navy),
      ('Galvos svaigimas', 'Dizziness', Icons.sync_problem_outlined, navy),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tx(c, 'Man bloga', 'Symptoms'))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          MediaQuery.paddingOf(c).bottom + 32,
        ),
        children: [
          title(tx(c, 'Kas labiausiai vargina?', 'What bothers you most?')),
          Text(
            tx(
              c,
              'Vedlys nediagnozuoja. Pavojingus ar stiprėjančius simptomus turi įvertinti medikas.',
              'This guide does not diagnose. Urgent or worsening symptoms require medical assessment.',
            ),
          ),
          const SizedBox(height: 16),
          if (widget.data.members.isNotEmpty) ...[
            Text(
              tx(c, 'Kam pasireiškė simptomai?', 'Who has symptoms?'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: navy,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: widget.data.members
                    .map(
                      (member) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: Text(
                            _memberEmoji(member.gender, member.ageGroup),
                          ),
                          label: Text(member.name),
                          selected: memberId == member.id,
                          onSelected: (_) =>
                              setState(() => memberId = member.id),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 14),
          ],
          ...cats.map(
            (x) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: x.$4.withValues(alpha: .11),
                  child: Icon(x.$3, color: x.$4),
                ),
                title: Text(
                  tx(c, x.$1, x.$2),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openWizard(c, x.$1),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: customSymptom,
            onChanged: (_) => setState(() {}),
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: tx(
                c,
                'Aprašyti kitus simptomus',
                'Describe other symptoms',
              ),
              hintText: tx(
                c,
                'Pvz., silpna, pykina ir svaigsta galva…',
                'For example: weakness, nausea and dizziness…',
              ),
              prefixIcon: const Icon(Icons.auto_awesome_outlined),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: customSymptom.text.trim().isEmpty
                ? null
                : () => _openWizard(
                    c,
                    'Kiti simptomai',
                    customSymptom.text.trim(),
                  ),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(tx(c, 'Tęsti', 'Continue')),
          ),
        ],
      ),
    );
  }

  Future<void> _openWizard(
    BuildContext context,
    String category, [
    String details = '',
  ]) async {
    if (widget.data.members.isNotEmpty && memberId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tx(
              context,
              'Pirmiausia pasirinkite šeimos narį.',
              'Choose a family member first.',
            ),
          ),
        ),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SymptomWizardPage(
          data: widget.data,
          memberId: memberId,
          category: category,
          initialDetails: details,
          directTextAnalysis: details.isNotEmpty,
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}

class SymptomWizardPage extends StatefulWidget {
  final AppData data;
  final String memberId;
  final String category;
  final String initialDetails;
  final bool directTextAnalysis;
  final VoidCallback onChanged;
  const SymptomWizardPage({
    super.key,
    required this.data,
    required this.memberId,
    required this.category,
    this.initialDetails = '',
    this.directTextAnalysis = false,
    required this.onChanged,
  });
  @override
  State<SymptomWizardPage> createState() => _SymptomWizardPageState();
}

class _SymptomWizardPageState extends State<SymptomWizardPage> {
  int step = 0;
  String location = '';
  String severity = 'vidutinis';
  String painType = '';
  String duration = '';
  bool fever = false;
  bool highFever = false;
  bool vomiting = false;
  bool persistentVomiting = false;
  bool blood = false;
  bool breathingProblem = false;
  bool faintingOrConfusion = false;
  bool rash = false;
  bool swelling = false;
  bool cannotDrink = false;
  bool neurologicDeficit = false;
  late bool aiConsent;
  final Set<String> selectedSymptoms = {};
  Future<SymptomExplanation?>? aiAssessment;

  @override
  void initState() {
    super.initState();
    aiConsent = widget.data.aiConsentGranted;
    if (widget.directTextAnalysis) {
      step = 2;
      duration = 'nenurodyta';
      selectedSymptoms.add('Laisvas simptomų aprašymas');
      final details = widget.initialDetails.toLowerCase();
      breathingProblem = details.contains('sunku kvėpuoti') ||
          details.contains('dusul') || details.contains('nekvėpu');
      blood = details.contains('krauj');
      faintingOrConfusion = details.contains('alp') ||
          details.contains('sumiš') || details.contains('sąmon');
      swelling = (details.contains('veid') || details.contains('lūp')) &&
          (details.contains('tin') || details.contains('patin'));
      cannotDrink = details.contains('negaliu gerti') ||
          details.contains('neišlaikau skys');
      neurologicDeficit = details.contains('sunku kalbėti') ||
          details.contains('paraly') || details.contains('nevaldau');
      aiAssessment = aiConsent ? _requestAiAssessment() : null;
    }
  }

  List<String> get locations => switch (widget.category) {
    'Pilvo problemos' => [
      'Viršutinėje pilvo dalyje',
      'Dešinėje',
      'Kairėje',
      'Apatinėje dalyje',
      'Visą pilvą',
      'Sunku pasakyti',
    ],
    'Skausmas' => [
      'Galva',
      'Gerklė',
      'Krūtinė',
      'Pilvas',
      'Nugara',
      'Sąnariai / raumenys',
      'Kita vieta',
    ],
    'Odos problemos' => [
      'Galva / veidas',
      'Krūtinė / liemuo',
      'Pilvas',
      'Nugara',
      'Rankos',
      'Kojos',
      'Kelios kūno vietos',
    ],
    _ => const [],
  };

  bool get usesBodyMap =>
      widget.category == 'Skausmas' ||
      widget.category == 'Pilvo problemos' ||
      widget.category == 'Odos problemos';

  String get bodyMapAsset {
    final member = widget.data.members
        .where((item) => item.id == widget.memberId)
        .firstOrNull;
    final child = member?.ageGroup == 'child';
    final female = member?.gender == 'female';
    if (child) {
      return female
          ? 'assets/images/body_maps/child_female.png'
          : 'assets/images/body_maps/child_male.png';
    }
    return female
        ? 'assets/images/body_maps/adult_female.png'
        : 'assets/images/body_maps/adult_male.png';
  }

  List<String> get symptomOptions => switch (widget.category) {
    'Peršalimas' => [
      'Sloga',
      'Užgulta nosis',
      'Gerklės skausmas',
      'Kosulys',
      'Užkimimas',
      'Bendras silpnumas',
    ],
    'Karščiavimas' => [
      'Iki 38 °C',
      '38–39 °C',
      '39 °C ar daugiau',
      'Šaltkrėtis',
      'Prakaitavimas',
      'Silpnumas',
    ],
    'Alergija' => [
      'Sloga / čiaudulys',
      'Akių niežėjimas',
      'Odos bėrimas',
      'Niežėjimas',
      'Veido ar lūpų tinimas',
      'Sunku kvėpuoti',
    ],
    'Viduriavimas / užkietėjimas' => [
      'Viduriavimas',
      'Užkietėjimas',
      'Pilvo pūtimas',
      'Pilvo spazmai',
      'Pykinimas',
      'Vėmimas',
    ],
    'Galvos svaigimas' => [
      'Sukasi aplinka',
      'Silpnumas / aptemimas',
      'Pusiausvyros sutrikimas',
      'Pykinimas',
      'Galvos skausmas',
      'Ūžimas ausyse',
    ],
    _ => ['Kitas simptomas'],
  };

  bool get dangerous =>
      severity == 'labai stiprus' ||
      blood ||
      breathingProblem ||
      faintingOrConfusion ||
      neurologicDeficit ||
      persistentVomiting ||
      cannotDrink ||
      highFever ||
      (widget.category == 'Alergija' && swelling) ||
      (widget.category == 'Pilvo problemos' &&
          location == 'Dešinėje' &&
          fever &&
          vomiting);

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(
        step == 0
            ? widget.category
            : tx(c, 'Simptomų įvertinimas', 'Symptom assessment'),
      ),
    ),
    body: SafeArea(
      top: false,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: step == 0
            ? _firstStep(c)
            : step == 1
            ? _questionsStep(c)
            : _resultStep(c),
      ),
    ),
  );

  Widget _firstStep(BuildContext c) =>
      usesBodyMap ? _locationStep(c) : _symptomStep(c);

  Widget _locationStep(BuildContext c) => ListView(
    key: const ValueKey('location'),
    padding: const EdgeInsets.all(18),
    children: [
      title(
        tx(
          c,
          widget.category == 'Pilvo problemos'
              ? 'Kurioje pilvo vietoje jaučiate problemą?'
              : 'Kurioje vietoje jaučiate problemą?',
          widget.category == 'Pilvo problemos'
              ? 'Where in the abdomen is the problem?'
              : 'Where do you feel the problem?',
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: Container(
          width: 210,
          height: 270,
          decoration: BoxDecoration(
            color: const Color(0xfff2fbf8),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0xffd7ebe5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: BodyMapView(
              asset: bodyMapAsset,
              location: location,
              errorLabel: tx(
                c,
                'Kūno vaizdo nepavyko įkelti',
                'Body image could not be loaded',
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ...locations.map(
        (item) => Card(
          color: location == item ? mint : Colors.white,
          child: ListTile(
            leading: Icon(
              location == item
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: green,
            ),
            title: Text(item),
            onTap: () => setState(() => location = item),
          ),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton(
        onPressed: location.isEmpty ? null : () => setState(() => step = 1),
        child: Text(tx(c, 'Tęsti', 'Continue')),
      ),
    ],
  );

  Widget _symptomStep(BuildContext c) => ListView(
    key: const ValueKey('symptoms'),
    padding: const EdgeInsets.all(18),
    children: [
      title(tx(c, 'Ką jaučiate?', 'What are you experiencing?')),
      const SizedBox(height: 6),
      Text(
        tx(
          c,
          'Galite pasirinkti kelis simptomus.',
          'You can select more than one symptom.',
        ),
      ),
      const SizedBox(height: 14),
      ...symptomOptions.map((item) {
        final selected = selectedSymptoms.contains(item);
        return Card(
          color: selected ? mint : Colors.white,
          child: CheckboxListTile(
            value: selected,
            activeColor: green,
            secondary: Icon(_symptomIcon(item), color: selected ? green : navy),
            title: Text(item),
            onChanged: (_) => setState(() {
              selected
                  ? selectedSymptoms.remove(item)
                  : selectedSymptoms.add(item);
              if (item == '39 °C ar daugiau')
                highFever = selectedSymptoms.contains(item);
              if (item == 'Sunku kvėpuoti')
                breathingProblem = selectedSymptoms.contains(item);
              if (item == 'Veido ar lūpų tinimas')
                swelling = selectedSymptoms.contains(item);
              if (item == 'Vėmimas') vomiting = selectedSymptoms.contains(item);
            }),
          ),
        );
      }),
      const SizedBox(height: 10),
      FilledButton(
        onPressed: selectedSymptoms.isEmpty
            ? null
            : () => setState(() => step = 1),
        child: Text(tx(c, 'Tęsti', 'Continue')),
      ),
    ],
  );

  IconData _symptomIcon(String item) {
    if (item.contains('Kosul') || item.contains('Gerkl'))
      return Icons.record_voice_over_outlined;
    if (item.contains('nos') || item.contains('Sloga'))
      return Icons.air_rounded;
    if (item.contains('39') || item.contains('38') || item.contains('Šaltkr'))
      return Icons.thermostat_rounded;
    if (item.contains('Odos') || item.contains('Niež'))
      return Icons.water_drop_outlined;
    if (item.contains('Viduri') || item.contains('Užkiet'))
      return Icons.wc_rounded;
    if (item.contains('Vėm') || item.contains('Pykin'))
      return Icons.sick_outlined;
    if (item.contains('kvėpuoti') || item.contains('tinimas'))
      return Icons.warning_amber_rounded;
    return Icons.health_and_safety_outlined;
  }

  Widget _questionsStep(BuildContext c) => ListView(
    key: const ValueKey('questions'),
    padding: const EdgeInsets.all(18),
    children: [
      title(tx(c, 'Papildomi klausimai', 'Additional questions')),
      if (widget.initialDetails.isNotEmpty) ...[
        const SizedBox(height: 8),
        card(Text(widget.initialDetails)),
      ],
      const SizedBox(height: 12),
      _choice(
        c,
        tx(c, 'Koks simptomų stiprumas?', 'How severe are the symptoms?'),
        ['lengvas', 'vidutinis', 'stiprus', 'labai stiprus'],
        severity,
        (v) => severity = v,
      ),
      const SizedBox(height: 14),
      _choice(
        c,
        tx(c, 'Kiek laiko tai tęsiasi?', 'How long has this lasted?'),
        ['kelias valandas', '1 dieną', '2–3 dienas', 'ilgiau'],
        duration,
        (v) => duration = v,
      ),
      if (widget.category == 'Skausmas' ||
          widget.category == 'Pilvo problemos') ...[
        const SizedBox(height: 14),
        _choice(
          c,
          tx(c, 'Koks skausmas?', 'What is the pain like?'),
          ['spazminis', 'degina', 'maudžia', 'aštrus'],
          painType,
          (v) => painType = v,
        ),
      ],
      const SizedBox(height: 14),
      ..._categoryQuestions(c),
      const SizedBox(height: 14),
      FilledButton(
        onPressed: duration.isEmpty
            ? null
            : () {
                setState(() {
                  step = 2;
                  aiAssessment = aiConsent ? _requestAiAssessment() : null;
                });
              },
        child: Text(tx(c, 'Atlikti saugumo patikrą', 'Run safety check')),
      ),
    ],
  );

  Future<SymptomExplanation?> _requestAiAssessment() async {
    if (!SubscriptionService.instance.hasPremium) return null;
    final member = widget.data.members
        .where((item) => item.id == widget.memberId)
        .firstOrNull;
    int? age;
    final birth = DateTime.tryParse(member?.birthDate ?? '');
    if (birth != null) {
      final now = DateTime.now();
      age = now.year - birth.year;
      if (now.month < birth.month ||
          (now.month == birth.month && now.day < birth.day)) {
        age--;
      }
    }
    final eligibleMedicines = widget.data.meds.where(
      (medicine) =>
          medicine.memberIds.isEmpty ||
          medicine.memberIds.contains(widget.memberId),
    );
    // Retrieve public medicine information without sending the patient's data
    // to the search request. A failed lookup must not block symptom guidance.
    final missing = eligibleMedicines.where((m) => m.registryVerified &&
        !m.prescription && m.stock > 0 &&
        (daysUntilMedicineExpiry(m.expiry, DateTime.now()) ?? -1) >= 0 &&
        (m.aiSourceUrls.isEmpty || m.dosage.trim().isEmpty));
    var enriched = false;
    await Future.wait(missing.toList().map((medicine) async {
      try {
        final profile = await AiMedicineProfileService.generate(
          medicine: VvktMedicine(
            name: medicine.name, substance: medicine.substance,
            strength: medicine.strength, dosageForm: medicine.dosageForm,
            administrationRoute: '', packageDescription: '',
            prescriptionStatus: 'Nereceptinis',
            registrationNumber: medicine.registrationNumber,
            registrant: medicine.manufacturer, supplyStatus: medicine.supplyStatus,
            registrationStatus: '', atcCode: medicine.atcCode,
          ),
          recognizedPackageText: '',
        );
        if (!mounted || !widget.data.meds.contains(medicine)) return;
        if (medicine.purpose.isEmpty) medicine.purpose = profile.purpose;
        if (medicine.dosage.isEmpty || medicine.dosage.startsWith('Vartojimo būdas:') ||
            medicine.dosage.startsWith('Administration route:')) {
          medicine.dosage = profile.dosage;
        }
        if (medicine.warnings.isEmpty) medicine.warnings = profile.warnings;
        if (medicine.interactions.isEmpty) medicine.interactions = profile.interactions;
        if (medicine.sideEffects.isEmpty) medicine.sideEffects = profile.sideEffects;
        medicine.aiSourceTitles = profile.sourceTitles;
        medicine.aiSourceUrls = profile.sourceUrls;
        medicine.aiSearchHtml = profile.searchHtml;
        medicine.aiLocalized = profile.localized;
        medicine.aiUpdatedAt = DateTime.now().toUtc().toIso8601String();
        enriched = true;
      } catch (_) {
        // Continue with known cabinet data; never manufacture missing facts.
      }
    }));
    if (!mounted) return null;
    if (enriched) await Store.save(widget.data);
    return AiSymptomService.assess(
      language: Localizations.localeOf(context).languageCode,
      category: widget.category,
      location: location,
      symptoms: selectedSymptoms.toList(),
      severity: severity,
      duration: duration,
      details: widget.initialDetails,
      safetyAnswers: {
        'highFever': highFever,
        'vomiting': vomiting,
        'persistentVomiting': persistentVomiting,
        'blood': blood,
        'breathingProblem': breathingProblem,
        'faintingOrConfusion': faintingOrConfusion,
        'swelling': swelling,
        'cannotDrink': cannotDrink,
        'neurologicDeficit': neurologicDeficit,
      },
      patient: <String, Object?>{
        'ageGroup': member?.ageGroup ?? '',
        'ageYears': age,
        'weightKg': member?.weight ?? '',
        'allergies': member?.allergies ?? '',
        'conditions': member?.conditions ?? '',
        'intolerantMedicines': member?.intolerantMedicines ?? '',
      },
      cabinetMedicines: eligibleMedicines.map((medicine) {
        final guidance = member == null
            ? null
            : calculateDoseGuidance(medicine, member);
        return <String, Object?>{
          'name': medicine.name,
          'substance': medicine.substance,
          'strength': medicine.strength,
          'form': medicine.dosageForm,
          'category': medicine.category,
          'purpose': medicine.purpose,
          'prescription': medicine.prescription,
          'officialUseText': medicine.dosage,
          'warnings': medicine.warnings,
          'interactions': medicine.interactions,
          'expired':
              (daysUntilMedicineExpiry(medicine.expiry, DateTime.now()) ?? 0) <
              0,
          'stock': medicine.stock,
          'verifiedDose': guidance == null
              ? null
              : <String, Object?>{
                  'doseMg': guidance.doseMg,
                  'volumeMl': guidance.volumeMl,
                  'units': guidance.units,
                  'source': guidance.source,
                },
        };
      }).toList(),
    );
  }

  Widget _aiCard(BuildContext c) {
    if (!SubscriptionService.instance.hasPremium) {
      return card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.workspace_premium_rounded, color: green),
                SizedBox(width: 8),
                Text('Premium AI', style: TextStyle(fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tx(
                c,
                'Saugumo patikra atlikta, tačiau išplėstas AI paaiškinimas priklauso „Premium“ planui.',
                'The safety check is complete, but the extended AI explanation requires Premium.',
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => Navigator.push(
                c,
                MaterialPageRoute(builder: (_) => const SubscriptionPage()),
              ),
              child: Text(tx(c, 'Peržiūrėti planus', 'View plans')),
            ),
          ],
        ),
      );
    }
    if (!aiConsent) {
      return card(
        Text(
          tx(
            c,
            'AI analizė nevykdyta – sveikatos duomenys neišsiųsti.',
            'AI analysis was not run — no health data was sent.',
          ),
        ),
      );
    }
    if (!AiSymptomService.isConfigured) {
      return card(
        Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, color: green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tx(
                  c,
                  'AI analizė paruošta. Ji bus aktyvuota prijungus saugų „Firebase“ servisą.',
                  'AI analysis is ready and will activate after connecting the secure Firebase service.',
                ),
              ),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<SymptomExplanation?>(
      future: aiAssessment,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return card(
            const Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('AI analizuoja pateiktą informaciją…')),
              ],
            ),
          );
        }
        if (snapshot.hasError) {
          return card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.medication_outlined, color: green),
                  SizedBox(width: 8),
                  Text('Vaistinėlės informacija', style: TextStyle(fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 8),
                Text(tx(
                  c,
                  'Rodome tinkamus vaistus iš jūsų vaistinėlės. Paspauskite vaistą ir pamatysite vartojimą bei svarbius perspėjimus.',
                  'Showing suitable medicines from your cabinet. Tap a medicine for use information and important warnings.',
                )),
              ],
            ),
          );
        }
        if (snapshot.data == null) {
          return card(Text(tx(
            c,
            'Rodome tinkamus vaistus iš jūsų vaistinėlės. Paspauskite vaistą ir pamatysite vartojimą bei svarbius perspėjimus.',
            'Showing suitable medicines from your cabinet. Tap a medicine for use information and important warnings.',
          )));
        }
        return card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: green),
                  const SizedBox(width: 8),
                  Text(
                    tx(c, 'AI paaiškinimas', 'AI explanation'),
                    style: const TextStyle(fontWeight: FontWeight.w700, color: navy),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...snapshot.data!.sections.entries.map((section) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tx(c, section.key, const {
                      'Kas galėtų būti': 'Possible causes',
                      'Ką daryti dabar': 'What to do now',
                      'Vaistai ir vartojimas': 'Medicines and use',
                      'Kada kreiptis pagalbos': 'When to seek help',
                    }[section.key] ?? section.key), style: const TextStyle(
                      fontWeight: FontWeight.w700, color: navy)),
                    const SizedBox(height: 6),
                    Text(section.value),
                  ],
                ),
              )),
              ...widget.data.meds.where((m) =>
                (m.memberIds.isEmpty || m.memberIds.contains(widget.memberId)) &&
                m.aiSourceUrls.isNotEmpty).map((m) => ExpansionTile(
                  title: Text(tx(c, '${m.name}: informacijos šaltiniai',
                    '${m.name}: information sources')),
                  children: [
                    if (m.aiSearchHtml.isNotEmpty)
                      GroundingSearchWidget(html: m.aiSearchHtml),
                    ...List.generate(m.aiSourceUrls.length, (i) => ListTile(
                      title: Text(i < m.aiSourceTitles.length
                        ? m.aiSourceTitles[i] : m.aiSourceUrls[i]),
                      onTap: () => launchUrl(Uri.parse(m.aiSourceUrls[i]),
                        mode: LaunchMode.externalApplication),
                    )),
                  ],
                )),
              const SizedBox(height: 6),
              Text(
                tx(
                  c,
                  'Tai nėra diagnozė ar gydymo paskyrimas.',
                  'This is not a diagnosis or treatment prescription.',
                ),
                style: const TextStyle(fontSize: 12, color: Color(0xff526572)),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _categoryQuestions(BuildContext c) => switch (widget.category) {
    'Peršalimas' => [
      _yesNo(
        c,
        tx(c, 'Ar yra temperatūra?', 'Do you have a fever?'),
        fever,
        (v) => fever = v,
      ),
      if (fever)
        _yesNo(
          c,
          tx(c, 'Ar temperatūra 39 °C ar aukštesnė?', 'Is it 39°C or higher?'),
          highFever,
          (v) => highFever = v,
        ),
      _yesNo(
        c,
        tx(
          c,
          'Ar sunku kvėpuoti arba jaučiate dusulį?',
          'Difficulty breathing or shortness of breath?',
        ),
        breathingProblem,
        (v) => breathingProblem = v,
      ),
    ],
    'Karščiavimas' => [
      _yesNo(
        c,
        tx(c, 'Ar temperatūra 39 °C ar aukštesnė?', 'Is it 39°C or higher?'),
        highFever,
        (v) => highFever = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar yra neįprastas bėrimas?', 'Is there an unusual rash?'),
        rash,
        (v) => rash = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar sunku kvėpuoti?', 'Difficulty breathing?'),
        breathingProblem,
        (v) => breathingProblem = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar alpstate arba esate sumišę?', 'Fainting or confusion?'),
        faintingOrConfusion,
        (v) => faintingOrConfusion = v,
      ),
    ],
    'Alergija' => [
      _yesNo(
        c,
        tx(
          c,
          'Ar tinsta veidas, lūpos arba liežuvis?',
          'Swelling of the face, lips or tongue?',
        ),
        swelling,
        (v) => swelling = v,
      ),
      _yesNo(
        c,
        tx(
          c,
          'Ar sunku kvėpuoti arba ryti?',
          'Difficulty breathing or swallowing?',
        ),
        breathingProblem,
        (v) => breathingProblem = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar bėrimas greitai plinta?', 'Is the rash spreading quickly?'),
        rash,
        (v) => rash = v,
      ),
    ],
    'Viduriavimas / užkietėjimas' => [
      _yesNo(
        c,
        tx(c, 'Ar pykina arba vemiate?', 'Nausea or vomiting?'),
        vomiting,
        (v) => vomiting = v,
      ),
      if (vomiting)
        _yesNo(
          c,
          tx(c, 'Ar vėmimas kartojasi?', 'Is vomiting persistent?'),
          persistentVomiting,
          (v) => persistentVomiting = v,
        ),
      _yesNo(
        c,
        tx(
          c,
          'Ar nepavyksta gerti arba išlaikyti skysčių?',
          'Unable to drink or keep fluids down?',
        ),
        cannotDrink,
        (v) => cannotDrink = v,
      ),
      _yesNo(
        c,
        tx(
          c,
          'Ar išmatose pastebėjote kraujo?',
          'Have you noticed blood in stool?',
        ),
        blood,
        (v) => blood = v,
      ),
    ],
    'Pilvo problemos' => [
      _yesNo(
        c,
        tx(c, 'Ar yra temperatūra?', 'Do you have a fever?'),
        fever,
        (v) => fever = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar pykina arba vemiate?', 'Nausea or vomiting?'),
        vomiting,
        (v) => vomiting = v,
      ),
      if (vomiting)
        _yesNo(
          c,
          tx(
            c,
            'Ar vėmimas kartojasi ir nepavyksta gerti?',
            'Persistent vomiting or unable to drink?',
          ),
          persistentVomiting,
          (v) => persistentVomiting = v,
        ),
      _yesNo(
        c,
        tx(c, 'Ar pastebėjote kraujo?', 'Have you noticed blood?'),
        blood,
        (v) => blood = v,
      ),
    ],
    'Odos problemos' => [
      _yesNo(
        c,
        tx(
          c,
          'Ar bėrimas arba paraudimas greitai plinta?',
          'Is the rash or redness spreading quickly?',
        ),
        rash,
        (v) => rash = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar tinsta veidas arba lūpos?', 'Swelling of the face or lips?'),
        swelling,
        (v) => swelling = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar sunku kvėpuoti?', 'Difficulty breathing?'),
        breathingProblem,
        (v) => breathingProblem = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar yra temperatūra?', 'Do you have a fever?'),
        fever,
        (v) => fever = v,
      ),
    ],
    'Galvos svaigimas' => [
      _yesNo(
        c,
        tx(c, 'Ar alpstate arba esate sumišę?', 'Fainting or confusion?'),
        faintingOrConfusion,
        (v) => faintingOrConfusion = v,
      ),
      _yesNo(
        c,
        tx(
          c,
          'Ar sunku kalbėti, matyti arba valdyti galūnes?',
          'Difficulty speaking, seeing or controlling a limb?',
        ),
        neurologicDeficit,
        (v) => neurologicDeficit = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar pykina arba vemiate?', 'Nausea or vomiting?'),
        vomiting,
        (v) => vomiting = v,
      ),
    ],
    _ => [
      _yesNo(
        c,
        tx(c, 'Ar yra temperatūra?', 'Do you have a fever?'),
        fever,
        (v) => fever = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar pastebėjote kraujo?', 'Have you noticed blood?'),
        blood,
        (v) => blood = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar sunku kvėpuoti?', 'Difficulty breathing?'),
        breathingProblem,
        (v) => breathingProblem = v,
      ),
      _yesNo(
        c,
        tx(c, 'Ar alpstate arba esate sumišę?', 'Fainting or confusion?'),
        faintingOrConfusion,
        (v) => faintingOrConfusion = v,
      ),
    ],
  };

  Widget _choice(
    BuildContext c,
    String label,
    List<String> values,
    String selected,
    ValueChanged<String> onSelect,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: navy,
        ),
      ),
      const SizedBox(height: 7),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: values
            .map(
              (value) => ChoiceChip(
                label: Text(value),
                selected: selected == value,
                onSelected: (_) => setState(() => onSelect(value)),
              ),
            )
            .toList(),
      ),
    ],
  );

  Widget _yesNo(
    BuildContext c,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    value: value,
    onChanged: (next) => setState(() => onChanged(next)),
  );

  Widget _resultStep(BuildContext c) {
    if (dangerous) return _dangerResult(c);
    final member = widget.data.members
        .where((x) => x.id == widget.memberId)
        .firstOrNull;
    final allergyText =
        '${member?.allergies ?? ''} '
                '${member?.intolerantMedicines ?? ''}'
            .toLowerCase();
    final matches = widget.data.meds.where((medicine) {
      if (medicine.prescription || medicine.stock <= 0) return false;
      if (widget.memberId.isNotEmpty &&
          medicine.memberIds.isNotEmpty &&
          !medicine.memberIds.contains(widget.memberId))
        return false;
      if (!_matchesSymptomCategory(
        medicine,
        widget.category,
        details: widget.initialDetails,
      )) return false;
      final expiryDays = daysUntilMedicineExpiry(
        medicine.expiry,
        DateTime.now(),
      );
      if (expiryDays != null && expiryDays < 0) return false;
      final identity = '${medicine.name} ${medicine.substance}'.toLowerCase();
      final allergyWords = allergyText
          .split(RegExp(r'[,;\s]+'))
          .where((word) => word.length > 3);
      return !allergyWords.any(identity.contains);
    }).toList();
    return ListView(
      key: const ValueKey('safe'),
      padding: const EdgeInsets.all(18),
      children: [
        const Center(
          child: CircleAvatar(
            radius: 42,
            backgroundColor: mint,
            child: Icon(Icons.check_circle, size: 58, color: green),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          tx(
            c,
            'Pagal pateiktus atsakymus pavojingų požymių nenustatyta',
            'No danger signs identified from the answers provided',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            color: green,
          ),
        ),
        const SizedBox(height: 10),
        card(
          Text(
            tx(
              c,
              'Tai nėra diagnozė. Jei būklė blogėja, simptomai stiprėja ar kelia nerimą – kreipkitės į gydytoją.',
              'This is not a diagnosis. Seek medical care if symptoms worsen or concern you.',
            ),
          ),
        ),
        const SizedBox(height: 10),
        _aiCard(c),
        const SizedBox(height: 14),
        Text(
          tx(
            c,
            'Asmens ir bendroje vaistinėlėje radome:',
            'Found in the personal and shared medicine cabinet:',
          ),
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: navy,
          ),
        ),
        const SizedBox(height: 8),
        if (matches.isEmpty)
          card(
            Text(
              tx(
                c,
                'Tinkamų ir galiojančių nereceptinių vaistų nerasta.',
                'No suitable, unexpired non-prescription medicines found.',
              ),
            ),
          ),
        ...matches.map((medicine) {
          final isShared = medicine.memberIds.isEmpty;
          final source = isShared
              ? tx(c, 'Bendra vaistinėlė', 'Shared medicine cabinet')
              : tx(
                  c,
                  'Priskirta pasirinktam asmeniui',
                  'Assigned to selected person',
                );
          final guidance = member == null
              ? null
              : calculateDoseGuidance(medicine, member);
          final doseLine = guidance == null
              ? tx(
                  c,
                  'Asmeninė dozė dar nenustatyta. Vartojimo informaciją rasite atidarę vaistą.',
                  'A personal dose is not yet available. Open the medicine for use information.',
                )
              : '${tx(c, 'Pagal patvirtintą lapelį', 'From approved leaflet')}: '
                    '${quantityLabel(guidance.doseMg)} mg'
                    '${guidance.volumeMl == null ? '' : ' • ${quantityLabel(guidance.volumeMl!)} ml'}'
                    '${guidance.units == null ? '' : ' • ${quantityLabel(guidance.units!)} ${tx(c, 'vnt.', 'units')}'}';
          return Card(
            child: ListTile(
              leading:
                  medicine.imagePath.isNotEmpty &&
                      File(medicine.imagePath).existsSync()
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(medicine.imagePath),
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const CircleAvatar(
                      backgroundColor: mint,
                      child: Icon(Icons.medication, color: green),
                    ),
              title: Text(
                '${medicine.name} ${medicine.strength}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '$source • ${medicine.substance}\n'
                '${_matchReason(c, widget.category)}\n$doseLine\n'
                '${tx(c, 'Turite', 'In stock')}: ${quantityLabel(medicine.stock)} ${doseUnitLabel(c, medicine.stockUnit)}',
              ),
              isThreeLine: false,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => MedicineAiPage(
                    data: widget.data,
                    medicine: medicine,
                    initialQuestion:
                        'Mano simptomai: ${widget.initialDetails.isEmpty ? widget.category : widget.initialDetails}. '
                        'Paaiškink, kodėl šis vaistas galėtų tikti, kaip jį vartoti pagal kortelėje patvirtintą informaciją, '
                        'į ką atkreipti dėmesį ir kada jo nevartoti. Asmens amžiaus grupė: ${member?.ageGroup ?? 'nenurodyta'}, '
                        'svoris: ${member?.weight ?? 'nenurodytas'}, alergijos: ${member?.allergies ?? 'nenurodytos'}, '
                        'ligos: ${member?.conditions ?? 'nenurodytos'}. Nekurk nepatvirtintos dozės.',
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(c),
          icon: const Icon(Icons.restart_alt),
          label: Text(tx(c, 'Pradėti iš naujo', 'Start again')),
        ),
      ],
    );
  }

  Widget _dangerResult(BuildContext c) {
    final signs = <String>[
      if (severity == 'labai stiprus')
        tx(c, 'Labai stiprūs simptomai', 'Very severe symptoms'),
      if (highFever)
        tx(
          c,
          'Temperatūra 39 °C ar aukštesnė',
          'Temperature of 39°C or higher',
        ),
      if (persistentVomiting)
        tx(
          c,
          'Nuolatinis vėmimas arba nepavyksta gerti',
          'Persistent vomiting or unable to drink',
        ),
      if (cannotDrink)
        tx(
          c,
          'Nepavyksta gerti arba išlaikyti skysčių',
          'Unable to drink or keep fluids down',
        ),
      if (blood) tx(c, 'Pastebėtas kraujas', 'Blood reported'),
      if (breathingProblem) tx(c, 'Sunku kvėpuoti', 'Difficulty breathing'),
      if (swelling)
        tx(
          c,
          'Tinsta veidas, lūpos arba liežuvis',
          'Swelling of the face, lips or tongue',
        ),
      if (faintingOrConfusion)
        tx(c, 'Alpimas arba sumišimas', 'Fainting or confusion'),
      if (neurologicDeficit)
        tx(
          c,
          'Kalbos, regėjimo arba galūnių valdymo sutrikimas',
          'Speech, vision or limb control problem',
        ),
      if (widget.category == 'Pilvo problemos' &&
          location == 'Dešinėje' &&
          fever &&
          vomiting)
        tx(
          c,
          'Pilvo skausmas dešinėje su temperatūra ir vėmimu',
          'Right-sided abdominal pain with fever and vomiting',
        ),
    ];
    return ListView(
      key: const ValueKey('danger'),
      padding: const EdgeInsets.all(18),
      children: [
        const Center(
          child: CircleAvatar(
            radius: 42,
            backgroundColor: Color(0xffffe7e7),
            child: Icon(Icons.warning_rounded, size: 54, color: Colors.red),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          tx(c, 'Galimi pavojingi požymiai', 'Possible danger signs'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w700,
            color: Colors.red,
          ),
        ),
        const SizedBox(height: 12),
        ...signs.map(
          (sign) => ListTile(
            leading: const Icon(Icons.circle, size: 10, color: Colors.red),
            title: Text(sign),
          ),
        ),
        Card(
          color: const Color(0xffffe7e7),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tx(
                c,
                'Rekomenduojama nedelsiant kreiptis į gydytoją arba skubios pagalbos skyrių. Jei kyla grėsmė gyvybei – skambinkite 112.',
                'Seek urgent medical assessment. Call emergency services if there is an immediate threat to life.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xffa31717),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Clipboard.setData(const ClipboardData(text: '112'))
              .then(
                (_) => ScaffoldMessenger.of(c).showSnackBar(
                  SnackBar(
                    content: Text(
                      tx(c, 'Numeris 112 nukopijuotas.', '112 copied.'),
                    ),
                  ),
                ),
              ),
          icon: const Icon(Icons.emergency_outlined),
          label: Text(tx(c, 'Kopijuoti numerį 112', 'Copy emergency number')),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => setState(() => step = 1),
          child: Text(tx(c, 'Patikslinti atsakymus', 'Review answers')),
        ),
      ],
    );
  }
}

String _matchReason(BuildContext c, String category) => switch (category) {
  'Skausmas' => tx(
    c,
    'Gali būti susijęs su pasirinktu skausmo simptomu.',
    'May relate to the selected pain symptom.',
  ),
  'Karščiavimas' => tx(
    c,
    'Paskirtis susijusi su karščiavimu.',
    'Its purpose relates to fever.',
  ),
  'Peršalimas' => tx(
    c,
    'Paskirtis susijusi su peršalimo simptomais.',
    'Its purpose relates to cold symptoms.',
  ),
  'Pilvo problemos' || 'Viduriavimas / užkietėjimas' => tx(
    c,
    'Paskirtis susijusi su virškinimo simptomais.',
    'Its purpose relates to digestive symptoms.',
  ),
  'Alergija' => tx(
    c,
    'Paskirtis susijusi su alergijos simptomais.',
    'Its purpose relates to allergy symptoms.',
  ),
  _ => tx(
    c,
    'Atitinka vaisto kortelėje nurodytą paskirtį.',
    'Matches the purpose recorded on the medicine card.',
  ),
};

class MatchesPage extends StatelessWidget {
  final AppData data;
  final String category;
  final VoidCallback onChanged;
  const MatchesPage({
    super.key,
    required this.data,
    required this.category,
    required this.onChanged,
  });
  @override
  Widget build(c) {
    final m = data.meds
        .where((x) => _matchesSymptomCategory(x, category) && !x.prescription)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(tx(c, 'Ką turiu?', 'What do I have?'))),
      body: ListView(
        padding: scrollPagePadding(c),
        children: [
          Text(
            tx(
              c,
              'Rodomi tik vaistinėlėje esantys nereceptiniai preparatai. Tai nėra gydymo paskyrimas.',
              'Only non-prescription medicines in your cabinet are shown. This is not a treatment recommendation.',
            ),
          ),
          if (m.isEmpty)
            card(
              Text(
                tx(
                  c,
                  'Tinkamų preparatų nerasta.',
                  'No matching medicines found.',
                ),
              ),
            ),
          ...m.map(
            (x) => Card(
              child: ListTile(
                title: Text(
                  '${x.name} ${x.strength}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(x.purpose),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) =>
                        MedicinePage(data: data, med: x, onChanged: onChanged),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _matchesSymptomCategory(Med medicine, String symptom, {String details = ''}) {
  final categories = _splitCategories(medicine.category)
      .map((x) => x.toLowerCase())
      .toSet();
  final normalizedDetails = details.toLowerCase();
  final inferred = <String>{};
  if (RegExp(r'pykin|vėm|viduri|užkiet|pilv|skrand|rėmuo').hasMatch(normalizedDetails)) {
    inferred.addAll({'pilvo problemos', 'virškinimas'});
  }
  if (RegExp(r'skaud|maud|migren|galv').hasMatch(normalizedDetails)) {
    inferred.addAll({'skausmas', 'skausmas ir karščiavimas', 'nervų sistema'});
  }
  if (RegExp(r'karš|temperat|šaltkr').hasMatch(normalizedDetails)) {
    inferred.addAll({'skausmas', 'skausmas ir karščiavimas', 'peršalimas'});
  }
  if (RegExp(r'slog|kos|gerkl|peršal').hasMatch(normalizedDetails)) {
    inferred.addAll({'peršalimas', 'kvėpavimo sistema'});
  }
  if (RegExp(r'alerg|bėrim|niež|čiaud').hasMatch(normalizedDetails)) inferred.add('alergija');
  final expected = switch (symptom) {
    'Skausmas' || 'Karščiavimas' => {'skausmas', 'skausmas ir karščiavimas'},
    'Peršalimas' => {'peršalimas', 'kvėpavimo sistema'},
    'Pilvo problemos' ||
    'Viduriavimas / užkietėjimas' => {'pilvo problemos', 'virškinimas'},
    'Alergija' => {'alergija'},
    'Odos problemos' => {'oda'},
    'Galvos svaigimas' => {'nervų sistema', 'kraujas', 'širdis ir kraujotaka'},
    _ => {symptom.toLowerCase()},
  };
  expected.addAll(inferred);
  final searchable = '${medicine.category} ${medicine.purpose} ${medicine.name} ${medicine.substance}'.toLowerCase();
  return categories.any(expected.contains) || expected.any(searchable.contains);
}
