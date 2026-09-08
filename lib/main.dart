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
import 'services/dose_guidance.dart';
import 'widgets/body_map.dart';
import 'models/leaflet_draft.dart';
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
  int step = 1;
  String choice = 'self';
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: step == 0 ? _welcome(context) : _choice(context),
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
          onPressed: () => setState(() => step = 1),
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

  Widget _choice(BuildContext context) {
    final options = [
      ('self', Icons.person_outline, tx(context, 'Aš', 'Me')),
      ('child', Icons.child_care, tx(context, 'Mano vaikas', 'My child')),
      (
        'family',
        Icons.family_restroom,
        tx(context, 'Kitas šeimos narys', 'Another family member'),
      ),
      (
        'shared',
        Icons.home_outlined,
        tx(context, 'Bendra vaistinėlė', 'Shared cabinet'),
      ),
    ];
    return ListView(
      key: const ValueKey('choice'),
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => step = 0),
              icon: const Icon(Icons.arrow_back),
            ),
            const MediBoxLogo(size: 42),
            const SizedBox(width: 10),
            const Text(
              'MediBox',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: navy,
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        Text(
          tx(context, 'Kas naudosis „MediBox“?', 'Who will use MediBox?'),
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            color: navy,
          ),
        ),
        const SizedBox(height: 16),
        ...options.map(
          (o) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => choice = o.$1),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: choice == o.$1
                      ? const Color(0xffe6f7f2)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: choice == o.$1 ? green : const Color(0xffe0eeeb),
                    width: choice == o.$1 ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    RoleAvatar(type: o.$1),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        o.$3,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (choice == o.$1)
                      const Icon(Icons.check_circle, color: green),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            widget.data.onboarded = true;
            if (choice == 'self' &&
                !widget.data.members.any((x) => x.relation == 'self')) {
              widget.data.members.add(
                Member(
                  id: newId(),
                  name: widget.data.profile.name.isEmpty
                      ? tx(context, 'Aš', 'Me')
                      : widget.data.profile.name,
                  relation: 'self',
                ),
              );
            }
            widget.onChanged();
          },
          child: Text(tx(context, 'Tęsti', 'Continue')),
        ),
      ],
    );
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
                          data.profile.name.isEmpty
                              ? tx(c, 'Labas! 👋', 'Hello! 👋')
                              : tx(
                                  c,
                                  'Labas, ${data.profile.name}! 👋',
                                  'Hello, ${data.profile.name}! 👋',
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
                                child: CircularProgressIndicator(
                                  value: active.isEmpty
                                      ? 0
                                      : taken / active.length,
                                  strokeWidth: 12,
                                  backgroundColor: const Color(0xffe1e8ec),
                                  strokeCap: StrokeCap.round,
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
                  'liko ${quantityLabel(medicine.stock)} vnt.',
                  '${quantityLabel(medicine.stock)} remaining',
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
  onTap: () => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => FamilyPage(data: data, onChanged: onChanged),
    ),
  ),
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
          width: 112,
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
  if (r.memberId.isEmpty) return me;
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
                                    '${quantityLabel(m.stock)} vnt.',
                                    '${quantityLabel(m.stock)} left',
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
    final value = (suggested ?? question.text).trim().isEmpty
        ? 'Trumpai paaiškink, kam skirtas šis vaistas, kaip jį saugiai vartoti ir į ką atkreipti dėmesį.'
        : (suggested ?? question.text).trim();
    if (busy) return;
    // Automatically generated patient context is sent to AI but never exposed
    // in the editable question field.
    if (suggested == null) question.text = value;
    setState(() { busy = true; error = ''; });
    try {
      final result = await AiMedicineAdvisorService.ask(
        medicine: widget.medicine,
        question: value,
      );
      if (mounted) setState(() => answer = result);
    } catch (_) {
      if (mounted) {
        setState(() {
          answer = AiMedicineAdvisorService.localFallback(
            widget.medicine,
            question: value,
          );
          error = tx(
            context,
            'Šiuo metu rodoma patikrinta informacija iš jūsų vaisto kortelės.',
            'Showing the verified information from your medicine card for now.',
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
      padding: const EdgeInsets.all(18),
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

class MedicinePage extends StatelessWidget {
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
                        ? () => Navigator.push(
                              c,
                              MaterialPageRoute(
                                builder: (_) => MedicineAiPage(
                                  data: data,
                                  medicine: med,
                                  initialQuestion:
                                      'Paaiškink šį vaistą: kam jis skirtas, kaip vartojamas ir į ką svarbiausia atkreipti dėmesį.',
                                ),
                              ),
                            )
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
                        Text(med.purpose),
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
                          '${tx(c, 'Likutis', 'Stock')}: ${quantityLabel(med.stock)}',
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
                (tx(c, 'Kaip vartoti?', 'How to use?'), med.dosage),
                (
                  tx(c, 'Priminimai', 'Reminders'),
                  data.reminders
                      .where((r) => r.medId == med.id)
                      .map((r) => '${r.time} — ${r.dose} ${r.doseUnit}'.trim())
                      .join('\n'),
                ),
              ]),
              _medicineSectionsTab(c, [
                (tx(c, 'Svarbu žinoti', 'Important'), med.warnings),
                (
                  tx(c, 'Dažnesni šalutiniai poveikiai', 'Common side effects'),
                  med.sideEffects,
                ),
              ]),
              _medicineSectionsTab(c, [
                (
                  tx(
                    c,
                    'Sąveikos su kitais vaistais',
                    'Interactions with medicines',
                  ),
                  med.interactions,
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
                    '${doseGuidance.units == null ? '' : ' • ${quantityLabel(doseGuidance.units!)} vnt.'}',
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
      padding: const EdgeInsets.all(18),
      children: [
        card(
          Text(
            '${widget.medicine.name} ${widget.medicine.strength}\n'
            '${tx(context, 'Bendras likutis', 'Total stock')}: ${quantityLabel(widget.medicine.stock)}',
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
                '${quantityLabel(item.quantity)} ${tx(context, 'vnt.', 'units')}',
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
      purpose = TextEditingController(text: widget.medicine?.purpose ?? ''),
      dosage = TextEditingController(text: widget.medicine?.dosage ?? ''),
      warnings = TextEditingController(text: widget.medicine?.warnings ?? ''),
      sideEffects = TextEditingController(
        text: widget.medicine?.sideEffects ?? '',
      ),
      interactions = TextEditingController(
        text: widget.medicine?.interactions ?? '',
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

  @override
  void initState() {
    super.initState();
    name.addListener(_scheduleVvktSearch);
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
    if (widget.data.aiConsentGranted) _autoFillProfile(medicine);
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

      setState(() {
        fill(purpose, profile.purpose);
        fill(dosage, profile.dosage);
        fill(warnings, profile.warnings);
        fill(sideEffects, profile.sideEffects);
        fill(interactions, profile.interactions);
        fill(storageLocation, profile.storage);
        selectedCategories.addAll(profile.categories);
        _aiSourceTitles = profile.sourceTitles;
        _aiSourceUrls = profile.sourceUrls;
        _aiSearchHtml = profile.searchHtml;
        if (leaflet.text.trim().isEmpty && profile.sourceUrls.isNotEmpty) {
          leaflet.text = profile.sourceUrls.first;
        }
        _aiUpdatedAt = DateTime.now().toUtc().toIso8601String();
        _aiProfileMessage = tx(
          context,
          'Kortelės informacija užpildyta automatiškai. Patikrinkite ir išsaugokite.',
          'Card information was filled automatically. Review and save.',
        );
      });
    } catch (_) {
      if (mounted)
        setState(
          () => _aiProfileMessage = tx(
            context,
            'Kortelė papildyta pagrindine vaisto informacija.',
            'The card has been filled with the core medicine information.',
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
    if (mounted) setState(() => imagePath = saved.path);
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
    if (widget.data.members.isEmpty) return const SizedBox.shrink();
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
        Text(
          tx(c, 'Kam skirtas vaistas?', 'Who is this medicine for?'),
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
        field(c, stock, 'Kiekis', 'Quantity', number: true),
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
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
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
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) => MemberEditor(data: data, onChanged: onChanged),
            ),
          ),
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
) => Card(
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
    subtitle: Text(relationName(c, member.relation)),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.push(
      c,
      MaterialPageRoute(
        builder: (_) =>
            MemberEditor(data: data, member: member, onChanged: onChanged),
      ),
    ),
  ),
);

const relations = [
  'self',
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

class MemberEditor extends StatefulWidget {
  final AppData data;
  final Member? member;
  final VoidCallback onChanged;
  const MemberEditor({
    super.key,
    required this.data,
    this.member,
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
  late String relation = widget.member?.relation ?? 'self';
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
        if (widget.member != null)
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
          ...widget.data.meds
              .where((m) => m.memberIds.contains(widget.member!.id))
              .map(
                (m) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.medication_outlined, color: green),
                  title: Text('${m.name} ${m.strength}'.trim()),
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

class HealthCalendarPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const HealthCalendarPage({
    super.key,
    required this.data,
    required this.onChanged,
  });
  @override
  State<HealthCalendarPage> createState() => _HealthCalendarPageState();
}

class _HealthCalendarPageState extends State<HealthCalendarPage> {
  DateTime selectedDay = DateTime.now();
  String memberId = '';

  @override
  Widget build(BuildContext context) {
    final key = dateKey(selectedDay);
    final doses =
        widget.data.reminders
            .where(
              (item) =>
                  reminderAppliesOn(item, selectedDay) &&
                  (memberId.isEmpty || item.memberId == memberId),
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
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day + index - 2);
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
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
                final value = await showDatePicker(
                  context: context,
                  initialDate: selectedDay,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (value != null) setState(() => selectedDay = value);
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
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: days.length,
            separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (context, index) {
              final day = days[index];
              final selected = dateKey(day) == key;
              return ChoiceChip(
                selected: selected,
                onSelected: (_) => setState(() => selectedDay = day),
                label: SizedBox(
                  width: 47,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat(
                          'E',
                          Localizations.localeOf(context).languageCode,
                        ).format(day),
                      ),
                      Text(
                        '${day.day}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Text(
          DateFormat('yyyy-MM-dd').format(selectedDay),
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
        ...appointments.map(
          (item) => Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.medical_services_outlined, color: green),
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
                color: item.completed ? green : null,
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
        ),
        ...doses.map(
          (item) => Card(
            child: ListTile(
              leading: Icon(
                item.takenDates.contains(key)
                    ? Icons.check_circle
                    : Icons.medication_outlined,
                color: item.takenDates.contains(key)
                    ? green
                    : const Color(0xffff9f1c),
              ),
              title: Text(
                '${item.time} • ${item.title}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(_who(widget.data, item, tx(context, 'Aš', 'Me'))),
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
          ),
        ),
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
            ReminderNotifications.requestPermissions();
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
      padding: const EdgeInsets.all(18),
      children: [
        if (showTitle) ...[
          title(tx(c, 'Priminimai', 'Reminders')),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await ReminderNotifications.requestPermissions();
                  await ReminderNotifications.scheduleAll(data);
                  await ReminderNotifications.showTest();
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
      memberId = widget.reminder?.memberId ?? widget.initialMemberId,
      time = widget.reminder?.time ?? '08:00';
  late String doseUnit = widget.reminder?.doseUnit ?? 'vnt.';
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
            setState(() => medId = v!);
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
            DropdownMenuItem(value: '', child: Text(tx(c, 'Man', 'Me'))),
            ...widget.data.members.map(
              (m) => DropdownMenuItem(value: m.id, child: Text(m.name)),
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
                initialValue: doseUnit,
                decoration: InputDecoration(
                  labelText: tx(c, 'Vienetas', 'Unit'),
                ),
                items: const ['vnt.', 'tabletė', 'kapsulė', 'ml', 'dozė']
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (value) => setState(() => doseUnit = value!),
              ),
            ),
          ],
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
            r.doseUnit = doseUnit;
            r.quantityPerDose = amount;
            r.instructions = instructions.text.trim();
            r.startDate = startDate.text.trim();
            r.endDate = endDate.text.trim();
            r.weekdays = [...days];
            r.enabled = enabled;
            if (widget.reminder == null) widget.data.reminders.add(r);
            await ReminderNotifications.requestPermissions();
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
        padding: const EdgeInsets.all(18),
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
  Future<void> _addCustomItem() async {
    final name = TextEditingController();
    final quantity = TextEditingController(text: '1');
    var prescription = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tx(context, 'Pridėti į sąrašą', 'Add to list')),
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
                widget.data.shopping.add(
                  ShoppingItem(
                    id: newId(),
                    name: name.text.trim(),
                    quantity: value,
                    prescription: prescription,
                  ),
                );
                widget.onChanged();
                Navigator.pop(dialogContext);
                setState(() {});
              },
              child: Text(tx(context, 'Pridėti', 'Add')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    quantity.dispose();
  }

  void _addLowStock() {
    for (final medicine in widget.data.meds.where(
      (medicine) => medicine.stock <= 10,
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

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Pirkinių sąrašas', 'Shopping list'))),
    body: ListView(
      padding: const EdgeInsets.all(18),
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
          onPressed: _addCustomItem,
          icon: const Icon(Icons.add_shopping_cart),
          label: Text(tx(c, 'Pridėti rankiniu būdu', 'Add manually')),
        ),
        if (widget.data.shopping.isEmpty)
          card(
            Text(tx(c, 'Pirkinių sąrašas tuščias.', 'Shopping list is empty.')),
          ),
        ...widget.data.shopping.map(
          (item) => Card(
            child: CheckboxListTile(
              value: item.purchased,
              title: Text(item.name),
              subtitle: Text(
                [
                  '${tx(c, 'Kiekis', 'Quantity')}: ${quantityLabel(item.quantity)}',
                  if (item.prescription)
                    tx(c, 'Reikalingas receptas', 'Prescription required'),
                ].join(' • '),
              ),
              secondary: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  widget.data.shopping.remove(item);
                  widget.onChanged();
                  setState(() {});
                },
              ),
              onChanged: (checked) {
                final wasPurchased = item.purchased;
                item.purchased = checked ?? false;
                final medicine = widget.data.meds
                    .where((med) => med.id == item.medId)
                    .firstOrNull;
                if (medicine != null && !wasPurchased && item.purchased) {
                  medicine.stock += item.quantity;
                }
                widget.onChanged();
                setState(() {});
              },
            ),
          ),
        ),
      ],
    ),
  );
}

String _doctorSummary(AppData data) {
  final p = data.profile;
  final buffer = StringBuffer('MEDIBOX – SVEIKATOS SANTRAUKA\n\n')
    ..writeln('Vardas: ${p.name}')
    ..writeln('Gimimo data: ${p.birthDate}')
    ..writeln('Kraujo grupė: ${p.bloodType}')
    ..writeln('Alergijos: ${p.allergies}')
    ..writeln('Sveikatos būklės: ${p.conditions}')
    ..writeln(
      'Skubios pagalbos kontaktas: ${p.emergencyName} ${p.emergencyPhone}',
    )
    ..writeln('\nVARTOJAMI VAISTAI');
  for (final medicine in data.meds) {
    buffer.writeln(
      '• ${medicine.name} ${medicine.strength} – ${medicine.dosage}',
    );
  }
  final upcomingAppointments =
      data.appointments.where((item) {
          final at = DateTime.tryParse('${item.date}T${item.time}');
          return !item.completed && at != null && at.isAfter(DateTime.now());
        }).toList()
        ..sort((a, b) => '${a.date}${a.time}'.compareTo('${b.date}${b.time}'));
  if (upcomingAppointments.isNotEmpty) {
    buffer.writeln('\nARTĖJANTYS VIZITAI');
    for (final item in upcomingAppointments) {
      buffer.writeln(
        '• ${item.date} ${item.time} – ${item.title}'
        '${item.doctor.isEmpty ? '' : ', ${item.doctor}'}',
      );
    }
  }
  buffer.writeln(
    '\nSukurta: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
  );
  return buffer.toString();
}

class DoctorSummaryPage extends StatelessWidget {
  final AppData data;
  const DoctorSummaryPage({super.key, required this.data});
  @override
  Widget build(BuildContext c) {
    final summary = _doctorSummary(data);
    return Scaffold(
      appBar: AppBar(
        title: Text(tx(c, 'Santrauka gydytojui', 'Doctor summary')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          card(SelectableText(summary)),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: summary));
              if (c.mounted)
                ScaffoldMessenger.of(c).showSnackBar(
                  SnackBar(
                    content: Text(
                      tx(c, 'Santrauka nukopijuota.', 'Summary copied.'),
                    ),
                  ),
                );
            },
            icon: const Icon(Icons.copy),
            label: Text(tx(c, 'Kopijuoti santrauką', 'Copy summary')),
          ),
        ],
      ),
    );
  }
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
        padding: const EdgeInsets.all(18),
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
      padding: const EdgeInsets.all(18),
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

class ProfilePage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const ProfilePage({super.key, required this.data, required this.onChanged});
  State<ProfilePage> createState() => _ProfilePage();
}

class _ProfilePage extends State<ProfilePage> {
  late final p = widget.data.profile;
  late final ctrls = [
    p.name,
    p.birthDate,
    p.phone,
    p.email,
    p.bloodType,
    p.allergies,
    p.conditions,
    p.medications,
    p.emergencyName,
    p.emergencyPhone,
    p.notes,
  ].map((value) => TextEditingController(text: value)).toList();
  @override
  void dispose() {
    for (final x in ctrls) x.dispose();
    super.dispose();
  }

  @override
  Widget build(c) {
    final labels = [
      ['Vardas', 'Name'],
      ['Gimimo data', 'Date of birth'],
      ['Telefonas', 'Phone'],
      ['El. paštas', 'Email'],
      ['Kraujo grupė', 'Blood type'],
      ['Alergijos', 'Allergies'],
      ['Lėtinės būklės', 'Medical conditions'],
      ['Nuolat vartojami vaistai', 'Regular medications'],
      ['Skubios pagalbos kontaktas', 'Emergency contact'],
      ['Kontakto telefonas', 'Emergency phone'],
      ['Pastabos', 'Notes'],
    ];
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
          ...List.generate(ctrls.length, (i) {
            if (i == 1) {
              return dateField(
                c,
                ctrls[i],
                'Gimimo data YYYY-MM-DD',
                'Date of birth YYYY-MM-DD',
              );
            }
            return field(
              c,
              ctrls[i],
              labels[i][0],
              labels[i][1],
              lines: i >= 5 ? 2 : 1,
            );
          }),
          FilledButton(
            onPressed: () {
              p.name = ctrls[0].text.trim();
              p.birthDate = ctrls[1].text.trim();
              p.phone = ctrls[2].text.trim();
              p.email = ctrls[3].text.trim();
              p.bloodType = ctrls[4].text.trim();
              p.allergies = ctrls[5].text.trim();
              p.conditions = ctrls[6].text.trim();
              p.medications = ctrls[7].text.trim();
              p.emergencyName = ctrls[8].text.trim();
              p.emergencyPhone = ctrls[9].text.trim();
              p.notes = ctrls[10].text.trim();
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
            () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => DoctorSummaryPage(data: widget.data),
              ),
            ),
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
            () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => DataTransferPage(
                  data: widget.data,
                  onChanged: widget.onChanged,
                ),
              ),
            ),
          ),
          Card(
            child: SwitchListTile(
              secondary: const CircleAvatar(
                backgroundColor: mint,
                child: Icon(Icons.auto_awesome_rounded, color: green),
              ),
              value: widget.data.aiConsentGranted,
              title: Text(
                tx(c, 'Firebase AI / Gemini', 'Firebase AI / Gemini'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(tx(c,
                'Vienas bendras leidimas vaistų kortelėms ir „Man bloga“ analizei',
                'One permission for medicine cards and symptom analysis')),
              onChanged: (value) {
                setState(() {
                  widget.data.aiConsentGranted = value;
                  widget.data.aiConsentChoiceMade = true;
                });
                widget.onChanged();
              },
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
                Text(
                  tx(c, 'Apie programą', 'About'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('MediBox v0.18.2'),
                Text(
                  tx(
                    c,
                    'Šeimos vaistinėlės ir vaistų priminimų programa.',
                    'Family medicine cabinet and medication reminder app.',
                  ),
                ),
                const SizedBox(height: 8),
                Text('${tx(c, 'Kūrėjas', 'Creator')}: Andrius Grudinskas'),
                Text('${tx(c, 'Projektas', 'Project')}: MediBox'),
                Text(
                  tx(
                    c,
                    'Programa nepakeičia gydytojo konsultacijos ar pakuotės lapelio.',
                    'The app does not replace medical advice or the package leaflet.',
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
      padding: const EdgeInsets.all(18),
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
  Future<String?>? aiAssessment;

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

  Future<String?> _requestAiAssessment() {
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
    return AiSymptomService.assess(
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
    return FutureBuilder<String?>(
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
              const Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: green),
                  SizedBox(width: 8),
                  Text(
                    'AI paaiškinimas',
                    style: TextStyle(fontWeight: FontWeight.w700, color: navy),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(snapshot.data!),
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
                  'Dozė nerodoma – nėra patvirtintos struktūrinės lapelio taisyklės.',
                  'Dose not shown — no approved structured leaflet rule.',
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
