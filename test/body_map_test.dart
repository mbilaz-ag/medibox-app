import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/main.dart';
import 'package:medibox/models/models.dart';
import 'package:medibox/widgets/body_map.dart';

const variants = ['adult_male', 'adult_female', 'child_male', 'child_female'];
String asset(String name) => 'assets/images/body_maps/$name.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final variant in variants) {
    test('$variant landmarks follow anatomy and image bounds', () {
      final g = BodyMapGeometry.forAsset(asset(variant));
      final throat = g.markers('Gerklė').single;
      final chest = g.markers('Krūtinė').single;
      final belly = g.markers('Pilvas').single;
      expect(throat.$1.dy, lessThan(chest.$1.dy));
      expect(chest.$1.dy, lessThan(belly.$1.dy));
      expect(throat.$2, lessThan(.1));
      expect(chest.$2, lessThan(.2));
      expect(g.markers('Dešinėje').single.$1.dx, lessThan(.5));
      expect(g.markers('Kairėje').single.$1.dx, greaterThan(.5));
      expect(g.markers('Sunku pasakyti'), isEmpty);
      for (final location in ['Galva', 'Gerklė', 'Krūtinė', 'Pilvas', 'Nugara', 'Rankos', 'Kojos', 'Sąnariai / raumenys']) {
        for (final marker in g.markers(location)) {
          expect(marker.$1.dx, inInclusiveRange(marker.$2, 1 - marker.$2));
          expect(marker.$1.dy, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('$variant bundled PNG decodes at declared dimensions', () async {
      final bytes = await rootBundle.load(asset(variant));
      final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final expected = BodyMapGeometry.forAsset(asset(variant)).pixels;
      expect(frame.image.width, expected.width);
      expect(frame.image.height, expected.height);
      frame.image.dispose();
      codec.dispose();
    });
  }

  testWidgets('render all four actual body maps with throat and chest markers', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RepaintBoundary(
      key: boundaryKey,
      child: ColoredBox(color: const Color(0xfff6fbfa), child: Column(
        children: ['Gerklė', 'Krūtinė'].map((location) => Expanded(child: Row(
          children: variants.map((name) => Expanded(child: Column(children: [
            Text('$name — $location'),
            Expanded(child: Padding(padding: const EdgeInsets.all(16),
              child: BodyMapView(asset: asset(name), location: location, errorLabel: 'ERROR'))),
          ]))).toList(),
        ))).toList(),
      )),
    ))));
    await tester.runAsync(() async {
      final context = tester.element(find.byType(BodyMapView).first);
      for (final name in variants) {
        await precacheImage(AssetImage(asset(name)), context);
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('ERROR'), findsNothing);
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((item) => item.foregroundPainter is BodyMapMarkerPainter);
    expect(painters.length, 8);
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/body-map-previews/landmarks.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });

  testWidgets('wizard list and continue button stay above system navigation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = AppData(meds: [], members: [], reminders: [], profile: UserProfile());
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(bottom: 48),
          viewPadding: const EdgeInsets.only(bottom: 48),
          textScaler: TextScaler.linear(1.3),
        ), child: child!,
      ),
      home: SymptomWizardPage(data: data, memberId: '', category: 'Skausmas', onChanged: () {}),
    ));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    expect(tester.getRect(list).bottom, lessThanOrEqualTo(740 - 48));
    await tester.scrollUntilVisible(find.text('Kita vieta'), 160);
    await tester.tap(find.text('Kita vieta'));
    await tester.scrollUntilVisible(find.text('Continue'), 160);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Continue')).bottom, lessThan(740 - 48));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
