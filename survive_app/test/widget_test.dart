import 'package:flutter_test/flutter_test.dart';
import 'package:survive_app/main.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SurviveApp());

    // Verify the title is shown
    expect(find.text('S.U.R.V.I.V.E'), findsWidgets);

    // Verify status message is shown
    expect(find.text('Connected • Ready'), findsOneWidget);
  });
}