import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';
import 'expiry_status.dart';
import 'reminder_logic.dart';
import 'store.dart';

typedef ReminderActionHandler = Future<void> Function(
  String action,
  String reminderId,
  DateTime occurrence,
);

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  await ReminderNotifications.handleBackgroundAction(response);
}

class ReminderNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static ReminderActionHandler? onAction;
  static bool _initialized = false;

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
            DarwinNotificationAction.plain('snooze', 'Atidėti 15 min.'),
            DarwinNotificationAction.plain('skip', 'Praleisti'),
          ],
        ),
      ],
    );
    await _plugin.initialize(
      InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _notificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    _initialized = true;
  }

  static Future<void> requestPermissions() async {
    if (!_initialized) return;
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

  static Future<void> showTest() async {
    if (!_initialized) return;
    await _plugin.show(
      2147483000,
      'MediBox priminimas veikia',
      'Pranešimai įjungti. Tikrieji priminimai bus rodomi jūsų pasirinktu laiku.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'medicine_reminders',
          'Vaistų priminimai',
          channelDescription: 'Priminimai apie suplanuotą vaistų vartojimą',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  static Future<void> scheduleAll(AppData data) async {
    if (!_initialized) return;
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
    for (final appointment in data.appointments.where((x) => !x.completed)) {
      final at = DateTime.tryParse('${appointment.date}T${appointment.time}');
      if (at == null) continue;
      final notifyAt = at.subtract(
        Duration(minutes: appointment.remindBeforeMinutes),
      );
      if (!notifyAt.isAfter(now)) continue;
      final member = data.members
          .where((x) => x.id == appointment.memberId)
          .map((x) => x.name)
          .firstOrNull;
      await _plugin.zonedSchedule(
        ('appointment-${appointment.id}').hashCode & 0x7fffffff,
        'Artėja vizitas: ${appointment.title}',
        [
          if (member != null) member,
          '${appointment.date} ${appointment.time}',
          if (appointment.doctor.isNotEmpty) appointment.doctor,
          if (appointment.facility.isNotEmpty) appointment.facility,
        ].join(' • '),
        tz.TZDateTime.from(notifyAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'health_appointments',
            'Gydytojų vizitai',
            channelDescription: 'Priminimai apie suplanuotus vizitus',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
    for (final medicine in data.meds) {
      final expiry = medicineExpiryDate(medicine.expiry);
      if (expiry != null) {
        await _scheduleMedicineDeadline(
          medicine,
          '${expiry.year.toString().padLeft(4, '0')}-'
              '${expiry.month.toString().padLeft(2, '0')}-'
              '${expiry.day.toString().padLeft(2, '0')}',
          'Baigiasi vaisto galiojimas',
          now,
        );
      }
      if (medicine.prescriptionValidUntil.isNotEmpty) {
        await _scheduleMedicineDeadline(
          medicine,
          medicine.prescriptionValidUntil,
          'Baigiasi recepto galiojimas',
          now,
        );
      }
      if (medicine.treatmentUntil.isNotEmpty) {
        await _scheduleMedicineDeadline(
          medicine,
          medicine.treatmentUntil,
          'Vaisto atsargos ir gydymo laikotarpio pabaiga',
          now,
        );
      }
    }
  }

  static Future<void> _scheduleMedicineDeadline(
    Med medicine,
    String date,
    String reason,
    DateTime now,
  ) async {
    final deadline = DateTime.tryParse(date);
    if (deadline == null) return;
    for (final daysBefore in [7, 1]) {
      final notifyAt = DateTime(
        deadline.year,
        deadline.month,
        deadline.day,
        9,
      ).subtract(Duration(days: daysBefore));
      if (!notifyAt.isAfter(now)) continue;
      await _plugin.zonedSchedule(
        ('medicine-deadline-${medicine.id}-$reason-$daysBefore').hashCode &
            0x7fffffff,
        '$reason po $daysBefore d.',
        '${medicine.name} ${medicine.strength}. '
            'Patikrinkite likutį ir prireikus suplanuokite vizitą pas gydytoją.',
        tz.TZDateTime.from(notifyAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'medicine_deadlines',
            'Receptai ir gydymo laikotarpiai',
            channelDescription: 'Priminimai apie receptų ir vaistų atsargų pabaigą',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  static Future<void> snooze(
    Reminder reminder,
    AppData data,
    DateTime occurrence,
  ) async {
    if (!_initialized) return;
    final at = DateTime.now().add(const Duration(minutes: 15));
    await _schedule(reminder, data, at, followUp: false, snoozed: true);
    await _plugin.cancel(_id(reminder.id, occurrence, false));
    await _plugin.cancel(_id(reminder.id, occurrence, true));
  }

  static Future<void> cancelOccurrence(
    Reminder reminder,
    DateTime occurrence,
  ) async {
    if (!_initialized) return;
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
      if (followUp) 'MediBox: ankstesnė dozė dar nepažymėta kaip išgerta.',
      'Vaistas: ${reminder.title}',
      'Išgerti: $dose',
      if (member != null) 'Kam: $member',
      if (reminder.instructions.isNotEmpty) 'Pastaba: ${reminder.instructions}',
    ].join('\n');
    final occurrence = followUp
        ? when.subtract(const Duration(minutes: 30))
        : when;
    final payload = '${reminder.id}|${occurrence.toIso8601String()}';
    await _plugin.zonedSchedule(
      _id(reminder.id, occurrence, followUp),
      snoozed
          ? 'MediBox • atidėta 15 min.'
          : 'MediBox • vaistų priminimas',
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
            AndroidNotificationAction('taken', 'Išgėriau', showsUserInterface: false),
            AndroidNotificationAction(
              'snooze',
              'Atidėti 15 min.',
              showsUserInterface: false,
            ),
            AndroidNotificationAction('skip', 'Praleisti', showsUserInterface: false),
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

  static Future<void> handleBackgroundAction(
    NotificationResponse response,
  ) async {
    final parts = response.payload?.split('|');
    if (parts == null || parts.length != 2) return;
    final occurrence = DateTime.tryParse(parts[1]);
    if (occurrence == null) return;
    final action = response.actionId;
    if (action == null || action.isEmpty || action == 'open') return;

    await initialize();
    final data = await Store.load();
    final matches = data.reminders.where((x) => x.id == parts[0]);
    if (matches.isEmpty) return;
    final reminder = matches.first;
    if (action == 'taken') {
      markDoseTaken(data, reminder, occurrence);
      await cancelOccurrence(reminder, occurrence);
    } else if (action == 'skip') {
      markDoseSkipped(reminder, occurrence);
      await cancelOccurrence(reminder, occurrence);
    } else if (action == 'snooze') {
      await snooze(reminder, data, occurrence);
    }
    await Store.save(data);
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
