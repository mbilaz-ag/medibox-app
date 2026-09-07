import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import 'models/models.dart';
import 'services/medicine_matcher.dart';
import 'services/reminder_logic.dart';
import 'services/reminder_notifications.dart';
import 'services/expiry_status.dart';
import 'services/store.dart';

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
        debugShowCheckedModeBanner: false,
        locale: d != null && d.language != 'system' ? Locale(d.language) : null,
        supportedLocales: const [Locale('lt'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: LaunchScreen(
          ready: d != null,
          onStart: d == null
              ? null
              : () => setState(() => launchAccepted = true),
        ),
      );
    }
    Locale? locale;
    if (d.language != 'system') locale = Locale(d.language);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MediBox',
      locale: locale,
      supportedLocales: const [Locale('lt'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        brightness: Brightness.light,
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
  @override
  Widget build(c) {
    final d = widget.data;
    final pages = [
      HomePage(data: d, onChanged: widget.onChanged),
      CabinetPage(data: d, onChanged: widget.onChanged),
      SymptomsPage(meds: d.meds),
      FamilyPage(data: d, onChanged: widget.onChanged),
      RemindersPage(data: d, onChanged: widget.onChanged),
    ];
    return Scaffold(
      body: SafeArea(child: pages[index]),
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
            icon: const Icon(Icons.notifications_outlined),
            label: tx(c, 'Priminimai', 'Reminders'),
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
    fontWeight: FontWeight.bold,
    color: navy,
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
  const HomePage({super.key, required this.data, required this.onChanged});

  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final today = dateKey(now);
    final active =
        data.reminders
            .where((x) => reminderAppliesOn(x, now))
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final taken = active.where((x) => x.takenDates.contains(today)).length;
    final remaining = active.length - taken;
    final lowStockMeds = data.meds.where((medicine) {
      final scheduled = data.reminders.where(
        (reminder) => reminder.enabled && reminder.medId == medicine.id,
      );
      final threshold = scheduled.isEmpty
          ? 10.0
          : scheduled
                    .map((reminder) => reminder.quantityPerDose)
                    .reduce((a, b) => a > b ? a : b) *
                7;
      return medicine.stock < threshold;
    }).toList();
    final expiringMeds = data.meds
        .where((x) => medicineNeedsExpiryAttention(x.expiry, now))
        .toList()
      ..sort((a, b) =>
          (daysUntilMedicineExpiry(a.expiry, now) ?? 999999).compareTo(
            daysUntilMedicineExpiry(b.expiry, now) ?? 999999,
          ));

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
                  Text(
                    data.profile.name.isEmpty
                        ? tx(c, '☀️ Labas! 👋', '☀️ Hello! 👋')
                        : tx(
                            c,
                            '☀️ Labas, ${data.profile.name}! 👋',
                            '☀️ Hello, ${data.profile.name}! 👋',
                          ),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: navy,
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
                  builder: (_) => ProfilePage(data: data, onChanged: onChanged),
                ),
              ),
              icon: const Icon(Icons.account_circle_outlined, size: 30),
            ),
          ],
        ),
            const SizedBox(height: 14),
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
                            value: active.isEmpty ? 0 : taken / active.length,
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
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
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
                                  ? tx(c, 'Pažymėti kaip neišgertą', 'Mark as not taken')
                                  : tx(c, 'Pažymėti kaip išgertą', 'Mark as taken'),
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
            if (lowStockMeds.isNotEmpty) ...[
          _medicineStatusCard(
            context: c,
            medicines: lowStockMeds,
            icon: Icons.warning_amber_rounded,
            color: const Color(0xffff9f1c),
            background: const Color(0xfffff3df),
            title: tx(
              c,
              'Mažas vaistų likutis',
              'Low medicine stock',
            ),
            onTap: () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => CabinetPage(data: data, onChanged: onChanged),
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
                  medicines: expiringMeds,
                  now: now,
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
                    builder: (_) => ScanPage(data: data, onChanged: onChanged),
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
                    builder: (_) => SymptomsPage(meds: data.meds),
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
          return Padding(
            padding: const EdgeInsets.only(left: 36, top: 4),
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
    final relation = member?.relation.toLowerCase() ?? '';
    final face = relation.contains('child') || relation.contains('vaik')
        ? '👦'
        : relation.contains('self')
        ? '👨'
        : ['👨', '👩', '👦'][fallbackIndex % 3];
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xffdff2fb),
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(face, style: const TextStyle(fontSize: 27)),
    );
  }
}

