import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/models.dart';
import 'package:medibox/services/reminder_logic.dart';

void main() {
  Reminder reminder({String start = '', String end = ''}) => Reminder(
    id: 'r1',
    title: 'Euthyrox',
    medId: 'm1',
    time: '08:00',
    startDate: start,
    endDate: end,
    quantityPerDose: 1,
  );

  AppData data(Reminder reminder) => AppData(
    meds: [
      Med(
        id: 'm1',
        name: 'Euthyrox',
        substance: 'levotiroksinas',
        strength: '50 µg',
        purpose: '',
        category: '',
        expiry: '2028-01',
        stock: 10,
      ),
    ],
    members: [],
    reminders: [reminder],
    profile: UserProfile(),
  );

  test('respects reminder start and end dates', () {
    final value = reminder(start: '2026-09-08', end: '2026-09-10');
    expect(reminderAppliesOn(value, DateTime(2026, 9, 7)), isFalse);
    expect(reminderAppliesOn(value, DateTime(2026, 9, 8)), isTrue);
    expect(reminderAppliesOn(value, DateTime(2026, 9, 11)), isFalse);
  });

  test('marks dose taken once and decrements stock once', () {
    final value = reminder();
    final app = data(value);
    final when = DateTime(2026, 9, 7, 8, 5);
    markDoseTaken(app, value, when);
    markDoseTaken(app, value, when);
    expect(value.takenDates, ['2026-09-07']);
    expect(app.meds.single.stock, 9);
  });

  test('undo restores stock and skipped status is separate', () {
    final value = reminder();
    final app = data(value);
    final when = DateTime(2026, 9, 7, 8, 5);
    markDoseTaken(app, value, when);
    undoDoseTaken(app, value, when);
    markDoseSkipped(value, when);
    expect(value.takenDates, isEmpty);
    expect(value.skippedDates, ['2026-09-07']);
    expect(app.meds.single.stock, 10);
  });

  test('status becomes late after thirty minutes', () {
    final value = reminder();
    expect(reminderStatus(value, DateTime(2026, 9, 7, 8, 20)), DoseStatus.waiting);
    expect(reminderStatus(value, DateTime(2026, 9, 7, 8, 31)), DoseStatus.late);
  });
}
