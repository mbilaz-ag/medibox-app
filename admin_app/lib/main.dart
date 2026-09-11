import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';

import 'admin_models.dart';
import 'admin_notifications.dart';
import 'admin_repository.dart';
import 'firebase_options.dart';

const navy = Color(0xff102a43);
const green = Color(0xff079b7a);
const pageColor = Color(0xfff4faf8);
const backgroundTask = 'mediboxAdminPremiumCheck';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await Firebase.initializeApp(options: AdminFirebaseOptions.current);
      await AdminNotifications.checkForNewRequests();
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: AdminFirebaseOptions.current);
  await AdminNotifications.initialize();
  await Workmanager().initialize(callbackDispatcher);
  runApp(const MediBoxAdminApp());
}

class MediBoxAdminApp extends StatelessWidget {
  const MediBoxAdminApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MediBox Admin',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: pageColor,
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: const AdminGate(),
  );
}

class AdminGate extends StatefulWidget {
  const AdminGate({super.key});

  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  late final AdminRepository repository;

  @override
  void initState() {
    super.initState();
    repository = AdminRepository();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, snapshot) {
      final user = snapshot.data ?? FirebaseAuth.instance.currentUser;
      if (user == null) return LoginPage(repository: repository);
      if (!AdminRepository.allowedEmails.contains(
        (user.email ?? '').toLowerCase(),
      )) {
        return AccessDeniedPage(repository: repository);
      }
      return DashboardPage(repository: repository);
    },
  );
}

class LoginPage extends StatefulWidget {
  final AdminRepository repository;
  const LoginPage({super.key, required this.repository});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool busy = false;
  String error = '';

  Future<void> _signIn() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.repository.signIn();
    } catch (value) {
      if (mounted) setState(() => error = '$value'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    color: green,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(
                    Icons.admin_panel_settings_rounded,
                    color: Colors.white,
                    size: 58,
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'MediBox Admin',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: navy,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Vartotojų ir Premium planų valdymas',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, color: Color(0xff526575)),
                ),
                const SizedBox(height: 30),
                FilledButton.icon(
                  onPressed: busy ? null : _signIn,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  icon: const Icon(Icons.login_rounded),
                  label: Text(busy ? 'Jungiama…' : 'Prisijungti su Google'),
                ),
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 18),
                const Text(
                  'Prieiga suteikta tik patvirtintoms administratoriaus paskyroms.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xff6c7d89)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AccessDeniedPage extends StatelessWidget {
  final AdminRepository repository;
  const AccessDeniedPage({super.key, required this.repository});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 70, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              'Administratoriaus prieiga nesuteikta',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: repository.signOut,
              child: const Text('Atsijungti'),
            ),
          ],
        ),
      ),
    ),
  );
}

