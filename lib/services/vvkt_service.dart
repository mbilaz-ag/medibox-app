import 'dart:convert';

import 'package:http/http.dart' as http;

class VvktMedicine {
  final String name;
  final String substance;
  final String strength;
  final String dosageForm;
  final String administrationRoute;
  final String packageDescription;
  final String prescriptionStatus;
  final String registrationNumber;
  final String registrant;
  final String supplyStatus;
  final String registrationStatus;
  final String atcCode;

  const VvktMedicine({
    required this.name,
    required this.substance,
    required this.strength,
    required this.dosageForm,
    required this.administrationRoute,
    required this.packageDescription,
    required this.prescriptionStatus,
    required this.registrationNumber,
    required this.registrant,
    required this.supplyStatus,
    required this.registrationStatus,
    required this.atcCode,
  });

  factory VvktMedicine.fromJson(Map<String, dynamic> json) => VvktMedicine(
        name: '${json['preparato_pav'] ?? ''}',
        substance: '${json['veiklioji_medz_lt'] ?? ''}',
        strength: '${json['stiprumas'] ?? ''}',
        dosageForm: '${json['farmacine_forma_lt'] ?? ''}',
        administrationRoute: '${json['vartojimo_budas'] ?? ''}',
        packageDescription: '${json['pak_aprasymas'] ?? ''}',
        prescriptionStatus: '${json['pak_recepto_poreikis'] ?? json['recepto_poreikis'] ?? ''}',
        registrationNumber: '${json['pak_reg_nr'] ?? ''}',
        registrant: '${json['registruotojas'] ?? ''}',
        supplyStatus: '${json['pak_tiekimo_busena'] ?? ''}',
        registrationStatus: '${json['stadija'] ?? ''}',
        atcCode: '${json['atc_kodas'] ?? ''}',
      );
}

class VvktService {
  static const _endpoint =
      'https://get.data.gov.lt/datasets/gov/vvkt/vaistiniai_preparatai/PreparatasPakuote';

  static Future<List<VvktMedicine>> search(String name) async {
    final cleanName = name.trim();
    if (cleanName.length < 2) return [];
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'preparato_pav': '"$cleanName"',
        'limit(20)': '',
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('VVKT HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final rows = (decoded as Map<String, dynamic>)['_data'] as List? ?? [];
    return rows
        .whereType<Map>()
        .map((row) => VvktMedicine.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  static VvktMedicine? bestMatch(
    List<VvktMedicine> matches,
    String recognizedStrength,
  ) {
    if (matches.isEmpty) return null;
    final wanted = _normalized(recognizedStrength);
    final ranked = [...matches]..sort((a, b) {
        int score(VvktMedicine item) {
          var result = 0;
          if (wanted.isNotEmpty && _normalized(item.strength) == wanted) result += 8;
          if (item.supplyStatus.toLowerCase() == 'tiekiama') result += 4;
          if (item.registrationStatus.toLowerCase() != 'išregistruotas') result += 2;
          return result;
        }
        return score(b).compareTo(score(a));
      });
    return ranked.first;
  }

  static String _normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '').replaceAll('µ', 'μ');
}
