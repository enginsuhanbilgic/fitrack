import 'package:fitrack/engine/curl/curl_form_analyzer.dart';
import 'package:fitrack/engine/form_analyzer_base.dart';
import 'package:fitrack/engine/push_up/push_up_form_analyzer.dart';
import 'package:fitrack/engine/squat/squat_form_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'curl/_pose_fixtures.dart';

void main() {
  group('FormAnalyzerBase drain contract', () {
    test('CurlFormAnalyzer is-a FormAnalyzerBase', () {
      expect(CurlFormAnalyzer(), isA<FormAnalyzerBase>());
    });

    test('SquatFormAnalyzer is-a FormAnalyzerBase', () {
      expect(SquatFormAnalyzer(), isA<FormAnalyzerBase>());
    });

    test('PushUpFormAnalyzer is-a FormAnalyzerBase', () {
      expect(PushUpFormAnalyzer(), isA<FormAnalyzerBase>());
    });

    test('Curl consumeCompletionErrors is drained after first call', () {
      final analyzer = CurlFormAnalyzer();
      analyzer.onRepStart(buildPose());

      // First drain may emit errors based on state; second drain without an
      // intervening onRepStart MUST be empty — boundary errors are one-shot.
      analyzer.consumeCompletionErrors();
      final second = analyzer.consumeCompletionErrors();
      expect(second, isEmpty);
    });

    test(
      'Squat consumeCompletionErrorsWithDepth is drained after first call',
      () {
        final analyzer = SquatFormAnalyzer();
        analyzer.onRepStart(buildPose());
        analyzer.trackAngle(85); // below kSquatBottomAngle — clean rep.
        analyzer.consumeCompletionErrorsWithDepth(90);
        final second = analyzer.consumeCompletionErrorsWithDepth(90);
        expect(second, isEmpty);
      },
    );

    test('Squat base consumeCompletionErrors throws UnsupportedError', () {
      final FormAnalyzerBase analyzer = SquatFormAnalyzer();
      expect(analyzer.consumeCompletionErrors, throwsUnsupportedError);
    });

    test('PushUp consumeCompletionErrors is drained after first call', () {
      final analyzer = PushUpFormAnalyzer();
      analyzer.onRepStart(buildPose());
      analyzer.trackAngle(85); // below bottom threshold — clean rep.
      analyzer.consumeCompletionErrors();
      final second = analyzer.consumeCompletionErrors();
      expect(second, isEmpty);
    });
  });
}