class ExpiringMedicinesPage extends StatelessWidget {
  final List<Med> medicines;
  final DateTime now;
  const ExpiringMedicinesPage({
    super.key,
    required this.medicines,
    required this.now,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tx(context, 'Besibaigiantys vaistai', 'Expiring medicines')),
    ),
    body: ListView.separated(
      padding: const EdgeInsets.all(18),
      itemCount: medicines.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final medicine = medicines[index];
        final days = daysUntilMedicineExpiry(medicine.expiry, now);
        return Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xffffe9e8),
              child: Icon(Icons.event_busy_outlined, color: Color(0xffe53935)),
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
          ),
        );
      },
    ),
  );
}

String _who(AppData d, Reminder r, String me) {
  if (r.memberId.isEmpty) return me;
  return d.members
          .where((x) => x.id == r.memberId)
          .map((x) => x.name)
          .firstOrNull ??
      me;
}

class CabinetPage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  const CabinetPage({super.key, required this.data, required this.onChanged});
  @override
  Widget build(c) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      title(tx(c, 'Mano vaistinėlė', 'My medicine cabinet')),
      const SizedBox(height: 10),
      ...data.meds.map(
        (m) => Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: mint,
              child: Icon(Icons.medication, color: green),
            ),
            title: Text(
              '${m.name} ${m.strength}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${m.substance}\n${tx(c, 'Liko', 'Stock')}: ${quantityLabel(m.stock)} • ${m.expiry}',
            ),
            isThreeLine: true,
            onTap: () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) =>
                    MedicinePage(data: data, med: m, onChanged: onChanged),
              ),
            ),
          ),
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => Navigator.push(
          c,
          MaterialPageRoute(
            builder: (_) => MedicineEditor(data: data, onChanged: onChanged),
          ),
        ),
        icon: const Icon(Icons.add),
        label: Text(tx(c, 'Pridėti vaistą', 'Add medicine')),
      ),
    ],
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
  Widget build(c) => StatefulBuilder(
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
        if (med.imagePath.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.file(
              File(med.imagePath),
              height: 210,
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
              const Divider(),
              Text(med.purpose),
              if (med.manufacturer.isNotEmpty)
                Text('${tx(c, 'Gamintojas', 'Manufacturer')}: ${med.manufacturer}'),
              if (med.dosageForm.isNotEmpty)
                Text('${tx(c, 'Vaisto forma', 'Dosage form')}: ${med.dosageForm}'),
              if (med.category.isNotEmpty)
                Text('${tx(c, 'Kategorija', 'Category')}: ${med.category}'),
            ],
          ),
        ),
        card(
          Column(
            children: [
              Text('${tx(c, 'Likutis', 'Stock')}: ${quantityLabel(med.stock)}'),
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
              Text('${tx(c, 'Galioja iki', 'Expires')}: ${med.expiry}'),
              if (med.batchNumber.isNotEmpty)
                Text('${tx(c, 'Partijos numeris', 'Batch number')}: ${med.batchNumber}'),
              if (med.barcode.isNotEmpty)
                Text('${tx(c, 'Brūkšninis kodas', 'Barcode')}: ${med.barcode}'),
              if (med.storageLocation.isNotEmpty)
                Text('${tx(c, 'Laikymo vieta', 'Storage location')}: ${med.storageLocation}'),
            ],
          ),
        ),
        if (med.leaflet.isNotEmpty || med.notes.isNotEmpty)
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (med.leaflet.isNotEmpty)
                  Text('${tx(c, 'Informacinis lapelis', 'Leaflet')}: ${med.leaflet}'),
                if (med.notes.isNotEmpty) ...[
                  if (med.leaflet.isNotEmpty) const Divider(),
                  Text('${tx(c, 'Pastabos', 'Notes')}: ${med.notes}'),
                ],
              ],
            ),
          ),
      ],
    ),
    _medicineSectionsTab(c, [
      (tx(c, 'Kaip vartoti?', 'How to use?'), med.dosage),
      (tx(c, 'Priminimai', 'Reminders'),
          data.reminders.where((r) => r.medId == med.id)
              .map((r) => '${r.time} — ${r.dose} ${r.doseUnit}'.trim())
              .join('\n')),
    ]),
    _medicineSectionsTab(c, [
      (tx(c, 'Svarbu žinoti', 'Important'), med.warnings),
      (tx(c, 'Dažnesni šalutiniai poveikiai', 'Common side effects'), med.sideEffects),
    ]),
    _medicineSectionsTab(c, [
      (tx(c, 'Sąveikos su kitais vaistais', 'Interactions with medicines'), med.interactions),
    ]),
    _medicineSectionsTab(c, [
      (tx(c, 'Pakuotės dydis', 'Package size'), med.packageSize),
      (tx(c, 'Gamintojas', 'Manufacturer'), med.manufacturer),
      (tx(c, 'Informacinis lapelis', 'Package leaflet'), med.leaflet),
      (tx(c, 'Pastabos', 'Notes'), med.notes),
    ]),
      ],
    ),
  ),
  );
  );
}

