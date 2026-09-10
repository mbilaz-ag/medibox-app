import 'dart:convert';

import 'package:http/http.dart' as http;

class AppUpdate {
  final String version;
  final String downloadUrl;

  const AppUpdate({required this.version, required this.downloadUrl});
}

class AppUpdateService {
  static const currentVersion = '0.20.4';
  static const _latestReleaseUrl =
      'https://api.github.com/repos/mbilaz-ag/medibox-app/releases/latest';

  static Future<AppUpdate?> check() async {
    try {
      final response = await http
          .get(
            Uri.parse(_latestReleaseUrl),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final version = (body['tag_name'] as String? ?? '')
          .replaceFirst(RegExp(r'^v'), '');
      if (!_isNewer(version, currentVersion)) return null;
      final assets = (body['assets'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>();
      final apk = assets
          .where(
            (asset) => (asset['name'] as String? ?? '').endsWith('.apk'),
          )
          .firstOrNull;
      final url = apk?['browser_download_url'] as String? ?? '';
      return url.isEmpty
          ? null
          : AppUpdate(version: version, downloadUrl: url);
    } catch (_) {
      return null;
    }
  }

  static bool _isNewer(String candidate, String current) {
    List<int> parse(String source) => source
        .split('.')
        .map(
          (part) =>
              int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
        )
        .toList();
    final candidateParts = parse(candidate);
    final currentParts = parse(current);
    for (var index = 0; index < 3; index++) {
      final candidatePart = index < candidateParts.length
          ? candidateParts[index]
          : 0;
      final currentPart = index < currentParts.length
          ? currentParts[index]
          : 0;
      if (candidatePart != currentPart) return candidatePart > currentPart;
    }
    return false;
  }
}
