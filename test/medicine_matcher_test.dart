import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/services/medicine_matcher.dart';

void main() {
  test('extracts labeled year-month expiry', () {
    expect(MedicineMatcher.expiry('LOT 123 EXP: 2028-04'), '2028-04');
  });
  test('normalizes month-year expiry', () {
    expect(MedicineMatcher.expiry('TINKA IKI 04/2028'), '2028-04');
  });
  test('does not accept impossible expiry month', () {
    expect(MedicineMatcher.expiry('EXP 2028-19'), isNull);
  });
  test('selects strength and pack lines from receipt text', () {
    expect(
      MedicineMatcher.candidateLines(
        'VAISTINĖ\nPreparatas 400 mg\nPakuotė N20\nVISO 3,99',
      ),
      ['Preparatas 400 mg', 'Pakuotė N20'],
    );
  });
}