Widget _medicineSectionsTab(
  BuildContext c,
  List<(String, String)> sections,
) =>
    ListView(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        MediaQuery.paddingOf(c).bottom + 28,
      ),
      children: sections
          .map((section) => Padding(
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
                    ? tx(c, 'Informacija dar neįvesta.', 'Information has not been entered yet.')
                    : section.$2.trim(),
              ),
            ],
          ),
        ),
      )).toList(),
    );

class MedicineEditor extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  final String sourceText;
  final String initialImagePath;
  final String initialMemberId;
  final Med? medicine;
  const MedicineEditor({
    super.key,
    required this.data,
    required this.onChanged,
    this.sourceText = '',
    this.initialImagePath = '',
    this.initialMemberId = '',
    this.medicine,
  });
  State<MedicineEditor> createState() => _MedicineEditor();
}

class _MedicineEditor extends State<MedicineEditor> {
  late final name = TextEditingController(
        text: widget.medicine?.name ?? _guessName(widget.sourceText),
      ),
      sub = TextEditingController(text: widget.medicine?.substance ?? ''),
      strength = TextEditingController(
        text: widget.medicine?.strength ?? _guessStrength(widget.sourceText),
      ),
      manufacturer = TextEditingController(text: widget.medicine?.manufacturer ?? ''),
      dosageForm = TextEditingController(text: widget.medicine?.dosageForm ?? ''),
      packageSize = TextEditingController(
        text: widget.medicine?.packageSize ?? _guessPackageSize(widget.sourceText),
      ),
      category = TextEditingController(text: widget.medicine?.category ?? ''),
      purpose = TextEditingController(text: widget.medicine?.purpose ?? ''),
      dosage = TextEditingController(text: widget.medicine?.dosage ?? ''),
      warnings = TextEditingController(text: widget.medicine?.warnings ?? ''),
      sideEffects = TextEditingController(text: widget.medicine?.sideEffects ?? ''),
      interactions = TextEditingController(text: widget.medicine?.interactions ?? ''),
      expiry = TextEditingController(
        text: widget.medicine?.expiry ?? MedicineMatcher.expiry(widget.sourceText) ?? '',
      ),
      stock = TextEditingController(text: quantityLabel(widget.medicine?.stock ?? 1)),
      batchNumber = TextEditingController(text: widget.medicine?.batchNumber ?? ''),
      barcode = TextEditingController(text: widget.medicine?.barcode ?? ''),
      storageLocation = TextEditingController(text: widget.medicine?.storageLocation ?? ''),
      leaflet = TextEditingController(text: widget.medicine?.leaflet ?? ''),
      notes = TextEditingController(text: widget.medicine?.notes ?? '');
  late bool prescription = widget.medicine?.prescription ?? false;
  late String imagePath = widget.medicine?.imagePath ?? widget.initialImagePath;
  late String expiryMode = expiry.text.length == 10 ? 'day' : 'month';

