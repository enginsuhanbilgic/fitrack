import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/app.dart';

void main() {
  testWidgets('App starts without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const FiTrackApp());
    expect(find.text('FiTrack'), findsOneWidget);
    expect(find.text('Biceps Curl'), findsOneWidget);
  });
}
