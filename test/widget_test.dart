// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:guardian_wheel/app/guardian_wheel_app.dart';

void main() {
  testWidgets('Guardian app renders SOS command screen', (WidgetTester tester) async {
    await tester.pumpWidget(const GuardianWheelApp());
    expect(find.text('ONLINE (MESH: 8 PEERS)'), findsOneWidget);
    expect(find.text('HOLD\nFOR SOS'), findsOneWidget);
  });
}
