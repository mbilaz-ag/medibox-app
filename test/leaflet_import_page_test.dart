import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/leaflet_draft.dart';
import 'package:medibox/widgets/leaflet_import_page.dart';

const identity = LeafletIdentity('Testmed', '40 mg', 'tablets');
const quote =
    'This is a test fixture, not real medicine information or advice.';
const source = 'Testmed 40 mg tablets. $quote $quote $quote $quote';

void main() {
  testWidgets(
    'no request before consent; preview needs explicit selection and review',
    (tester) async {
      var requests = 0;
      LeafletRecord? returned;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  returned = await Navigator.push<LeafletRecord>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LeafletImportPage(
                        identity: identity,
                        initialUrl: 'https://example.org/leaflet',
                        generate:
                            ({
                              required identity,
                              required sourceText,
                              required sourceUrl,
                            }) async {
                              requests++;
                              expect(sourceText, source);
                              expect(identity.toJson().keys, [
                                'name',
                                'strength',
                                'form',
                              ]);
                              return LeafletDraft.parse(
                                jsonEncode({
                                  'matchesMedicine': true,
                                  'identity': identity.toJson(),
                                  'sections': [
                                    {'field': 'purpose', 'quote': quote},
                                  ],
                                }),
                                identity: identity,
                                sourceText: sourceText,
                                sourceUrl: sourceUrl,
                                model: 'test',
                              );
                            },
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), source);
      expect(requests, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(returned, isNull);
      await tester.ensureVisible(find.byType(FilledButton));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile).first);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile).last);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(returned!.sections, {'purpose': quote});
    },
  );

  testWidgets('provider failure is recoverable and never applies a record', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LeafletImportPage(
          identity: identity,
          initialUrl: 'https://example.org/leaflet',
          generate:
              ({
                required identity,
                required sourceText,
                required sourceUrl,
              }) async {
                throw StateError('SECRET_PROVIDER_ERROR');
              },
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).at(1), source);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI is unavailable.'), findsOneWidget);
    expect(find.textContaining('SECRET_PROVIDER_ERROR'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}
