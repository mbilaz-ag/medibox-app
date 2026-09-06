import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/main.dart';

void main() {
  testWidgets('MediBox paleidziama', (WidgetTester tester) async {
    await tester.pumpWidget(const App());
    await tester.pump();
    expect(find.text('MediBox'), findsWidgets);
  });
}