  @override
  void dispose() {
    for (final x in [
      name, sub, strength, manufacturer, dosageForm, packageSize, category,
      purpose, dosage, warnings, sideEffects, interactions, expiry,
      stock, batchNumber, barcode, storageLocation, leaflet, notes,
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (picked == null) return;
    final directory = await getApplicationDocumentsDirectory();
    final extension = picked.path.contains('.') ? picked.path.split('.').last : 'jpg';
    final id = widget.medicine?.id ?? newId();
    final saved = await File(picked.path).copy('${directory.path}/medicine_$id.$extension');
    if (mounted) setState(() => imagePath = saved.path);
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(widget.medicine == null
          ? tx(c, 'Pridėti vaistą', 'Add medicine')
          : tx(c, 'Redaguoti vaistą', 'Edit medicine')),
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
        field(c, sub, 'Veiklioji medžiaga', 'Active ingredient'),
        field(c, strength, 'Stiprumas', 'Strength'),
        field(c, manufacturer, 'Gamintojas', 'Manufacturer'),
        field(c, dosageForm, 'Vaisto forma (tabletės, sirupas...)', 'Dosage form'),
        field(c, packageSize, 'Pakuotės dydis', 'Package size'),
        field(c, category, 'Kategorija', 'Category'),
        field(c, purpose, 'Paskirtis / kam vartojamas', 'Purpose / use', lines: 2),
        field(c, dosage, 'Kaip vartoti', 'How to use', lines: 3),
        field(c, warnings, 'Svarbūs įspėjimai', 'Important warnings', lines: 3),
        field(c, sideEffects, 'Dažnesni šalutiniai poveikiai', 'Common side effects', lines: 3),
        field(c, interactions, 'Sąveikos su kitais vaistais', 'Interactions', lines: 3),
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
        field(c, stock, 'Kiekis', 'Quantity', number: true),
        field(c, batchNumber, 'Partijos numeris', 'Batch number'),
        field(c, barcode, 'Brūkšninis kodas', 'Barcode', number: true),
        field(c, storageLocation, 'Laikymo vieta', 'Storage location'),
        field(c, leaflet, 'Informacinio lapelio nuoroda', 'Leaflet link'),
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
                !_validDate(expiry.text, monthOnly: expiryMode == 'month')) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      c,
                      'Patikrink pavadinimą ir galiojimo datos formatą.',
                      'Check the name and expiry date format.',
                    ),
                  ),
                ),
              );
              return;
            }
            final parsedStock =
                double.tryParse(stock.text.trim().replaceAll(',', '.')) ?? 1;
            final existing = widget.medicine;
            if (existing == null) {
              widget.data.meds.add(Med(
                id: newId(),
                name: name.text.trim(),
                substance: sub.text.trim(),
                strength: strength.text.trim(),
                purpose: purpose.text.trim(),
                category: category.text.trim().isEmpty ? 'Kita' : category.text.trim(),
                expiry: expiry.text.trim(),
                stock: parsedStock,
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
                memberIds: widget.initialMemberId.isEmpty
                    ? null
                    : [widget.initialMemberId],
                batchNumber: batchNumber.text.trim(),
                barcode: barcode.text.trim(),
                storageLocation: storageLocation.text.trim(),
                notes: notes.text.trim(),
              ));
            } else {
              if (widget.initialMemberId.isNotEmpty &&
                  !existing.memberIds.contains(widget.initialMemberId)) {
                existing.memberIds.add(widget.initialMemberId);
              }
              existing
                ..name = name.text.trim()
                ..substance = sub.text.trim()
                ..strength = strength.text.trim()
                ..manufacturer = manufacturer.text.trim()
                ..dosageForm = dosageForm.text.trim()
                ..packageSize = packageSize.text.trim()
                ..category = category.text.trim().isEmpty ? 'Kita' : category.text.trim()
                ..purpose = purpose.text.trim()
                ..dosage = dosage.text.trim()
                ..warnings = warnings.text.trim()
                ..sideEffects = sideEffects.text.trim()
                ..interactions = interactions.text.trim()
                ..expiry = expiry.text.trim()
                ..stock = parsedStock
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

String _guessStrength(String source) =>
    RegExp(
      r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|µg|g|ml)\b',
      caseSensitive: false,
    ).firstMatch(source)?.group(0) ??
    '';