class DashboardPage extends StatefulWidget {
  final AdminRepository repository;
  const DashboardPage({super.key, required this.repository});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  AdminSnapshot? data;
  bool loading = true;
  String error = '';
  int tab = 0;
  String query = '';
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    _load(first: true);
    refreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _load(),
    );
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool first = false}) async {
    if (first && mounted) setState(() => loading = true);
    try {
      final result = await widget.repository.load();
      if (first) {
        await AdminNotifications.seedKnown(result.pendingRequests);
        await AdminNotifications.requestPermission();
        await Workmanager().registerPeriodicTask(
          'medibox-admin-premium-periodic-v1',
          backgroundTask,
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        await AdminNotifications.checkForNewRequests();
      }
      if (!mounted) return;
      setState(() {
        data = result;
        loading = false;
        error = '';
      });
    } catch (value) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '$value'.replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = data;
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MediBox Admin',
              style: TextStyle(fontWeight: FontWeight.w900, color: navy),
            ),
            Text(
              'Vartotojai ir Premium planai',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Atnaujinti',
            onPressed: loading ? null : () => _load(first: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') widget.repository.signOut();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('Atsijungti')),
            ],
          ),
        ],
      ),
      body: loading && snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : error.isNotEmpty && snapshot == null
          ? _ErrorState(message: error, retry: () => _load(first: true))
          : RefreshIndicator(
              onRefresh: () => _load(first: true),
              child: tab == 0
                  ? _overview(snapshot!)
                  : tab == 1
                  ? _requests(snapshot!)
                  : _users(snapshot!),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Apžvalga',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: (snapshot?.pendingRequests.length ?? 0) > 0,
              label: Text('${snapshot?.pendingRequests.length ?? 0}'),
              child: const Icon(Icons.inbox_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: (snapshot?.pendingRequests.length ?? 0) > 0,
              label: Text('${snapshot?.pendingRequests.length ?? 0}'),
              child: const Icon(Icons.inbox_rounded),
            ),
            label: 'Užklausos',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline_rounded),
            selectedIcon: Icon(Icons.people_rounded),
            label: 'Vartotojai',
          ),
        ],
      ),
    );
  }

  Widget _overview(AdminSnapshot snapshot) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (error.isNotEmpty) _message(error, Colors.red),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.55,
        children: [
          _stat('Visi vartotojai', snapshot.users.length, Icons.people),
          _stat('Free', snapshot.free, Icons.person_outline),
          _stat('Premium', snapshot.premium, Icons.workspace_premium),
          _stat('Mėnesiniai', snapshot.monthly, Icons.calendar_view_month),
          _stat('Metiniai', snapshot.yearly, Icons.calendar_month),
          _stat('Laukia', snapshot.pendingRequests.length, Icons.inbox),
        ],
      ),
      const SizedBox(height: 16),
      if (snapshot.pendingRequests.isNotEmpty)
        FilledButton.icon(
          onPressed: () => setState(() => tab = 1),
          icon: const Icon(Icons.inbox_rounded),
          label: Text(
            'Peržiūrėti laukiančias (${snapshot.pendingRequests.length})',
          ),
        ),
      const SizedBox(height: 12),
      _message(
        'Pranešimai tikrinami periodiškai. Android gali foninę patikrą atidėti, ypač įjungus energijos taupymą.',
        const Color(0xff526575),
      ),
    ],
  );

  Widget _requests(AdminSnapshot snapshot) {
    final requests = snapshot.pendingRequests;
    if (requests.isEmpty) {
      return const _EmptyState(
        icon: Icons.task_alt_rounded,
        title: 'Laukiančių užklausų nėra',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: requests.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final request = requests[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.email.isEmpty ? request.uid : request.email,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: navy,
                  ),
                ),
                const SizedBox(height: 5),
                Text(_planLabel(request.requestedPlan)),
                if (request.requestedAt != null)
                  Text('Pateikta: ${_dateTime(request.requestedAt!)}'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _reject(request),
                        child: const Text('Atmesti'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _approve(request),
                        child: const Text('Patvirtinti'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _users(AdminSnapshot snapshot) {
    final normalized = query.trim().toLowerCase();
    final users = snapshot.users.where((item) {
      return normalized.isEmpty ||
          '${item.email} ${item.name} ${item.plan}'.toLowerCase().contains(
            normalized,
          );
    }).toList();
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: users.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                hintText: 'Ieškoti pagal vardą, el. paštą ar planą',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          );
        }
        final user = users[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: CircleAvatar(
                backgroundColor: user.isPremium
                    ? const Color(0xfffff0c7)
                    : const Color(0xffe7f6f2),
                child: Icon(
                  user.isPremium ? Icons.workspace_premium : Icons.person,
                  color: user.isPremium ? const Color(0xffa86b00) : green,
                ),
              ),
              title: Text(
                user.name.isEmpty ? user.email : user.name,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                [
                  if (user.name.isNotEmpty) user.email,
                  _userPlan(user),
                  if (user.validUntil != null)
                    'Galioja iki ${_date(user.validUntil!)}',
                ].join('\n'),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _editUser(user),
            ),
          ),
        );
      },
    );
  }

  Widget _stat(String label, int value, IconData icon) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: green),
          const Spacer(),
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w900,
              color: navy,
            ),
          ),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    ),
  );

  Widget _message(String value, Color color) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Text(value, style: TextStyle(color: color)),
  );

  Future<void> _approve(PremiumRequest request) async {
    final result = await showDialog<_PlanChoice>(
      context: context,
      builder: (_) => _PlanDialog(initialPlan: request.requestedPlan),
    );
    if (result == null) return;
    try {
      await widget.repository.approve(
        request,
        plan: result.plan,
        validUntil: result.validUntil,
      );
      await _load();
      if (mounted) _toast('Premium planas patvirtintas.');
    } catch (value) {
      if (mounted) _toast('$value');
    }
  }

  Future<void> _reject(PremiumRequest request) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Atmesti užklausą?'),
        content: Text(request.email),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Atšaukti'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Atmesti'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await widget.repository.reject(request);
    await _load();
  }

  Future<void> _editUser(AdminUser user) async {
    final result = await showDialog<_PlanChoice>(
      context: context,
      builder: (_) => _PlanDialog(
        initialPlan: user.isPremium ? user.plan : 'free',
        initialUntil: user.validUntil,
        allowFree: true,
      ),
    );
    if (result == null) return;
    await widget.repository.setPlan(
      user,
      plan: result.plan,
      status: result.plan == 'free' ? 'cancelled' : 'active',
      validUntil: result.validUntil,
    );
    await _load();
    if (mounted) _toast('Vartotojo planas atnaujintas.');
  }

  void _toast(String value) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(value)));
}

