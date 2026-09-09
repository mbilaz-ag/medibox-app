Warning: truncated output (original token count: 89022)
Total output lines: 10064

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
import 'services/firebase_leaflet_service.dart';
import 'services/cloud_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReminderNotifications.initialize();
  runApp(const App());
}

const green = Color(0xff079b7a),
    navy = Color(0xff102a43),
    mint = Color(0xffe9f8f4);
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
    ..appointmentNotificationsGranted = appointmentNotifications;

  if (camera) {
    data.cameraPermissionAsked = true;
    final status = await Permission.camera.request();
    if (!status.isGranted) data.cameraConsentGranted = false;
  }
  if (medicineNotifications || appointmentNotifications) {
    await ReminderNotifications.requestPermissions();
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

class _App extends State<App> {
  AppData? data;
  bool launchAccepted = false;
  bool authenticating = false;
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _finishOpening(AppData current) async {
    if (current.onboarded && !current.permissionsChoiceMade && mounted) {
      await _showPermissionsCenter(
        navigatorKey.currentContext!,
        current,
        firstLaunch: true,
      );
    }
    if (mounted) setState(() => launchAccepted = true);
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
    await Store.save(current);
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
  @override
  Widget build(c) {
    final d = widget.data;
    final pages = [
      HomePage(
        data: d,
        onChanged: widget.onChanged,
        memberId: selectedMemberId,
        onMemberChanged: (value) => setState(() => selectedMemberId = value),
      ),
      CabinetPage(data: d, onChanged: widget.onChanged),
      SymptomsPage(data: d, onChanged: widget.onChanged),
      FamilyPage(data: d, onChanged: widget.onChanged),
      HealthCalendarPage(data: d, onChanged: widget.onChanged),
    ];
    return Scaffold(
      backgroundColor: const Color(0xfff6fbfa),
      body: ColoredBox(
        color: const Color(0xfff6fbfa),
        child: SafeArea(child: pages[index]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (v) => setState(() => index = v),
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
  const HomePage({
    super.key,
    required this.data,
    required this.onChanged,
    this.memberId = '',
    required this.onMemberChanged,
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
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
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
                                '$taken/${active.length}\n${tx(c, 'vaistai\nišgerti', 'medicines\ntaken')}',
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (nextAppointment != null) ...[
              Card(
                color: const Color(0xffe8f7f3),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(Icons.medical_services_outlined, color: green),
                  ),
                  title: Text(
                    tx(c, 'Artimiausias vizitas', 'Next appointment'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: navy,
                    ),
                  ),
                  subtitle: Text(
                    '${nextAppointment.date} ${nextAppointment.time} • ${nextAppointment.title}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => AppointmentEditor(
                        data: data,
                        appointment: nextAppointment,
                        onChanged: onChanged,
                      ),
                    ),
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
       …59022 tokens truncated….',
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
                    '${guidance.units == null ? '' : ' • ${quantityLabel(guidance.units!)} vnt.'}';
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
                '${tx(c, 'Turite', 'In stock')}: ${quantityLabel(medicine.stock)}',
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
        padding: const EdgeInsets.all(18),
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
