import 'dart:convert';

import 'package:http/http.dart' as http;

/// Safe client for the MediBox AI gateway. The Gemini credential stays on the
/// server; the mobile application only receives a medically cautious summary.
class AiSymptomService {
  static const endpoint = String.fromEnvironment('MEDIBOX_AI_ENDPOINT');

  static bool get isConfigured => endpoint.trim().isNotEmpty;

  static Future<String?> assess({
    required String category,
    required String location,
    required List<String> symptoms,
    required String severity,
    required String duration,
    required Map<String, bool> safetyAnswers,
    required List<Map<String, Object?>> cabinetMedicines,
  }) async {
    if (!isConfigured) return null;
    final response = await http
        .post(
          Uri.parse(endpoint),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'category': category,
            'location': location,
            'symptoms': symptoms,
            'severity': severity,
            'duration': duration,
            'safetyAnswers': safetyAnswers,
            'cabinetMedicines': cabinetMedicines,
          }),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final summary = decoded['summary'];
    return summary is String && summary.trim().isNotEmpty ? summary.trim() : null;
  }
}
