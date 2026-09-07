import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'models/models.dart';
import 'services/medicine_matcher.dart';
import 'services/store.dart';

void main() => runApp(const App());
const green = Color(0xff079b7a),
    navy = Color(0xff102a43),
    mint = Color(0xffe9f8f4);
String tx(BuildContext c, String lt, String en) =>
    Localizations.localeOf(c).languageCode == 'en' ? en : lt;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();

class App extends StatefulWidget {
  const App({super.key});
  State<App> createState() => _App();
}

class _App extends State<App> {
  AppData? data;
  @override
  void initState() {
    super.initState();
    Store.load().then((v) {
      if (mounted) setState(() => data = v);
    });
  }

  void changed() {
    if (data != null) {
      Store.save(data!);
      setState(() {});
    }
  }

  @override
  Widget build(c) {
    final d = data;
    if (d == null)
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    Locale? locale;
    if (d.language != 'system') locale = Locale(d.language);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MediBox',
      locale: locale,
      supportedLocales: const [Locale('lt'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: green),
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

class MediBoxLogo extends StatelessWidget {
  final double size;
  const MediBoxLogo({super.key, this.size = 64});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xff56d7ad), Color(0xff078b71)],
      ),
      borderRadius: BorderRadius.circular(size * .24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33078b71),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Icon(Icons.add_rounded, color: Colors.white, size: size * .72),
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
            'assets/images/medibox_family.webp',
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
      (
        'self',
        Icons.person_outline,
        tx(context, 'Aš pats / Aš pati', 'Myself'),
      ),
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
                    CircleAvatar(
                      backgroundColor: mint,
                      child: Icon(o.$2, color: green),
                    ),
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

class HomePage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  const HomePage({super.key, required this.data, required this.onChanged});
  @override
  Widget build(c) {
    final active = data.reminders.where((x) => x.enabled).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            const CircleAvatar(
              backgroundColor: green,
              child: Icon(Icons.medication, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'MediBox',
                style: TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.bold,
                  color: navy,
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: tx(c, 'Mano profilis', 'My profile'),
              onPressed: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => ProfilePage(data: data, onChanged: onChanged),
                ),
              ),
              icon: const Icon(Icons.account_circle_outlined),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          data.profile.name.isEmpty
              ? tx(c, 'Labas! 👋', 'Hello! 👋')
              : tx(
                  c,
                  'Labas, ${data.profile.name}! 👋',
                  'Hello, ${data.profile.name}! 👋',
                ),
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
        ),
        Text(
          tx(c, 'Tavo vaistinėlė šiandien.', 'Your medicine cabinet today.'),
        ),
        const SizedBox(height: 14),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tx(c, 'Šiandienos priminimai', 'Today’s reminders'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (active.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    tx(
                      c,
                      'Aktyvių priminimų nėra. Sukurk juos skiltyje „Priminimai“.',
                      'No active reminders. Add them under Reminders.',
                    ),
                  ),
                ),
              ...active
                  .take(4)
                  .map(
                    (r) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule, color: green),
                      title: Text('${r.time} • ${r.title}'),
                      subtitle: Text(_who(data, r, tx(c, 'Aš', 'Me'))),
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) => ScanPage(data: data, onChanged: onChanged),
            ),
          ),
          icon: const Icon(Icons.camera_alt),
          label: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              tx(c, 'Nuskenuoti vaistą / čekį', 'Scan medicine / receipt'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(builder: (_) => SymptomsPage(meds: data.meds)),
          ),
          icon: const Icon(Icons.health_and_safety),
          label: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(tx(c, 'Man bloga', 'I feel unwell')),
          ),
        ),
        const SizedBox(height: 10),
        card(
          Column(
            children: [
              ListTile(
                leading: const Icon(Icons.inventory_2, color: Colors.orange),
                title: Text(
                  tx(
                    c,
                    '${data.meds.where((x) => x.stock < 10).length} preparatų atsargos mažos',
                    '${data.meds.where((x) => x.stock < 10).length} medicines are low in stock',
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.people, color: green),
                title: Text(
                  tx(
                    c,
                    'Šeimos narių: ${data.members.length}',
                    'Family members: ${data.members.length}',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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
              '${m.substance}\n${tx(c, 'Liko', 'Stock')}: ${m.stock} • ${m.expiry}',
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
  Widget build(c) => Scaffold(
    appBar: AppBar(
      title: Text(med.name),
      actions: [
        IconButton(
          onPressed: () {
            data.meds.removeWhere((x) => x.id == med.id);
            data.reminders.removeWhere((x) => x.medId == med.id);
            onChanged();
            Navigator.pop(c);
          },
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
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
            ],
          ),
        ),
        card(
          Column(
            children: [
              Text('${tx(c, 'Likutis', 'Stock')}: ${med.stock}'),
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
            ],
          ),
        ),
      ],
    ),
  );
}

class MedicineEditor extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  final String sourceText;
  const MedicineEditor({
    super.key,
    required this.data,
    required this.onChanged,
    this.sourceText = '',
  });
  State<MedicineEditor> createState() => _MedicineEditor();
}

class _MedicineEditor extends State<MedicineEditor> {
  late final name = TextEditingController(text: _guessName(widget.sourceText)),
      sub = TextEditingController(),
      strength = TextEditingController(text: _guessStrength(widget.sourceText)),
      expiry = TextEditingController(
        text: MedicineMatcher.expiry(widget.sourceText) ?? '',
      ),
      stock = TextEditingController(text: '1');
  @override
  void dispose() {
    for (final x in [name, sub, strength, expiry, stock]) x.dispose();
    super.dispose();
  }

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Pridėti vaistą', 'Add medicine'))),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        field(c, name, 'Pavadinimas', 'Name'),
        field(c, sub, 'Veiklioji medžiaga', 'Active ingredient'),
        field(c, strength, 'Stiprumas', 'Strength'),
        field(c, expiry, 'Galioja iki (YYYY-MM)', 'Expiry (YYYY-MM)'),
        field(c, stock, 'Kiekis', 'Quantity', number: true),
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
            if (name.text.trim().isEmpty) return;
            widget.data.meds.add(
              Med(
                id: newId(),
                name: name.text.trim(),
                substance: sub.text.trim(),
                strength: strength.text.trim(),
                purpose: tx(
                  c,
                  'Informaciją tikrinkite pakuotės lapelyje.',
                  'Check the package leaflet.',
                ),
                category: 'Kita',
                expiry: expiry.text.trim(),
                stock: int.tryParse(stock.text) ?? 1,
              ),
            );
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

class FamilyPage extends StatelessWidget {
  final AppData data;
  final VoidCallback onChanged;
  const FamilyPage({super.key, required this.data, required this.onChanged});
  @override
  Widget build(c) => ListView(
    padding: const EdgeInsets.all(18),
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
            leading: const CircleAvatar(child: Icon(Icons.person)),
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
      allergies = TextEditingController(text: widget.member?.allergies ?? ''),
      conditions = TextEditingController(text: widget.member?.conditions ?? ''),
      notes = TextEditingController(text: widget.member?.notes ?? '');
  late String relation = widget.member?.relation ?? 'self';
  @override
  void dispose() {
    for (final x in [name, birth, allergies, conditions, notes]) x.dispose();
    super.dispose();
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
            onPressed: () {
              widget.data.members.removeWhere((x) => x.id == widget.member!.id);
              widget.data.reminders.removeWhere(
                (x) => x.memberId == widget.member!.id,
              );
              widget.onChanged();
              Navigator.pop(c);
            },
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
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
        field(c, birth, 'Gimimo data', 'Date of birth'),
        field(c, allergies, 'Alergijos', 'Allergies', lines: 2),
        field(
          c,
          conditions,
          'Sveikatos būklės',
          'Medical conditions',
          lines: 2,
        ),
        field(c, notes, 'Pastabos', 'Notes', lines: 3),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            final m =
                widget.member ??
                Member(id: newId(), name: '', relation: relation);
            m.name = name.text.trim();
            m.relation = relation;
            m.birthDate = birth.text.trim();
            m.allergies = allergies.text.trim();
            m.conditions = conditions.text.trim();
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
  const RemindersPage({super.key, required this.data, required this.onChanged});
  @override
  Widget build(c) {
    final rs = [...data.reminders]..sort((a, b) => a.time.compareTo(b.time));
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        title(tx(c, 'Priminimai', 'Reminders')),
        const SizedBox(height: 10),
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
  final VoidCallback onChanged;
  const ReminderEditor({
    super.key,
    required this.data,
    this.reminder,
    required this.onChanged,
  });
  State<ReminderEditor> createState() => _ReminderEditor();
}

class _ReminderEditor extends State<ReminderEditor> {
  late final titleC = TextEditingController(text: widget.reminder?.title ?? ''),
      dose = TextEditingController(text: widget.reminder?.dose ?? ''),
      instructions = TextEditingController(
        text: widget.reminder?.instructions ?? '',
      );
  late String medId = widget.reminder?.medId ?? '',
      memberId = widget.reminder?.memberId ?? '',
      time = widget.reminder?.time ?? '08:00';
  late List<int> days = [
    ...(widget.reminder?.weekdays ?? [1, 2, 3, 4, 5, 6, 7]),
  ];
  late bool enabled = widget.reminder?.enabled ?? true;
  @override
  void dispose() {
    titleC.dispose();
    dose.dispose();
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
      padding: const EdgeInsets.all(18),
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
        field(c, dose, 'Dozė / kiekis', 'Dose / amount'),
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
          onPressed: () {
            if (titleC.text.trim().isEmpty || days.isEmpty) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(
                    tx(
                      c,
                      'Įrašyk pavadinimą ir pasirink bent vieną dieną.',
                      'Enter a title and select at least one day.',
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
            r.instructions = instructions.text.trim();
            r.weekdays = [...days];
            r.enabled = enabled;
            if (widget.reminder == null) widget.data.reminders.add(r);
            widget.onChanged();
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
        padding: const EdgeInsets.all(18),
        children: [
          ...List.generate(
            ctrls.length,
            (i) => field(
              c,
              ctrls[i],
              labels[i][0],
              labels[i][1],
              lines: i >= 5 ? 2 : 1,
            ),
          ),
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
                const Text('MediBox v0.3.0'),
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

class ScanPage extends StatefulWidget {
  final AppData data;
  final VoidCallback onChanged;
  const ScanPage({super.key, required this.data, required this.onChanged});
  State<ScanPage> createState() => _ScanPage();
}

class _ScanPage extends State<ScanPage> {
  String text = '';
  bool busy = false;
  Future<void> ocr(ImageSource src) async {
    if (busy) return;
    setState(() => busy = true);
    TextRecognizer? r;
    try {
      final f = await ImagePicker().pickImage(source: src, imageQuality: 90);
      if (f == null || !mounted) return;
      r = TextRecognizer(script: TextRecognitionScript.latin);
      final out = await r.processImage(InputImage.fromFilePath(f.path));
      if (mounted) setState(() => text = out.text);
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

  @override
  Widget build(c) => Scaffold(
    appBar: AppBar(title: Text(tx(c, 'Skenuoti', 'Scan'))),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => ocr(ImageSource.camera),
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
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx(c, 'Atpažintas tekstas', 'Recognized text'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                SelectableText(text),
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
