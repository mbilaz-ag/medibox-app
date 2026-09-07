DateTime? medicineExpiryDate(String value) {
  try {
    final parts = value.split('-').map(int.parse).toList();
    if (parts.length == 2) {
      if (parts[1] < 1 || parts[1] > 12) return null;
      return DateTime(parts[0], parts[1] + 1, 0);
    }
    if (parts.length != 3) return null;
    final parsed = DateTime(parts[0], parts[1], parts[2]);
    if (parsed.year != parts[0] ||
        parsed.month != parts[1] ||
        parsed.day != parts[2]) {
      return null;
    }
    return parsed;
  } catch (_) {
    return null;
  }
}

int? daysUntilMedicineExpiry(String value, DateTime now) {
  final expiry = medicineExpiryDate(value);
  if (expiry == null) return null;
  final today = DateTime(now.year, now.month, now.day);
  return expiry.difference(today).inDays;
}

bool medicineNeedsExpiryAttention(String value, DateTime now) {
  final days = daysUntilMedicineExpiry(value, now);
  return days != null && days <= 7;
}
