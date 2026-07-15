import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/music_recognition/music_recognition_service.dart';
import 'package:resonance/widgets/music_recognition/music_recognition_dialog.dart';

void main() {
  testWidgets('offers both sources and returns a recognized track', (tester) async {
    final service = _FakeRecognitionService();
    MusicRecognitionResult? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                selected = await showMusicRecognitionDialog(context, service: service);
              },
              child: const Text('Identify'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Identify'));
    await tester.pumpAndSettle();
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Device audio'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recognition-source-microphone')));
    await tester.pump();
    expect(service.source, MusicRecognitionSource.microphone);
    expect(find.text('Listening…'), findsOneWidget);

    service.complete(const MusicRecognitionResult(title: 'Judas', artist: 'Lady Gaga'));
    await tester.pumpAndSettle();
    expect(selected?.youtubeQuery, 'Lady Gaga Judas');
  });
}

class _FakeRecognitionService extends MusicRecognitionService {
  final Completer<MusicRecognitionResult?> _result = Completer<MusicRecognitionResult?>();
  MusicRecognitionSource? source;

  @override
  Future<MusicRecognitionResult?> recognize(
    MusicRecognitionSource source, {
    required void Function(MusicRecognitionStage stage) onStage,
  }) {
    this.source = source;
    onStage(MusicRecognitionStage.listening);
    return _result.future;
  }

  void complete(MusicRecognitionResult result) => _result.complete(result);
}
