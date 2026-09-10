import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
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
  static const _maxRepeatIndex = 48;

  // Leave room for appointments, medicine deadlines and test notifications.
  static int get _medicationScheduleLimit => Platform.isAndroid ? 180 : 48;

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
            DarwinNotificationAction.plain('snooze', 'Priminti po 10 min.'),
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

  static Future<bool> requestPermissions() async {
    if (!_initialized) return false;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final androidGranted = android == null
        ? null
        : await android.requestNotificationsPermission();
    if (androidGranted != false) {
      await android?.requestExactAlarmsPermission();
    }
    final iosGranted = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    return androidGranted ?? iosGranted ?? false;
  }

  static Future<bool> notificationsEnabled() async {
    if (!_initialized) return false;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) return await android.areNotificationsEnabled() ?? false;
    return Permission.notification.isGranted;
  }

  static Future<void> showTest(AppData data) async {
    if (!_initialized) return;
    final english = data.language == 'en';
    await _plugin.show(
      2147483000,
      english ? 'MediBox reminders work' : 'MediBox priminimas veikia',
      english
          ? 'Notifications are enabled. Scheduled reminders will appear at the selected time.'
          : 'Pranešimai įjungti. Tikrieji priminimai bus rodomi jūsų pasirinktu laiku.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'medicine_reminders',
          english ? 'Medicine reminders' : 'Vaistų priminimai',
          channelDescription: english
              ? 'Reminders for scheduled medicines'
              : 'Priminimai apie suplanuotą vaistų vartojimą',
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
    if (data.medicationNotificationsGranted) {
      final scheduledDoses = <_ScheduledDose>[];
      for (final reminder in data.reminders.where((x) => x.enabled)) {
        final firstOffset = data.repeatUnconfirmedMedicationReminders ? -1 : 0;
        for (var offset = firstOffset; offset < 14; offset++) {
          final day = DateTime(now.year, now.month, now.day + offset);
          if (!reminderAppliesOn(reminder, day)) continue;
          final due = reminderDateTime(reminder, day);
          if (due == null) continue;
          final key = _dateKey(day);
          if (reminder.takenDates.contains(key) ||
              reminder.skippedDates.contains(key)) {
            continue;
          }
          if (due.isAfter(now)) {
            scheduledDoses.add(
              _ScheduledDose(reminder, due, due, repeatIndex: 0),
            );
          }
          if (data.repeatUnconfirmedMedicationReminders) {
            final repeats = unconfirmedReminderTimes(due);
            for (var index = 0; index < repeats.length; index++) {
              final when = repeats[index];
              if (!when.isAfter(now)) continue;
              scheduledDoses.add(
                _ScheduledDose(
                  reminder,
                  due,
                  when,
                  repeatIndex: index + 1,
                ),
              );
            }
          }
        }
      }
      scheduledDoses.sort((a, b) => a.when.compareTo(b.when));
      for (final scheduled in scheduledDoses.take(_medicationScheduleLimit)) {
        await _schedule(
          scheduled.reminder,
          data,
          scheduled.when,
          occurrence: scheduled.occurrence,
          repeatIndex: scheduled.repeatIndex,
        );
      }
    }
    if (data.appointmentNotificationsGranted) {
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
        Future<void> scheduleAppointment(AndroidScheduleMode mode) =>
            _plugin.zonedSchedule(
              ('appointment-${appointment.id}').hashCode & 0x7fffffff,
              'MediBox • artėja vizitas: ${appointment.title}',
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
              androidScheduleMode: mode,
            );
        try {
          await scheduleAppointment(AndroidScheduleMode.exactAllowWhileIdle);
        } catch (_) {
          await scheduleAppointment(AndroidScheduleMode.inexactAllowWhileIdle);
        }
      }
    }
    if (data.medicationNotificationsGranted) {
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
        'MediBox • $reason po $daysBefore d.',
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
    final at = DateTime.now().add(const Duration(minutes: 10));
    await cancelOccurrence(reminder, occurrence);
    await _schedule(
      reminder,
      data,
      at,
      occurrence: occurrence,
      repeatIndex: -1,
      snoozed: true,
    );
  }

  static Future<void> cancelOccurrence(
    Reminder reminder,
    DateTime occurrence,
  ) async {
    if (!_initialized) return;
    for (var index = -1; index <= _maxRepeatIndex; index++) {
      await _plugin.cancel(_id(reminder.id, occurrence, index));
    }
    // Cancel identifiers created by MediBox 0.20.3 and older.
    await _plugin.cancel(_legacyId(reminder.id, occurrence, false));
    await _plugin.cancel(_legacyId(reminder.id, occurrence, true));
  }

  static Future<void> _schedule(
    Reminder reminder,
    AppData data,
    DateTime when, {
    required DateTime occurrence,
    required int repeatIndex,
    bool snoozed = false,
  }) async {
    final english = data.language == 'en';
    final unit = english
        ? switch (reminder.doseUnit) {
            'vnt.' => 'unit',
            'tabletė' => 'tablet',
            'kapsulė' => 'capsule',
            'dozė' => 'dose',
            _ => reminder.doseUnit,
          }
        : reminder.doseUnit;
    final member = data.members
        .where((x) => x.id == reminder.memberId)
        .map((x) => x.name)
        .firstOrNull;
    final dose = reminder.dose.isEmpty
        ? '${reminder.quantityPerDose} $unit'
        : reminder.dose;
    final body = [
      if (repeatIndex > 0)
        english
            ? 'MediBox: the previous dose is not marked as taken.'
            : 'MediBox: ankstesnė dozė dar nepažymėta kaip išgerta.',
      '${english ? 'Medicine' : 'Vaistas'}: ${reminder.title}',
      '${english ? 'Take' : 'Išgerti'}: $dose',
      if (member != null) '${english ? 'For' : 'Kam'}: $member',
      if (reminder.instructions.isNotEmpty)
        '${english ? 'Note' : 'Pastaba'}: ${reminder.instructions}',
    ].join('\n');
    final payload = '${reminder.id}|${occurrence.toIso8601String()}';
    final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'medicine_reminders',
          english ? 'Medicine reminders' : 'Vaistų priminimai',
          channelDescription: english
              ? 'Reminders for scheduled medicines'
              : 'Priminimai apie suplanuotą vaistų vartojimą',
          importance: Importance.max,
          priority: Priority.high,
          actions: [
            AndroidNotificationAction(
              'taken',
              english ? 'Taken' : 'Išgėriau',
              showsUserInterface: false,
            ),
            AndroidNotificationAction(
              'snooze',
              english ? 'Remind in 10 min.' : 'Priminti po 10 min.',
              showsUserInterface: false,
            ),
            AndroidNotificationAction(
              'skip',
              english ? 'Skip' : 'Praleisti',
              showsUserInterface: false,
            ),
          ],
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: 'medicine'),
    );
    Future<void> schedule(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          _id(reminder.id, occurrence, repeatIndex),
          snoozed
              ? english
                    ? 'MediBox • reminder after 10 min.'
                    : 'MediBox • priminimas po 10 min.'
              : repeatIndex > 0
              ? english
                    ? 'MediBox • unconfirmed medicine reminder'
                    : 'MediBox • nepatvirtintas vaistų priminimas'
              : english
                    ? 'MediBox • medicine reminder'
                    : 'MediBox • vaistų priminimas',
          body,
          tz.TZDateTime.from(when, tz.local),
          details,
          androidScheduleMode: mode,
          payload: payload,
        );
    if (snoozed) {
      try {
        await schedule(AndroidScheduleMode.exactAllowWhileIdle);
      } catch (_) {
        await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
      }
    } else {
      try {
        await schedule(AndroidScheduleMode.exactAllowWhileIdle);
      } catch (_) {
        await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
      }
    }
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

  static int _id(String reminderId, DateTime occurrence, int repeatIndex) {
    final raw = '$reminderId-${occurrence.toIso8601String()}-$repeatIndex';
    return raw.hashCode & 0x7fffffff;
  }

  static int _legacyId(
    String reminderId,
    DateTime occurrence,
    bool followUp,
  ) {
    final raw = '$reminderId-${occurrence.toIso8601String()}-$followUp';
    return raw.hashCode & 0x7fffffff;
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _ScheduledDose {
  final Reminder reminder;
  final DateTime occurrence;
  final DateTime when;
  final int repeatIndex;

  const _ScheduledDose(
    this.reminder,
    this.occurrence,
    this.when, {
    required this.repeatIndex,
  });
}
