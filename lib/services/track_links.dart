import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/services/track_source_repository.dart';
import 'package:resonance/services/google_drive/drive_music_models.dart';

class TrackLinks {
  const TrackLinks(this.source, {this.youtubeId});
  final Uri source;
  final String? youtubeId;
  Uri? get youtubeMusic => youtubeId == null ? null : Uri.https('music.youtube.com', '/watch', {'v': youtubeId!});

  static TrackLinks? direct(String track) {
    final id = TrackSourceRepository.videoIdFromUrlOrId(track);
    if (id != null) return TrackLinks(Uri.parse(TrackSourceRepository.canonicalUrlFor(id)), youtubeId: id);
    final drive = DriveMusicRef.parse(track);
    if (drive != null) return TrackLinks(Uri.https('drive.google.com', '/file/d/${drive.fileId}/view'));
    return null;
  }

  static Future<TrackLinks?> resolve(
    String track, {
    TrackSourceRepository repository = const TrackSourceRepository(),
  }) async {
    final known = direct(track);
    if (known != null) return known;
    // Never copy CDN URLs, credentials or a guessed title-search match.
    final uri = Uri.tryParse(track);
    if (uri?.hasScheme == true && uri!.scheme != 'file' && !RegExp(r'^[A-Za-z]:').hasMatch(track)) return null;
    final source = await repository.getSourceForTrack(track);
    return source == null ? null : direct(source.youtubeVideoId);
  }

  Future<void> perform(BuildContext context, String action) async {
    try {
      if (action == 'copy-link') {
        await Clipboard.setData(ClipboardData(text: source.toString()));
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.tr('Link copied'))));
        }
      } else {
        final uri = action == 'open-ytmusic' ? youtubeMusic : source;
        if (uri != null && !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('Browser unavailable');
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(context.tr('Could not open or copy this link'))));
      }
    }
  }
}