String _guessPackageSize(String source) =>
    RegExp(r'\bN\s?\d+\b', caseSensitive: false)
        .firstMatch(source)
        ?.group(0)
        ?.replaceAll(' ', '') ??
    '';

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
      const SizedBox(height: 10),
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
      ...data.members.map(
        (m) => Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: mint,
              backgroundImage: m.imagePath.isNotEmpty
                  ? FileImage(File(m.imagePath))
                  : null,
              child: m.imagePath.isEmpty
                  ? const Icon(Icons.person, color: green)
                  : null,
            ),
            title: Text(m.name),
            subtitle: Text(relationName(c, m.relation)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) =>
                    MemberEditor(data: data, member: m, onChanged: onChanged),
              ),
            ),
          ),
        ),
      ),
      FilledButton.tonalIcon(
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
      familyDoctor = TextEditingController(text: widget.member?.familyDoctor ?? ''),
      facilityPhone = TextEditingController(text: widget.member?.facilityPhone ?? ''),
      facilityAddress = TextEditingController(text: widget.member?.facilityAddress ?? ''),
      notes = TextEditingController(text: widget.member?.notes ?? '');
  late String relation = widget.member?.relation ?? 'self';
  late String imagePath = widget.member?.imagePath ?? '';
  @override
  void dispose() {
    for (final x in [
      name, birth, bloodType, height, weight, allergies, conditions,
      intolerantMedicines, healthcareFacility, familyDoctor, facilityPhone,
      facilityAddress, notes,
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
    final extension = picked.path.contains('.') ? picked.path.split('.').last : 'jpg';
    final id = widget.member?.id ?? newId();
    final saved = await File(picked.path).copy('${directory.path}/member_$id.$extension');
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
            backgroundImage: imagePath.isNotEmpty ? FileImage(File(imagePath)) : null,
            child: imagePath.isEmpty
                ? const Icon(Icons.person_outline, size: 58, color: green)
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
          onChanged: (v) => setState(() => relation = v!),
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
            Expanded(child: field(c, height, 'Ūgis (cm)', 'Height (cm)', number: true)),
            const SizedBox(width: 10),
            Expanded(child: field(c, weight, 'Svoris (kg)', 'Weight (kg)', number: true)),
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
        field(c, healthcareFacility, 'Gydymo įstaigos pavadinimas', 'Facility name'),
        field(c, familyDoctor, 'Šeimos gydytojas', 'Family doctor'),
        field(c, facilityPhone, 'Gydymo įstaigos telefonas', 'Facility phone'),
        field(c, facilityAddress, 'Gydymo įstaigos adresas', 'Facility address'),
        field(c, notes, 'Pastabos', 'Notes', lines: 3),
        if (widget.member != null) ...[
          const SizedBox(height: 4),
          Text(
            tx(c, 'Priskirti vaistai ir priminimai', 'Assigned medicines and reminders'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...widget.data.meds
              .where((m) => m.memberIds.contains(widget.member!.id))
              .map((m) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.medication_outlined, color: green),
                    title: Text('${m.name} ${m.strength}'.trim()),
                  )),
          ...widget.data.reminders
              .where((r) => r.memberId == widget.member!.id)
              .map((r) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.alarm_outlined, color: green),
                    title: Text(r.title),
                    subtitle: Text(r.time),
                  )),
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
  final VoidCallback onChanged;
  const ReminderEditor({
    super.key,
    required this.data,
    this.reminder,
    this.initialMemberId = '',
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
  late String medId = widget.reminder?.medId ?? '',
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
            if (titleC.text.isEmpty && medId.isNotEmpty)
              titleC.text = widget.data.meds
                  .firstWhere((x) => x.id == medId)
                  .name;
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
                (startDate.text.isNotEmpty &&
                    start == null) ||
                (endDate.text.isNotEmpty &&
                    end == null) ||
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
                const Text('MediBox v0.12.0'),
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
  const ScanPage({super.key, required this.data, required this.onChanged});
  State<ScanPage> createState() => _ScanPage();
}

class _ScanPage extends State<ScanPage> {
  String text = '';
  String imagePath = '';
  bool busy = false;
  Future<void> ocr(ImageSource src) async {
    if (busy) return;
    setState(() => busy = true);
    TextRecognizer? r;
    try {
      final f = await ImagePicker().pickImage(source: src, imageQuality: 90);
      if (f == null || !mounted) return;
      final directory = await getApplicationDocumentsDirectory();
      final saved = await File(f.path).copy(
        '${directory.path}/scan_${newId()}.jpg',
      );
      r = TextRecognizer(script: TextRecognitionScript.latin);
      final out = await r.processImage(InputImage.fromFilePath(saved.path));
      if (mounted) {
        setState(() {
          text = out.text;
          imagePath = saved.path;
        });
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
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
                  title: Text(tx(c, 'Visas atpažintas tekstas', 'All recognized text')),
                  children: [SelectableText(text)],
                ),
              ],
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
      final saved = await File(file.path).copy(
        '${directory.path}/scan_${newId()}.jpg',
      );
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

class SymptomsPage extends StatelessWidget {
  final List<Med> meds;
  const SymptomsPage({super.key, required this.meds});
  @override
  Widget build(c) {
    final cats = [
      ['Skausmas', 'Pain'],
      ['Karščiavimas', 'Fever'],
      ['Peršalimas', 'Cold'],
      ['Pilvo problemos', 'Stomach'],
      ['Alergija', 'Allergy'],
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tx(c, 'Man bloga', 'Symptoms'))),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          title(tx(c, 'Kas labiausiai vargina?', 'What bothers you most?')),
          Text(
            tx(
              c,
              'Vedlys nediagnozuoja. Pavojingus ar stiprėjančius simptomus turi įvertinti medikas.',
              'This guide does not diagnose. Urgent or worsening symptoms require medical assessment.',
            ),
          ),
          const SizedBox(height: 10),
          ...cats.map(
            (x) => Card(
              child: ListTile(
                leading: const Icon(Icons.health_and_safety, color: green),
                title: Text(tx(c, x[0], x[1])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => MatchesPage(meds: meds, category: x[0]),
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

class MatchesPage extends StatelessWidget {
  final List<Med> meds;
  final String category;
  const MatchesPage({super.key, required this.meds, required this.category});
  @override
  Widget build(c) {
    final m = meds
        .where((x) => x.category == category && !x.prescription)
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
                title: Text('${x.name} ${x.strength}'),
                subtitle: Text(x.purpose),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
