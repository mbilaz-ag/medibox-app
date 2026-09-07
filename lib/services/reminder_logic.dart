import '../models/models.dart';

enum DoseStatus { upcoming, waiting, late, taken, skipped, missed }

DateTime? reminderDateTime(Reminder reminder, DateTime day) {
  final parts = reminder.time.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null || hour > 23 || minute > 59) return null;
  return DateTime(day.year, day.month, day.day, hour, minute);
}

bool reminderAppliesOn(Reminder reminder, DateTime day) {
  final date = _dateOnly(day);
  final start = _parseDate(reminder.startDate);
  final end = _parseDate(reminder.endDate);
  return reminder.enabled &&
      reminder.weekdays.contains(day.weekday) &&
      (start == null || !date.isBefore(start)) &&
      (end == null || !date.isAfter(end));
}

DoseStatus reminderStatus(Reminder reminder, DateTime now) {
  final key = _key(now);
  if (reminder.takenDates.contains(key)) return DoseStatus.taken;
  if (reminder.skippedDates.contains(key)) return DoseStatus.skipped;
  final due = reminderDateTime(reminder, now);
  if (due == null || now.isBefore(due)) return DoseStatus.upcoming;
  if (now.difference(due).inMinutes <= 30) return DoseStatus.waiting;
  final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
  return now.isAfter(endOfDay) ? DoseStatus.missed : DoseStatus.late;
}

void markDoseTaken(AppData data, Reminder reminder, DateTime when) {
  final key = _key(when);
  if (reminder.takenDates.contains(key)) return;
  reminder.skippedDates.remove(key);
  reminder.takenDates.add(key);
  reminder.takenTimes[key] = when.toIso8601String();
  final medicine = _medicine(data, reminder.medId);
  if (medicine != null) {
    var remaining = reminder.quantityPerDose;
    final batches = [...medicine.batches]
      ..sort((a, b) {
        if (a.expiry.isEmpty) return 1;
        if (b.expiry.isEmpty) return -1;
        return a.expiry.compareTo(b.expiry);
      });
    for (final batch in batches) {
      if (remaining <= 0) break;
      final used = remaining.clamp(0, batch.quantity).toDouble();
      batch.quantity -= used;
      remaining -= used;
    }
    medicine.batches.removeWhere((batch) => batch.quantity <= 0);
    medicine.stock = (medicine.stock - reminder.quantityPerDose)
        .clamp(0, medicine.stock)
        .toDouble();
  }
}

void undoDoseTaken(AppData data, Reminder reminder, DateTime when) {
  final key = _key(when);
  if (!reminder.takenDates.remove(key)) return;
  reminder.takenTimes.remove(key);
  final medicine = _medicine(data, reminder.medId);
  if (medicine != null) {
    medicine.stock += reminder.quantityPerDose;
    if (medicine.batches.isNotEmpty) {
      medicine.batches.first.quantity += reminder.quantityPerDose;
    }
  }
}

void markDoseSkipped(Reminder reminder, DateTime when) {
  final key = _key(when);
  reminder.takenDates.remove(key);
  reminder.takenTimes.remove(key);
  if (!reminder.skippedDates.contains(key)) reminder.skippedDates.add(key);
}

Med? _medicine(AppData data, String id) {
  for (final medicine in data.meds) {
    if (medicine.id == id) return medicine;
  }
  return null;
}

DateTime? _parseDate(String value) {
  if (value.isEmpty) return null;
  return DateTime.tryParse(value);
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _key(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
