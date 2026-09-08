import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/services/ai_symptom_service.dart';

void main() {
  test('requires all four readable sections', () {
    final result = SymptomExplanation.parse({
      'scenarios': ' Galimas sutrikimas. ',
      'selfCare': 'Pailsėkite.',
      'medicines': 'Tinkamo vaisto nėra.',
      'seekHelp': 'Būklei blogėjant kreipkitės pagalbos.',
    });
    expect(result!.sections.length, 4);
    expect(result.sections.values.first, 'Galimas sutrikimas.');
    expect(SymptomExplanation.parse({'scenarios': 'Tik dalis'}), isNull);
    expect(SymptomExplanation.parse({'summary': 'Senas formatas'}), isNull);
    expect(SymptomExplanation.parse(null), isNull);
  });
}
