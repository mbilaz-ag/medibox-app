import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('MediBox paleidziama', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const App());
    await tester.pumpAndSettle();
    expect(find.text('MediBox'), findsWidgets);
  });
}
