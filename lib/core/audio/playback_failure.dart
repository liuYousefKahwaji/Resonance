import 'package:audio_service/audio_service.dart';

class PlaybackFailure {
  const PlaybackFailure({
    required this.generation,
    required this.track,
    required this.error,
    this.position = Duration.zero,
  });
  final int generation;
  final MediaItem track;
  final Object error;
  final Duration position;
}
