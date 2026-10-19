import 'package:flutter_test/flutter_test.dart';
import 'package:survive_app/main.dart';

void main() {
  testWidgets('App renders with map', (WidgetTester tester) async {
    await tester.pumpWidget(const SurviveApp());
    expect(find.text('S.U.R.V.I.V.E'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);
  });
}