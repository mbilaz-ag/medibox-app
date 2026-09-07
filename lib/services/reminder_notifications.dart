[main 61b0ff3] Keep notification scheduling test safe
 1 file changed, 6 insertions(+)
  String reminderId,
  DateTime occurrence,
);

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
  }

  static Future<void> snooze(
    Reminder reminder,
    AppData data,
    DateTime occurrence,
  ) async {
    if (!_initialized) return;
    final at = DateTime.now().add(const Duration(minutes: 10));
    await _schedule(reminder, data, at, followUp: false, snoozed: true);
    await _plugin.cancel(_id(reminder.id, occurrence, true));
  }
