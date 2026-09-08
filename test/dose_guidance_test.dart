import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/models.dart';
import 'package:medibox/services/dose_guidance.dart';

void main() {
  Member child({String weight = '20'}) => Member(
        id: 'c1',
        name: 'Vaikas',
        relation: 'child',
        ageGroup: 'child',
        weight: weight,
      );

  Med medicine() => Med(
        id: 'm1',
        name: 'Test',
        substance: 'Test',
        strength: '100 mg/5 ml',
        purpose: 'Skausmas',
        category: 'Skausmas',
        expiry: '2027-01',
        stock: 1,
        doseMgPerKg: '10',
        doseMaxSingleMg: '400',
        doseMaxDailyMg: '1200',
        doseIntervalHours: '6',
        concentrationMgPerMl: '20',
        doseRuleSource: 'https://example.org/official-leaflet',
        doseRuleVerified: true,
      );

  test('calculates mg and ml from approved structured rule', () {
    final result = calculateDoseGuidance(medicine(), child());
    expect(result?.doseMg, 200);
    expect(result?.volumeMl, 10);
    expect(result?.maxDailyMg, 1200);
    expect(result?.intervalHours, 6);
  });

  test('caps a weight-based result at maximum single dose', () {
    final result = calculateDoseGuidance(medicine(), child(weight: '60'));
    expect(result?.doseMg, 400);
  });

  test('refuses unverified or incomplete rules', () {
    final med = medicine()..doseRuleVerified = false;
    expect(calculateDoseGuidance(med, child()), isNull);
    med
      ..doseRuleVerified = true
      ..doseRuleSource = '';
    expect(calculateDoseGuidance(med, child()), isNull);
  });
}
