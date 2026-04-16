import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

/// Thin wrapper over FlutterTts.
/// Exposes speak() and stop() only — cooldown and sequencing are
/// the caller's responsibility.
class TtsService {
  final FlutterTts _tts = FlutterTts();

  Future<void> init() async {
    // iOS: the camera grabs the audio session for recording, which mutes
    // speech output. Set the category to playAndRecord with mixWithOthers
    // so TTS can play alongside the camera stream.
    if (Platform.isIOS) {
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playAndRecord,
        [
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
      );
    }

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5); // slightly slower — readable from 2 m
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Stop any in-progress speech, then speak [text].
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async => _tts.stop();

  void dispose() => _tts.stop();
}
