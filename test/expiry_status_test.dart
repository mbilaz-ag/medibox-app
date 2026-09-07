import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/services/expiry_status.dart';

void main() {
  final now = DateTime(2026, 9, 7, 12);

  test('expiry warning starts exactly seven days before expiry', () {
    expect(medicineNeedsExpiryAttention('2026-09-15', now), isFalse);
    expect(medicineNeedsExpiryAttention('2026-09-14', now), isTrue);
  });

  test('expired medicine remains visible as an alert', () {
    expect(medicineNeedsExpiryAttention('2026-09-06', now), isTrue);
    expect(daysUntilMedicineExpiry('2026-09-06', now), -1);
  });

  test('month-only expiry uses the last day of that month', () {
    expect(daysUntilMedicineExpiry('2026-09', now), 23);
  });

  test('invalid expiry is ignored', () {
    expect(medicineNeedsExpiryAttention('2026-19', now), isFalse);
  });
}
