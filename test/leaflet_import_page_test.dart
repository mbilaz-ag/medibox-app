import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/leaflet_draft.dart';
import 'package:medibox/widgets/leaflet_import_page.dart';

const identity = LeafletIdentity('Testmed', '40 mg', 'tablets');
const quote =
    'This is a test fixture, not real medicine information or advice.';
const source = 'Testmed 40 mg tablets. $quote $quote $quote $quote';
Finder key(String name) => find.byKey(ValueKey('leaflet-$name'));

Future<void> reveal(
  WidgetTester tester,
  Finder target, {
  double delta = 250,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

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
      tester.testTextInput.hide();
      await reveal(tester, key('generate'));
      expect(requests, 0);
      expect(tester.widget<FilledButton>(key('generate')).onPressed, isNull);
      await reveal(tester, key('consent'), delta: -250);
      await tester.tap(key('consent'));
      await tester.pumpAndSettle();
      await reveal(tester, key('generate'));
      await tester.tap(key('generate'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(returned, isNull);
      await reveal(tester, key('apply'));
      expect(tester.widget<FilledButton>(key('apply')).onPressed, isNull);
      await reveal(tester, key('select-purpose'), delta: -250);
      await tester.tap(key('select-purpose'));
      await tester.pumpAndSettle();
      await reveal(tester, key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      await reveal(tester, key('apply'));
      await tester.tap(key('apply'));
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
    tester.testTextInput.hide();
    await reveal(tester, key('consent'));
    await tester.tap(key('consent'));
    await tester.pumpAndSettle();
    await reveal(tester, key('generate'));
    await tester.tap(key('generate'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('AI is unavailable.'));
    expect(find.textContaining('SECRET_PROVIDER_ERROR'), findsNothing);
    await reveal(tester, key('generate'), delta: -250);
    expect(tester.widget<FilledButton>(key('generate')).onPressed, isNotNull);
  });
}
