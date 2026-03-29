import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/main.dart';

void main() {
  testWidgets('App should render', (WidgetTester tester) async {
    await tester.pumpWidget(const FiTrackApp());
    expect(find.text('FiTrack Benchmark'), findsOneWidget);
  });
}
