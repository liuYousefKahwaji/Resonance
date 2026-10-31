import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/youtube/youtube_request.dart';

void main() {
  test('a cancelled network request settles promptly and absorbs its late failure', () async {
    final network = Completer<String>();
    final request = YoutubeRequest();
    final result = request.follow(network.future);
    final cancelled = expectLater(result, throwsA(isA<YoutubeRequestCancelled>()));
    request.cancel();
    await cancelled.timeout(const Duration(milliseconds: 100));
    network.completeError(StateError('late offline response'));
    await Future<void>.delayed(Duration.zero);
  });
}
