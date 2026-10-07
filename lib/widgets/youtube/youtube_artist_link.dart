import 'package:flutter/material.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/screens/youtube/youtube_artist_screen.dart';

/// Keeps the existing artist typography; only the name is a separate tap target.
class YoutubeArtistLink extends StatelessWidget {
  const YoutubeArtistLink({
    super.key,
    required this.track,
    required this.child,
    this.returnToPlayer = false,
    this.onTap,
  });
  final YoutubeTrack track;
  final Widget child;
  final bool returnToPlayer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (track.videoId == null && !RegExp(r'^UC[A-Za-z0-9_-]{22}$').hasMatch(track.artistId ?? '') ||
        track.artist.trim().isEmpty ||
        {'Unknown', 'Loading details…', 'YouTube'}.contains(track.artist)) {
      return child;
    }
    return Semantics(
      button: true,
      label: context.tr('View artist {0}', [track.artist]),
      child: Tooltip(
        message: context.tr('View artist'),
        child: InkWell(
          onTap: onTap ?? () => openYoutubeArtist(context, track, returnToPlayer: returnToPlayer),
          borderRadius: BorderRadius.circular(4),
          mouseCursor: SystemMouseCursors.click,
          child: child,
        ),
      ),
    );
  }
}
