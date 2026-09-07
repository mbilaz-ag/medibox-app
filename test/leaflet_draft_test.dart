import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/leaflet_draft.dart';
import 'package:medibox/models/models.dart';

const identity = LeafletIdentity('Testmed', '40 mg', 'tabletės');
const quote = 'Tai tik testavimo tekstas, nesusijęs su tikro vaisto vartojimu.';
const source = 'Testmed 40 mg tabletės. $quote $quote $quote $quote';
const url = 'https://example.org/leaflet';

Map<String, dynamic> response() => {
  'matchesMedicine': true,
  'identity': identity.toJson(),
  'sections': [
    {'field': 'purpose', 'quote': quote},
  ],
};

LeafletDraft parse(Map<String, dynamic> json) => LeafletDraft.parse(
  jsonEncode(json),
  identity: identity,
  sourceText: source,
  sourceUrl: url,
  model: 'test-model',
);

void main() {
  test('client configuration targets the Android project, not Web', () {
    final json = jsonDecode(
      File('config/google-services.json').readAsStringSync(),
    );
    expect(json['project_info']['project_id'], 'medibox-6d80d');
    final clients = json['client'] as List;
    expect(
      clients.single['client_info']['android_client_info']['package_name'],
      'lt.medibox.medibox',
    );
    expect(
      clients.single['client_info']['mobilesdk_app_id'],
      contains(':android:'),
    );
  });
  test('only selected verbatim fields can be accepted with provenance', () {
    final draft = parse(response());
    final record = draft.accept({'purpose'}, DateTime.utc(2026, 9, 8));
    expect(record.sections, {'purpose': quote});
    expect(record.sourceUrl, url);
    expect(record.model, 'test-model');
    expect(record.acceptedAt, '2026-09-08T00:00:00.000Z');
    expect(() => draft.accept({}, DateTime.now()), throwsFormatException);
    expect(
      () => draft.accept({'dosage'}, DateTime.now()),
      throwsFormatException,
    );
  });
  test('rejects generated or altered dosage text not present in document', () {
    final json = response();
    json['sections'] = [
      {'field': 'usage', 'quote': 'Take 999 tablets every hour.'},
    ];
    expect(() => parse(json), throwsFormatException);
  });
  test('rejects hallucinated missing-risk claim', () {
    final json = response();
    json['sections'] = [
      {'field': 'interactions', 'quote': 'There are no interactions.'},
    ];
    expect(() => parse(json), throwsFormatException);
  });
  test('rejects identity mismatch and explicit model refusal', () {
    final json = response();
    json['identity'] = const LeafletIdentity(
      'Testmed',
      '400 mg',
      'tabletės',
    ).toJson();
    expect(() => parse(json), throwsFormatException);
    json['identity'] = identity.toJson();
    json['matchesMedicine'] = false;
    expect(() => parse(json), throwsFormatException);
  });
  test('refuses a document for another strength or a substring name', () {
    expect(
      () => validateLeafletInput(
        identity,
        source.replaceAll('40 mg', '400 mg'),
        url,
      ),
      throwsFormatException,
    );
    expect(
      () => validateLeafletInput(
        identity,
        source.replaceAll('40 mg', '140 mg'),
        url,
      ),
      throwsFormatException,
    );
    expect(
      () => validateLeafletInput(
        identity,
        source.replaceAll('Testmed', 'TestmedPlus'),
        url,
      ),
      throwsFormatException,
    );
  });
  test(
    'normalizes only whitespace for quotes and identity casing for identifiers',
    () {
      expect(
        identity.matches(
          const LeafletIdentity(' TESTMED ', '40  mg', 'tabletės'),
        ),
        isTrue,
      );
      final json = response();
      json['sections'] = [
        {'field': 'purpose', 'quote': quote.replaceAll(' ', '\n')},
      ];
      expect(parse(json).sections['purpose'], quote);
    },
  );
  test(
    'validates URL, input length and complete identity before networking',
    () {
      for (final invalid in [
        'http://example.org/a',
        'javascript:alert(1)',
        'https://user:password@example.org/a',
        '',
      ]) {
        expect(
          () => validateLeafletInput(identity, source, invalid),
          throwsFormatException,
        );
      }
      expect(
        () => validateLeafletInput(identity, 'short', url),
        throwsFormatException,
      );
      expect(
        () => validateLeafletInput(identity, 'x' * 60001, url),
        throwsFormatException,
      );
      expect(
        () => validateLeafletInput(
          const LeafletIdentity('Testmed', '', ''),
          source,
          url,
        ),
        throwsFormatException,
      );
    },
  );
  test('rejects unknown fields, duplicates and empty results atomically', () {
    for (final sections in [
      [],
      [
        {'field': 'stock', 'quote': quote},
      ],
      [
        {'field': 'purpose', 'quote': quote},
        {'field': 'purpose', 'quote': quote},
      ],
      [
        {'field': 'purpose', 'quote': quote},
        {'field': 'usage', 'quote': 'invented'},
      ],
    ]) {
      final json = response()..['sections'] = sections;
      expect(() => parse(json), throwsFormatException);
    }
  });
  test(
    'record survives medicine JSON roundtrip without changing manual fields',
    () {
      final med = Med(
        id: 'm',
        name: 'Testmed',
        substance: 'test',
        strength: '40 mg',
        dosageForm: 'tabletės',
        purpose: 'manual purpose',
        category: 'test',
        expiry: '2028-01',
        stock: 10,
        dosage: 'doctor instruction',
        leafletRecord: parse(response())
            .accept({'purpose'}, DateTime.utc(2026, 9, 8)),
      );
      final restored = Med.fromJson(jsonDecode(jsonEncode(med.toJson())));
      expect(restored.leafletRecord!.sections['purpose'], quote);
      expect(restored.purpose, 'manual purpose');
      expect(restored.dosage, 'doctor instruction');
      expect(restored.stock, 10);
      expect(restored.expiry, '2028-01');
      expect(restored.registryVerified, isFalse);
    },
  );
  test(
    'old or malformed optional record does not break legacy medicine loading',
    () {
      for (final value in [
        null,
        'invalid',
        {'version': 1},
        {'version': 2},
      ]) {
        expect(
          Med.fromJson({'id': 'old', 'name': 'old', 'leafletRecord': value})
              .leafletRecord,
          isNull,
        );
      }
    },
  );
}
