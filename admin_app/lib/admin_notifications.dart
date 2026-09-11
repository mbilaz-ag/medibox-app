import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_models.dart';
import 'admin_repository.dart';

class AdminNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _knownKey = 'medibox_admin_known_pending_v1';
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings);
    _initialized = true;
  }

  static Future<bool> requestPermission() async {
    await initialize();
    if (!Platform.isAndroid) return false;
    return await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        false;
  }

  static Future<void> seedKnown(Iterable<PremiumRequest> requests) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _knownKey,
      requests.map((item) => item.uid).toSet().toList(),
    );
  }

  static Future<int> checkForNewRequests({bool notify = true}) async {
    await initialize();
    final current = FirebaseAuth.instance.currentUser;
    if (current == null ||
        !AdminRepository.allowedEmails.contains(
          (current.email ?? '').toLowerCase(),
        )) {
      return 0;
    }
    final pending = await AdminRepository().pendingRequests();
    final preferences = await SharedPreferences.getInstance();
    final known = preferences.getStringList(_knownKey)?.toSet() ?? <String>{};
    final newItems = pending.where((item) => !known.contains(item.uid)).toList();
    await seedKnown(pending);
    if (notify && newItems.isNotEmpty) {
      final first = newItems.first;
      final title = newItems.length == 1
          ? 'Nauja Premium užklausa'
          : 'Naujos Premium užklausos: ${newItems.length}';
      final body = newItems.length == 1
          ? '${first.email.isEmpty ? 'Vartotojas' : first.email} prašo ${_plan(first.requestedPlan)} plano.'
          : 'Atidarykite MediBox Admin ir peržiūrėkite laukiančias užklausas.';
      await _plugin.show(
        91001,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'premium_requests_v1',
            'Premium užklausos',
            channelDescription: 'Naujos MediBox Premium planų užklausos',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
            playSound: true,
          ),
        ),
        payload: 'premium_requests',
      );
    }
    return newItems.length;
  }

  static String _plan(String value) =>
      value == 'premium_yearly' ? 'metinio' : 'mėnesinio';
}

