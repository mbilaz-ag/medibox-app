class MedicineMatcher {
  static List<String> candidateLines(String text) {
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.length > 2);
    final rx = RegExp(
      r'(\d+(?:[.,]\d+)?\s?(?:mg|mcg|µg|g|ml)|\bN\d+\b)',
      caseSensitive: false,
    );
    return lines.where((e) => rx.hasMatch(e)).toList();
  }

  static String? expiry(String text) {
    final patterns = [
      RegExp(
        r'(?:EXP|TINKA IKI|GALIOJA IKI)\s*[:.]?\s*(20\d{2})[-./](0[1-9]|1[0-2])',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:TINKA(?:\s+IKI)?\s*[:.]?\s*)?(0[1-9]|1[0-2])[-./](20\d{2})',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        if (p == patterns[0]) return '${m.group(1)}-${m.group(2)}';
        return '${m.group(2)}-${m.group(1)}';
      }
    }
    return null;
  }
}
