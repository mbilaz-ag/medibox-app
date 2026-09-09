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

class _App extends State<App> {
  AppData? data;
  bool launchAccepted = false;
  bool authenticating = false;
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _finishOpening(AppData current) async {
    if (!current.aiConsentChoiceMade && mounted) {
      final granted = await showDialog<bool>(
        context: navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Išmaniosios MediBox funkcijos'),
          content: const Text(
            'Ar sutinkate, kad „Firebase AI / Google Gemini“ apdorotų vaisto '
            'pakuotės tekstą ir pasirinktus sveikatos duomenis: amžių, svorį, '
            'alergijas, ligas, simptomus bei tinkamus vaistinėlės įrašus? '
            'Vardas nesiunčiamas. Sutikimas išsaugomas ir daugiau nekartojamas. '
            'Dozės rodomos tik pagal patvirtintas oficialias taisykles. '
            'Po šio pasirinkimo telefonas iškart paprašys kameros prieigos, '
            'kad galėtumėte fotografuoti ir atpažinti vaistų pakuotes.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Naudoti be AI'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Sutinku ir tęsti'),
            ),
          ],
        ),
      );
      current.aiConsentChoiceMade = true;
      current.aiConsentGranted = granted == true;
      await Store.save(current);
    }
    if (!current.cameraPermissionAsked) {
      await Permission.camera.request();
      current.cameraPermissionAsked = true;
      await Store.save(current);
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
      await ReminderNotifications.requestPermissions();
      ReminderNotifications.scheduleAll(v);
      if (mounted) setState(() => data = v);
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