class _PlanChoice {
  final String plan;
  final DateTime? validUntil;
  const _PlanChoice(this.plan, this.validUntil);
}

class _PlanDialog extends StatefulWidget {
  final String initialPlan;
  final DateTime? initialUntil;
  final bool allowFree;
  const _PlanDialog({
    required this.initialPlan,
    this.initialUntil,
    this.allowFree = false,
  });

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late String plan;
  late String duration;
  DateTime? customUntil;

  @override
  void initState() {
    super.initState();
    plan = widget.initialPlan;
    duration = widget.initialUntil == null ? 'default' : 'custom';
    customUntil = widget.initialUntil;
  }

  DateTime? get validUntil {
    final now = DateTime.now();
    if (plan == 'free' || duration == 'unlimited') return null;
    if (duration == 'custom') return customUntil;
    return plan == 'premium_yearly'
        ? DateTime(now.year + 1, now.month, now.day, 23, 59, 59)
        : DateTime(now.year, now.month + 1, now.day, 23, 59, 59);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Plano nustatymai'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: plan,
            decoration: const InputDecoration(labelText: 'Planas'),
            items: [
              if (widget.allowFree)
                const DropdownMenuItem(value: 'free', child: Text('Free')),
              const DropdownMenuItem(
                value: 'premium_monthly',
                child: Text('Premium mėnesinis'),
              ),
              const DropdownMenuItem(
                value: 'premium_yearly',
                child: Text('Premium metinis'),
              ),
            ],
            onChanged: (value) => setState(() => plan = value!),
          ),
          if (plan != 'free') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: duration,
              decoration: const InputDecoration(labelText: 'Galiojimas'),
              items: [
                DropdownMenuItem(
                  value: 'default',
                  child: Text(
                    plan == 'premium_yearly' ? '1 metai' : '1 mėnuo',
                  ),
                ),
                const DropdownMenuItem(
                  value: 'unlimited',
                  child: Text('Neterminuotai'),
                ),
                const DropdownMenuItem(
                  value: 'custom',
                  child: Text('Pasirinkti datą'),
                ),
              ],
              onChanged: (value) => setState(() => duration = value!),
            ),
            if (duration == 'custom') ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final value = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                    initialDate: customUntil ?? DateTime.now(),
                  );
                  if (value != null) setState(() => customUntil = value);
                },
                icon: const Icon(Icons.event_rounded),
                label: Text(
                  customUntil == null
                      ? 'Pasirinkti datą'
                      : _date(customUntil!),
                ),
              ),
            ],
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Atšaukti'),
      ),
      FilledButton(
        onPressed: duration == 'custom' && customUntil == null
            ? null
            : () => Navigator.pop(context, _PlanChoice(plan, validUntil)),
        child: const Text('Išsaugoti'),
      ),
    ],
  );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback retry;
  const _ErrorState({required this.message, required this.retry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.red),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: retry, child: const Text('Bandyti dar kartą')),
        ],
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  const _EmptyState({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const SizedBox(height: 130),
      Icon(icon, size: 72, color: green),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

String _planLabel(String value) => value == 'premium_yearly'
    ? 'Premium metinis'
    : value == 'premium_monthly'
    ? 'Premium mėnesinis'
    : 'Free';

String _userPlan(AdminUser user) => user.isPremium
    ? _planLabel(user.plan)
    : 'Free';

String _date(DateTime value) => DateFormat('yyyy-MM-dd').format(value);
String _dateTime(DateTime value) => DateFormat('yyyy-MM-dd HH:mm').format(value);
