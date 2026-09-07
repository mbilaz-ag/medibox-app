import 'dart:convert';

/// AI only locates verbatim passages. It never writes medical advice or doses.
const leafletFields = <String, (String, String)>{
  'purpose': ('Kam vartojamas', 'What it is used for'),
  'usage': ('Vartojimas pagal lapelį', 'Use according to the leaflet'),
  'warnings': (
    'Įspėjimai ir kontraindikacijos',
    'Warnings and contraindications',
  ),
  'sideEffects': ('Galimas šalutinis poveikis', 'Possible side effects'),
  'interactions': ('Sąveikos', 'Interactions'),
  'storage': ('Laikymo sąlygos', 'Storage conditions'),
};

String _spaces(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
String _identityText(String text) => _spaces(text).toLowerCase();

class LeafletIdentity {
  final String name, strength, form;
  const LeafletIdentity(this.name, this.strength, this.form);

  Map<String, String> toJson() => {
    'name': name.trim(),
    'strength': strength.trim(),
    'form': form.trim(),
  };

  bool matches(LeafletIdentity other) =>
      _identityText(name) == _identityText(other.name) &&
      _identityText(strength) == _identityText(other.strength) &&
      _identityText(form) == _identityText(other.form);

  bool get isComplete => toJson().values.every((v) => v.isNotEmpty);

  factory LeafletIdentity.fromJson(Map<String, dynamic> json) =>
      LeafletIdentity(
        json['name'] as String,
        json['strength'] as String,
        json['form'] as String,
      );
}

/// The URL is user supplied, not a claim that the app fetched/verified it.
bool isLeafletUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.contains('.') &&
      uri.userInfo.isEmpty;
}

void validateLeafletInput(LeafletIdentity identity, String text, String url) {
  if (!identity.isComplete) throw const FormatException('identity');
  if (!isLeafletUrl(url)) throw const FormatException('url');
  if (text.trim().length < 200 || text.length > 60000) {
    throw const FormatException('length');
  }
  // Require all three identifiers in the supplied document before sending it.
  // Word boundaries prevent e.g. 40 mg from matching 400 mg or 140 mg.
  final document = _identityText(text);
  for (final value in identity.toJson().values) {
    final pattern = RegExp(
      '(^|[^\\p{L}\\p{N}])${RegExp.escape(_identityText(value))}(\$|[^\\p{L}\\p{N}])',
      unicode: true,
    );
    if (!pattern.hasMatch(document)) {
      throw const FormatException('document_identity');
    }
  }
}

class LeafletDraft {
  final LeafletIdentity identity;
  final String sourceUrl, model;
  final Map<String, String> sections;
  const LeafletDraft({
    required this.identity,
    required this.sourceUrl,
    required this.model,
    required this.sections,
  });

  factory LeafletDraft.parse(
    String response, {
    required LeafletIdentity identity,
    required String sourceText,
    required String sourceUrl,
    required String model,
  }) {
    validateLeafletInput(identity, sourceText, sourceUrl);
    if (response.length > 100000) throw const FormatException('response');
    final json = jsonDecode(response);
    if (json is! Map<String, dynamic> ||
        json['matchesMedicine'] != true ||
        json['identity'] is! Map<String, dynamic> ||
        json['sections'] is! List) {
      throw const FormatException('response');
    }
    final returned = LeafletIdentity.fromJson(json['identity']);
    if (!identity.matches(returned)) throw const FormatException('identity');
    final items = json['sections'] as List;
    if (items.isEmpty || items.length > leafletFields.length) {
      throw const FormatException('sections');
    }
    final result = <String, String>{};
    final document = _spaces(sourceText);
    for (final item in items) {
      if (item is! Map ||
          item['field'] is! String ||
          item['quote'] is! String) {
        throw const FormatException('section');
      }
      final field = item['field'] as String;
      final quote = _spaces(item['quote'] as String);
      if (!leafletFields.containsKey(field) ||
          result.containsKey(field) ||
          quote.length < 20 ||
          quote.length > 18000 ||
          !document.contains(quote)) {
        // Reject the entire response: no partial application of invalid output.
        throw const FormatException('unsupported_quote');
      }
      result[field] = quote;
    }
    return LeafletDraft(
      identity: identity,
      sourceUrl: sourceUrl.trim(),
      model: model,
      sections: Map.unmodifiable(result),
    );
  }

  LeafletRecord accept(Set<String> selected, DateTime now) {
    if (selected.isEmpty || selected.any((key) => !sections.containsKey(key))) {
      throw const FormatException('selection');
    }
    return LeafletRecord(
      identity: identity,
      sourceUrl: sourceUrl,
      model: model,
      acceptedAt: now.toUtc().toIso8601String(),
      sections: Map.unmodifiable({
        for (final key in selected) key: sections[key]!,
      }),
    );
  }
}

class LeafletRecord {
  final LeafletIdentity identity;
  final String sourceUrl, model, acceptedAt;
  final Map<String, String> sections;
  const LeafletRecord({
    required this.identity,
    required this.sourceUrl,
    required this.model,
    required this.acceptedAt,
    required this.sections,
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'identity': identity.toJson(),
    'sourceUrl': sourceUrl,
    'model': model,
    'acceptedAt': acceptedAt,
    'sections': sections,
  };

  /// Old backups and malformed optional data must not break the medicine list.
  static LeafletRecord? tryRead(dynamic json) {
    try {
      if (json is! Map || json['version'] != 1) return null;
      final identity = LeafletIdentity.fromJson(
        Map<String, dynamic>.from(json['identity']),
      );
      final source = json['sourceUrl'] as String;
      final accepted = json['acceptedAt'] as String;
      final sections = Map<String, String>.from(json['sections']);
      if (!identity.isComplete ||
          !isLeafletUrl(source) ||
          DateTime.tryParse(accepted) == null ||
          sections.isEmpty ||
          sections.keys.any((key) => !leafletFields.containsKey(key)) ||
          sections.values.any(
            (text) => text.length < 20 || text.length > 18000,
          )) {
        return null;
      }
      return LeafletRecord(
        identity: identity,
        sourceUrl: source,
        acceptedAt: DateTime.parse(accepted).toUtc().toIso8601String(),
        model: json['model'] as String,
        sections: Map.unmodifiable(sections),
      );
    } catch (_) {
      return null;
    }
  }
}
