import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';
import 'reminder_logic.dart';

typedef ReminderActionHandler = Future<void> Function(
  String action,
  String reminderId,
  DateTime occurrence,
);

class ReminderNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static ReminderActionHandler? onAction;

  static Future<void> initialize() async {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Vilnius'));
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          'medicine',
          actions: [
            DarwinNotificationAction.plain('taken', 'Išgėriau'),
            DarwinNotificationAction.plain('snooze', 'Po 10 min.'),
            DarwinNotificationAction.plain('skip', 'Praleisti'),
          ],
        ),
      ],
    );
    await _plugin.initialize(
      InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _notificationResponse,
    );
  }

  static Future<void> requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static Future<void> scheduleAll(AppData data) async {
    await _plugin.cancelAll();
    final now = DateTime.now();
    var scheduledCount = 0;
    reminders:
    for (final reminder in data.reminders.where((x) => x.enabled)) {
      for (var offset = 0; offset < 14; offset++) {
        if (scheduledCount >= 60) break reminders;
        final day = DateTime(now.year, now.month, now.day + offset);
        if (!reminderAppliesOn(reminder, day)) continue;
        final due = reminderDateTime(reminder, day);
        if (due == null || !due.isAfter(now)) continue;
        final key = _dateKey(day);
        if (reminder.takenDates.contains(key) ||
            reminder.skippedDates.contains(key)) {
          continue;
        }
        await _schedule(reminder, data, due, followUp: false);
        scheduledCount++;
        if (scheduledCount >= 60) break reminders;
        await _schedule(
          reminder,
          data,
          due.add(const Duration(minutes: 30)),
          followUp: true,
        );
        scheduledCount++;
      }
    }
  }

  static Future<void> snooze(
    Reminder reminder,
    AppData data,
    DateTime occurrence,
  ) async {
    final at = DateTime.now().add(const Duration(minutes: 10));
    await _schedule(reminder, data, at, followUp: false, snoozed: true);
    await _plugin.cancel(_id(reminder.id, occurrence, true));
  }

  static Future<void> cancelOccurrence(
    Reminder reminder,
    DateTime occurrence,
  ) async {
    await _plugin.cancel(_id(reminder.id, occurrence, false));
    await _plugin.cancel(_id(reminder.id, occurrence, true));
  }

  static Future<void> _schedule(
    Reminder reminder,
    AppData data,
    DateTime when, {
    required bool followUp,
    bool snoozed = false,
  }) async {
    final member = data.members
        .where((x) => x.id == reminder.memberId)
        .map((x) => x.name)
        .firstOrNull;
    final dose = reminder.dose.isEmpty
        ? '${reminder.quantityPerDose} ${reminder.doseUnit}'
        : reminder.dose;
    final body = [
      if (followUp) 'Dar nepažymėta kaip išgerta.',
      'Išgerti $dose',
      if (member != null) member,
      if (reminder.instructions.isNotEmpty) reminder.instructions,
    ].join('\n');
    final occurrence = followUp
        ? when.subtract(const Duration(minutes: 30))
        : when;
    final payload = '${reminder.id}|${occurrence.toIso8601String()}';
    await _plugin.zonedSchedule(
      _id(reminder.id, occurrence, followUp),
      snoozed ? 'Atidėtas priminimas: ${reminder.title}' : reminder.title,
      body,
      tz.TZDateTime.from(when, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'medicine_reminders',
          'Vaistų priminimai',
          channelDescription: 'Priminimai apie suplanuotą vaistų vartojimą',
          importance: Importance.max,
          priority: Priority.high,
          actions: [
            AndroidNotificationAction('taken', 'Išgėriau', showsUserInterface: true),
            AndroidNotificationAction('snooze', 'Po 10 min.', showsUserInterface: true),
            AndroidNotificationAction('skip', 'Praleisti', showsUserInterface: true),
          ],
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: 'medicine'),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  static void _notificationResponse(NotificationResponse response) {
    final parts = response.payload?.split('|');
    if (parts == null || parts.length != 2) return;
    final occurrence = DateTime.tryParse(parts[1]);
    if (occurrence == null) return;
    final action = response.actionId;
    onAction?.call(
      action == null || action.isEmpty ? 'open' : action,
      parts[0],
      occurrence,
    );
  }

  static int _id(String reminderId, DateTime occurrence, bool followUp) {
    final raw = '$reminderId-${occurrence.toIso8601String()}-$followUp';
    return raw.hashCode & 0x7fffffff;
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
