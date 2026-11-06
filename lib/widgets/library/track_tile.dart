import 'package:resonance/widgets/library/cover_crop_dialog.dart';
import 'package:resonance/app/route_transitions.dart';
import 'package:resonance/services/track_artwork_service.dart';
import 'package:resonance/widgets/library/current_track_surface.dart';
import 'package:resonance/widgets/common/resonance_dialog.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/widgets/common/track_link_menu.dart';
import 'package:resonance/widgets/player/playback_range_dialog.dart';
import 'package:resonance/widgets/player/playback_range_indicator.dart';
// lib/widgets/library/track_tile.dart
//
// Scroll-smoothness fixes:
//  1. RepaintBoundary wraps each tile so a single tile redrawing during
//     playback state changes doesn't invalidate the whole list.
//  2. StreamBuilder is scoped to only listen to mediaItem — the narrowest
//     stream needed to check "is this tile currently playing".
//  3. AnimatedContainer transitions are kept but only trigger on isPlaying
//     changes — identical rebuilds from parent scrolls are cheap because
//     the decoration parameters don't change.
//  4. Skeleton loader uses const colours so Flutter doesn't allocate
//     new Color objects on every build cycle.
//  5. MetadataCacheService lookup is guarded so it doesn't trigger setState
//     if the widget was already disposed.

import 'dart:async';
import 'package:resonance/models/youtube_track.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/widgets/youtube/youtube_failure_dialog.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_metadata_extractor/audio_metadata_extractor.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/app/resonance_motion.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/screens/player/standalone_player_screen.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/youtube/stream_track_metadata_service.dart';
import 'package:resonance/widgets/common/artwork_thumbnail.dart';
import 'package:resonance/widgets/common/progressive_network_artwork.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:resonance/services/favorites_repository.dart';

class TrackTile extends StatefulWidget {
  final String trackPath;
  final int playlistNumber;
  final int index;
  final VoidCallback onDelete;
  final VoidCallback onDeleteEverywhere;
  final int pulse;
  final int artworkRevision;
  final bool selected;
  final bool selectionMode;
  final bool allowReorder;
  final VoidCallback? onSelectionToggle;
  @visibleForTesting
  final Future<CachedTrackMetadata?> Function(String path)? metadataLoader;

  const TrackTile({
    super.key,
    required this.trackPath,
    required this.playlistNumber,
    required this.index,
    required this.onDelete,
    required this.onDeleteEverywhere,
    this.pulse = 0,
    this.artworkRevision = 0,
    this.selected = false,
    this.selectionMode = false,
    this.allowReorder = true,
    this.onSelectionToggle,
    this.metadataLoader,
  });

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _title;
  String? _artist;
  Uint8List? _coverArt;
  String? _artworkUrl;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 850));
    _loadMetadata();
    _loadCoverArt();
  }

  @override
  void didUpdateWidget(covariant TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackPath != widget.trackPath) {
      if (mounted) {
        setState(() {
          _loading = true;
          _title = null;
          _artist = null;
          _coverArt = null;
          _artworkUrl = null;
        });
      }
      _loadMetadata();
      _loadCoverArt();
    }
    if (oldWidget.trackPath == widget.trackPath && oldWidget.artworkRevision != widget.artworkRevision) {
      _loadCoverArt(force: true);
    }
    if (widget.pulse != 0 && oldWidget.pulse != widget.pulse) {
      _pulseController.forward(from: 0);
    }
  }

  int _coverGeneration = 0;
  Future<void> _loadCoverArt({bool force = false}) async {
    final path = widget.trackPath;
    if (path.startsWith('http')) return;
    final generation = ++_coverGeneration;
    try {
      final uri = await const TrackArtworkService().resolve(path);
      final bytes = uri?.scheme == 'file' ? await File.fromUri(uri!).readAsBytes() : null;
      if (mounted && widget.trackPath == path && generation == _coverGeneration) {
        setState(() {
          _coverArt = bytes;
          _artworkUrl = uri?.scheme == 'https' || uri?.scheme == 'http' ? uri.toString() : null;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final path = widget.trackPath;
    final isStream = path.startsWith('http://') || path.startsWith('https://');
    final fileName = isStream ? path : p.basenameWithoutExtension(path);

    final cached = await (widget.metadataLoader?.call(path) ?? MetadataCacheService.get(path));
    if (!mounted || widget.trackPath != path) return;
    if (cached != null) {
      setState(() {
        _title = cached.title;
        _artist = cached.artist;
        _artworkUrl = cached.artworkUrl;
        _loading = false;
      });
      return;
    }

    if (isStream) {
      if (mounted) {
        setState(() {
          _title = 'Streaming Audio';
          _artist = 'YouTube';
          _loading = false;
        });
      }
      if (widget.metadataLoader == null) {
        final metadata = await StreamTrackMetadataService.instance.load(
          path,
          isCurrent: () => mounted && widget.trackPath == path,
        );
        if (metadata != null && mounted && widget.trackPath == path) {
          setState(() {
            _title = metadata.title;
            _artist = metadata.artist;
            _artworkUrl = metadata.artworkUrl;
          });
        }
      }
      return;
    }

    try {
      final metadata = await AudioMetadata.extract(File(path));
      if (!mounted || widget.trackPath != path) return;
      final title = (metadata?.trackName?.trim().isNotEmpty ?? false) ? metadata!.trackName! : fileName;
      final artist = (metadata?.firstArtists?.trim().isNotEmpty ?? false) ? metadata!.firstArtists! : 'Unknown Artist';

      unawaited(MetadataCacheService.set(path, title, artist));

      if (mounted && widget.trackPath == path) {
        setState(() {
          _title = title;
          _artist = artist;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && widget.trackPath == path) {
        setState(() {
          _title = fileName;
          _artist = 'Unknown Artist';
          _loading = false;
        });
      }
    }
  }

  void _showMetadataEditor(BuildContext context, String currentTitle, String currentArtist) async {
    final trackPath = widget.trackPath;
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final titleController = TextEditingController(text: currentTitle);
    final artistController = TextEditingController(text: currentArtist);
    Metadata? existingMetadata;
    Uint8List? coverBytes;
    String? coverMimeType;
    var coverRemoved = false;
    var coverEdited = false;
    var restoreOriginal = false;
    Uri? remoteCover;
    final canRestore = await const TrackArtworkService().hasOverride(trackPath);

    try {
      existingMetadata = await MetadataGod.readMetadata(file: trackPath);
    } catch (_) {}
    try {
      final uri = await const TrackArtworkService().resolve(trackPath);
      if (uri?.scheme == 'file') {
        coverBytes = await File.fromUri(uri!).readAsBytes();
        coverMimeType = _mimeTypeForImage('', coverBytes);
      } else {
        remoteCover = uri;
      }
    } catch (_) {}

    if (!context.mounted) {
      titleController.dispose();
      artistController.dispose();
      return;
    }

    ModalRoute<dynamic>? editorRoute;
    try {
      await showResonanceDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          editorRoute = ModalRoute.of(dialogContext);
          var saving = false;
          var coverBusy = false;
          String? saveError;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              Future<void> pickCover() async {
                final result = await FilePicker.pickFiles(type: FileType.image, withData: true);
                final file = result?.files.single;
                if (file == null) return;
                final bytes = file.bytes ?? (file.path == null ? null : await File(file.path!).readAsBytes());
                if (bytes == null || bytes.isEmpty) return;
                setDialogState(() {
                  coverBytes = Uint8List.fromList(bytes);
                  coverMimeType = _mimeTypeForImage(file.path ?? file.name, bytes);
                  coverRemoved = false;
                  restoreOriginal = false;
                  remoteCover = null;
                  coverEdited = true;
                });
              }

              Future<void> crop() async {
                final current = coverBytes;
                if (current == null) return;
                final cropped = await showCoverCropDialog(dialogContext, current);
                if (cropped == null || !dialogContext.mounted) return;
                setDialogState(() {
                  coverBytes = cropped;
                  coverMimeType = 'image/png';
                  coverEdited = true;
                  coverRemoved = false;
                  restoreOriginal = false;
                  remoteCover = null;
                });
              }

              Future<void> original() async {
                setDialogState(() => coverBusy = true);
                try {
                  final uri = await const TrackArtworkService().resolveOriginal(trackPath);
                  final bytes = uri?.scheme == 'file' ? await File.fromUri(uri!).readAsBytes() : null;
                  if (!dialogContext.mounted) return;
                  setDialogState(() {
                    coverBytes = bytes;
                    coverMimeType = bytes == null ? null : _mimeTypeForImage('', bytes);
                    remoteCover = bytes == null ? uri : null;
                    restoreOriginal = true;
                    coverRemoved = false;
                    coverEdited = true;
                    coverBusy = false;
                  });
                } catch (_) {
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      coverBusy = false;
                      saveError = 'Could not restore the original cover.';
                    });
                  }
                }
              }

              return PopScope(
                canPop: !saving && !coverBusy,
                child: ResonanceDialog(
                  title: Row(
                    children: [
                      Icon(Icons.edit_rounded, size: 18, color: Theme.of(dialogContext).colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(context.tr("Edit Metadata")),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: titleController,
                          decoration: InputDecoration(
                            labelText: context.tr("Title"),
                            prefixIcon: Icon(Icons.music_note_rounded, size: 18),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: artistController,
                          decoration: InputDecoration(
                            labelText: context.tr("Artist"),
                            prefixIcon: Icon(Icons.person_rounded, size: 18),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: ClipRRect(
                            borderRadius: resonanceBorderRadius(context, 10),
                            child: Container(
                              key: const Key('metadata-cover-preview'),
                              width: 176,
                              height: 176,
                              color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                              child: coverBytes != null
                                  ? Image.memory(coverBytes!, fit: BoxFit.contain)
                                  : remoteCover != null
                                  ? Image.network(
                                      remoteCover.toString(),
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, size: 40),
                                    )
                                  : const Icon(Icons.image_outlined, size: 40),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            OutlinedButton.icon(
                              onPressed: saving || coverBusy ? null : pickCover,
                              icon: const Icon(Icons.image_search_rounded, size: 18),
                              label: Text(
                                context.tr(coverBytes == null && remoteCover == null ? 'Choose cover' : 'Change cover'),
                              ),
                            ),
                            if (coverBytes != null)
                              OutlinedButton.icon(
                                onPressed: saving || coverBusy ? null : crop,
                                icon: const Icon(Icons.crop_rounded, size: 18),
                                label: Text(context.tr('Crop / zoom')),
                              ),
                            if (coverBytes != null || remoteCover != null)
                              TextButton.icon(
                                onPressed: saving || coverBusy
                                    ? null
                                    : () => setDialogState(() {
                                        coverBytes = null;
                                        coverMimeType = null;
                                        remoteCover = null;
                                        coverRemoved = true;
                                        coverEdited = true;
                                        restoreOriginal = false;
                                      }),
                                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                                label: Text(context.tr('Remove cover')),
                              ),
                            if (canRestore || coverEdited)
                              TextButton.icon(
                                onPressed: saving || coverBusy ? null : original,
                                icon: const Icon(Icons.restore_rounded, size: 18),
                                label: Text(context.tr('Restore original')),
                              ),
                          ],
                        ),
                        if (saveError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            saveError!,
                            key: const Key('metadata-save-error'),
                            style: TextStyle(color: Theme.of(dialogContext).colorScheme.error, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: saving || coverBusy ? null : () => Navigator.pop(dialogContext),
                      child: Text(context.tr("Cancel")),
                    ),
                    ElevatedButton(
                      onPressed: saving || coverBusy
                          ? null
                          : () async {
                              final title = titleController.text.trim();
                              final artist = artistController.text.trim();
                              // Null leaves pictures untouched in metadata_god; re-sending the
                              // old picture on text-only edits appends another embedded copy.
                              final picture = !coverEdited || restoreOriginal
                                  ? null
                                  : coverRemoved
                                  ? null
                                  : coverBytes == null
                                  ? existingMetadata?.picture
                                  : Picture(mimeType: coverMimeType ?? 'image/jpeg', data: coverBytes!);
                              setDialogState(() {
                                saving = true;
                                saveError = null;
                              });
                              try {
                                final updatedMetadata = _updatedMetadata(
                                  existingMetadata,
                                  title: title,
                                  artist: artist,
                                  picture: picture,
                                );
                                if (coverEdited) await const TrackArtworkService().rememberOriginal(trackPath);
                                try {
                                  await handler.withTrackFileReleased(
                                    trackPath,
                                    () => MetadataGod.writeMetadata(file: trackPath, metadata: updatedMetadata),
                                    updatedTitle: title,
                                    updatedArtist: artist,
                                  );
                                } catch (_) {
                                  // Original containers may not support tag writing. A cover-only
                                  // change still works in Resonance; never pretend text tags saved.
                                  if (!coverEdited || title != currentTitle || artist != currentArtist) rethrow;
                                }
                                await MetadataCacheService.set(trackPath, title, artist);
                                final updatedCover = coverRemoved ? null : coverBytes;
                                if (coverEdited) {
                                  if (restoreOriginal) {
                                    await const TrackArtworkService().restoreOriginal(trackPath);
                                  } else if (coverRemoved) {
                                    await const TrackArtworkService().embeddedChanged(trackPath, removed: true);
                                  } else {
                                    // A successful tag write does not prove replacement: the native
                                    // writer appends pictures while its reader returns the first one.
                                    // The user's exact choice must remain authoritative in Resonance.
                                    await const TrackArtworkService().saveCover(trackPath, coverBytes!);
                                  }
                                } else {
                                  TrackArtworkService.notifyChanged(trackPath);
                                }
                                if (mounted && widget.trackPath == trackPath) {
                                  setState(() {
                                    _title = title;
                                    _artist = artist;
                                    _coverArt = updatedCover;
                                    _artworkUrl = null;
                                  });
                                }
                                unawaited(_loadCoverArt(force: true));
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext);
                                }
                              } catch (error) {
                                if (dialogContext.mounted) {
                                  setDialogState(() {
                                    saving = false;
                                    saveError = 'Failed to update metadata: $error';
                                  });
                                }
                              }
                            },
                      child: saving
                          ? const SizedBox.square(
                              key: Key('metadata-save-progress'),
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.tr("Save")),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      // Popping completes the dialog Future before its exit animation unmounts
      // the TextFields. Keep their controllers alive until the route is gone.
      await editorRoute?.completed;
      titleController.dispose();
      artistController.dispose();
    }
  }

  Metadata _updatedMetadata(Metadata? existing, {required String title, required String artist, Picture? picture}) {
    return Metadata(
      title: title,
      durationMs: existing?.durationMs,
      artist: artist,
      album: existing?.album,
      albumArtist: existing?.albumArtist,
      trackNumber: existing?.trackNumber,
      trackTotal: existing?.trackTotal,
      discNumber: existing?.discNumber,
      discTotal: existing?.discTotal,
      year: existing?.year,
      genre: existing?.genre,
      picture: picture,
      fileSize: existing?.fileSize,
    );
  }

  String _mimeTypeForImage(String path, List<int> bytes) {
    final extension = p.extension(path).toLowerCase();
    if (extension == '.png' || (bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50)) {
      return 'image/png';
    }
    if (extension == '.webp' ||
        (bytes.length > 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45)) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  @override
  Widget build(BuildContext context) {
    final windowsNative = useWindowsNativeControls(context);
    final tileRadius = windowsNative ? 4.0 : 14.0;
    // RepaintBoundary: this tile can redraw (e.g. playing state) without
    // triggering repaints of neighbouring tiles in the list.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final wave = math.sin(_pulseController.value * math.pi);
          return Transform.scale(
            scale: 1 + wave * 0.012,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: resonanceBorderRadius(context, tileRadius, rounderRadius: windowsNative ? 11 : 23),
                boxShadow: [
                  if (wave > 0)
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: wave * 0.42),
                      blurRadius: 24 * wave,
                      spreadRadius: 2 * wave,
                    ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: _TrackTileContent(
          trackPath: widget.trackPath,
          playlistNumber: widget.playlistNumber,
          index: widget.index,
          onDelete: widget.onDelete,
          onDeleteEverywhere: widget.onDeleteEverywhere,
          loading: _loading,
          title: _title,
          artist: _artist,
          coverArt: _coverArt,
          artworkUrl: _artworkUrl,
          onEditMetadata: _showMetadataEditor,
          selected: widget.selected,
          selectionMode: widget.selectionMode,
          allowReorder: widget.allowReorder,
          onSelectionToggle: widget.onSelectionToggle,
        ),
      ),
    );
  }
}

@visibleForTesting
enum TrackTapAction { load, restart }

@visibleForTesting
TrackTapAction trackTapAction({required String? activeTrackPath, required String tappedTrackPath}) =>
    activeTrackPath == tappedTrackPath ? TrackTapAction.restart : TrackTapAction.load;

/// A track activates only after Flutter has accepted a completed tap.
///
/// Deliberately omitting [InkWell.onDoubleTap] removes its recognition timeout,
/// while allowing a scroll drag to defeat the tap in the gesture arena.
@visibleForTesting
class TrackTapRegion extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final BorderRadius borderRadius;
  final Widget child;
  final bool showHighlight;

  const TrackTapRegion({
    super.key,
    required this.onTap,
    required this.onLongPress,
    required this.borderRadius,
    required this.child,
    this.showHighlight = true,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    borderRadius: borderRadius,
    hoverColor: showHighlight ? null : Colors.transparent,
    focusColor: showHighlight ? null : Colors.transparent,
    highlightColor: showHighlight ? null : Colors.transparent,
    child: child,
  );
}

// Separated into its own widget so StreamBuilder rebuilds are contained
// inside it and don't touch the parent StatefulWidget's state.
class _TrackTileContent extends StatelessWidget {
  final String trackPath;
  final int playlistNumber;
  final int index;
  final VoidCallback onDelete;
  final VoidCallback onDeleteEverywhere;
  final bool loading;
  final String? title;
  final String? artist;
  final Uint8List? coverArt;
  final String? artworkUrl;
  final void Function(BuildContext, String, String) onEditMetadata;
  final bool selected;
  final bool selectionMode;
  final bool allowReorder;
  final VoidCallback? onSelectionToggle;

  const _TrackTileContent({
    required this.trackPath,
    required this.playlistNumber,
    required this.index,
    required this.onDelete,
    required this.onDeleteEverywhere,
    required this.loading,
    required this.title,
    required this.artist,
    required this.coverArt,
    required this.artworkUrl,
    required this.onEditMetadata,
    required this.selected,
    required this.selectionMode,
    required this.allowReorder,
    required this.onSelectionToggle,
  });

  Future<void> _openStandalone(
    BuildContext context,
    PlayerHandler handler,
    String resolvedTitle,
    String resolvedArtist,
  ) async {
    final ready = await handler.preparePlaylistTrackForStandalone(
      trackPath,
      resolvedTitle,
      resolvedArtist,
      playlistNumber: playlistNumber,
      playlistIndex: index,
    );
    if (!context.mounted || !ready) return;
    await Navigator.of(
      context,
    ).push(resonancePlayerRoute<void>(context, (_) => const StandalonePlayerScreen(playlistTrack: true)));
  }

  Future<void> _activateTrack(PlayerHandler handler, String resolvedTitle, String resolvedArtist) async {
    switch (trackTapAction(activeTrackPath: handler.playbackVisualNotifier.value.trackId, tappedTrackPath: trackPath)) {
      case TrackTapAction.restart:
        await handler.seek(Duration.zero);
        await handler.play();
        return;
      case TrackTapAction.load:
        await handler.loadTrack(trackPath, resolvedTitle, resolvedArtist);
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final handler = Provider.of<PlayerHandler>(context, listen: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final favorites = context.watch<FavoritesRepository?>();
    final isFavorite = favorites?.isFavorite(trackPath) ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    final windowsNative = useWindowsNativeControls(context);
    final modern = context.watch<ThemeProvider?>()?.modernLayout ?? false;
    final tileRadius = modern
        ? 8.0
        : windowsNative
        ? 4.0
        : 12.0;
    final fileName = p.basenameWithoutExtension(trackPath);
    final isStream = trackPath.startsWith('http://') || trackPath.startsWith('https://');

    if (loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: TrackTapRegion(
          onTap: selectionMode && onSelectionToggle != null ? onSelectionToggle! : () {},
          onLongPress: onSelectionToggle,
          borderRadius: resonanceBorderRadius(context, tileRadius, rounderRadius: windowsNative ? 11 : 23),
          child: _SkeletonTile(isDark: isDark),
        ),
      );
    }

    final resolvedTitle = title ?? fileName;
    final resolvedArtist = artist ?? 'Unknown Artist';

    return ValueListenableBuilder<PlaybackVisualState>(
      valueListenable: handler.playbackVisualNotifier,
      builder: (context, playback, _) {
        final isCurrentTrack = playback.trackId == trackPath;
        final isLoading = isCurrentTrack && playback.loading;
        final isPlaying = isCurrentTrack && playback.playing && !isLoading;

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: modern ? 20 : 12,
            vertical: modern
                ? 1
                : windowsNative
                ? 2
                : 3,
          ),
          child: CurrentTrackSurface(
            enabled: isCurrentTrack,
            duration: resonanceDuration(context, resonanceMotion(context).stateChange),
            curve: resonanceMotion(context).standardCurve,
            decoration: BoxDecoration(
              color: selected
                  ? primary.withValues(alpha: isDark ? 0.22 : 0.12)
                  : isCurrentTrack
                  ? (isDark ? primary.withValues(alpha: 0.12) : primary.withValues(alpha: 0.06))
                  : modern
                  ? Colors.transparent
                  : Theme.of(context).colorScheme.surface,
              borderRadius: resonanceBorderRadius(context, tileRadius, rounderRadius: windowsNative ? 11 : 23),
              border: modern
                  ? null
                  : Border.all(
                      color: selected || isCurrentTrack
                          ? primary.withValues(alpha: selected ? 0.75 : 0.45)
                          : Theme.of(context).colorScheme.outline,
                      width: selected || isCurrentTrack ? 1.5 : 1,
                    ),
              boxShadow: isCurrentTrack && !windowsNative && !modern
                  ? [
                      BoxShadow(
                        color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: TrackTapRegion(
                showHighlight: !isFavorite,
                onTap: selectionMode && onSelectionToggle != null
                    ? onSelectionToggle!
                    : () => unawaited(_activateTrack(handler, resolvedTitle, resolvedArtist)),
                onLongPress: onSelectionToggle,
                borderRadius: resonanceBorderRadius(context, tileRadius, rounderRadius: windowsNative ? 11 : 23),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: modern
                        ? 8
                        : windowsNative
                        ? 10
                        : 12,
                    vertical: modern
                        ? 8
                        : windowsNative
                        ? 8
                        : 10,
                  ),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: resonanceDuration(context, resonanceMotion(context).stateChange),
                        curve: resonanceMotion(context).standardCurve,
                        width: isCurrentTrack ? 3 : 0,
                        height: isCurrentTrack ? 32 : 0,
                        decoration: BoxDecoration(
                          color: isFavorite ? FavoritesRepository.gold : primary,
                          borderRadius: resonanceBorderRadius(context, 99),
                          boxShadow: isCurrentTrack
                              ? [
                                  BoxShadow(
                                    color: (isFavorite ? FavoritesRepository.gold : primary).withValues(alpha: .42),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      AnimatedContainer(
                        duration: resonanceDuration(context, resonanceMotion(context).stateChange),
                        width: isCurrentTrack ? 8 : 0,
                      ),
                      // ── Drag handle / shuffle cue ─────────────
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: selectionMode
                            ? Checkbox(
                                value: selected,
                                onChanged: onSelectionToggle == null ? null : (_) => onSelectionToggle!(),
                                visualDensity: VisualDensity.compact,
                              )
                            : !allowReorder
                            ? Icon(
                                isFavorite ? Icons.star_rounded : Icons.music_note_rounded,
                                size: 18,
                                color: isFavorite ? FavoritesRepository.gold : null,
                              )
                            : ReorderableDragStartListener(
                                index: index,
                                child: ValueListenableBuilder<int>(
                                  valueListenable: handler.playbackModeRevision,
                                  builder: (context, _, __) {
                                    final shuffle = handler.getShuffleMode();
                                    return AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 180),
                                      child: Icon(
                                        shuffle
                                            ? Icons.shuffle_rounded
                                            : isFavorite
                                            ? Icons.star_rounded
                                            : Icons.drag_handle_rounded,
                                        key: ValueKey((shuffle, isFavorite)),
                                        size: 18,
                                        color: isFavorite
                                            ? FavoritesRepository.gold
                                            : shuffle
                                            ? primary.withValues(alpha: isCurrentTrack ? 0.85 : 0.55)
                                            : isCurrentTrack
                                            ? primary.withValues(alpha: 0.5)
                                            : Theme.of(context).colorScheme.outline,
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),

                      // ── Icon ─────────────────────────────────
                      _TrackIcon(
                        isPlaying: isPlaying,
                        isStream: isStream,
                        isLoading: isLoading,
                        coverArt: coverArt,
                        artworkUrl: artworkUrl,
                        size: modern ? 42 : 34,
                      ),
                      const SizedBox(width: 12),

                      // ── Title + artist ────────────────────────
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    resolvedTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: isCurrentTrack ? FontWeight.w700 : FontWeight.w500,
                                      fontSize: modern ? 14 : 13,
                                      color: isCurrentTrack
                                          ? primary
                                          : (isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A)),
                                      letterSpacing: -0.1,
                                    ),
                                  ),
                                ),
                                if (!isStream)
                                  PlaybackRangeIndicator(handler: handler, path: trackPath, title: resolvedTitle),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              resolvedArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: modern ? 12 : 11,
                                color: modern
                                    ? Theme.of(context).colorScheme.onSurfaceVariant
                                    : const Color(0xFF64748B),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),

                      if (!selectionMode) ...[
                        MenuAnchor(
                          alignmentOffset: const Offset(-196, 4),
                          style: MenuStyle(
                            elevation: WidgetStatePropertyAll(windowsNative ? 8 : 10),
                            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
                            shape: WidgetStatePropertyAll(
                              RoundedRectangleBorder(
                                borderRadius: resonanceBorderRadius(context, windowsNative ? 4 : 14),
                                side: windowsNative
                                    ? BorderSide(color: Theme.of(context).colorScheme.outline)
                                    : BorderSide.none,
                              ),
                            ),
                            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: windowsNative ? 3 : 6)),
                          ),
                          menuChildren: [
                            if (modern)
                              MenuItemButton(
                                leadingIcon: const Icon(Icons.playlist_remove_rounded, size: 19),
                                onPressed: onDelete,
                                child: Text(context.tr('Remove from playlist')),
                              ),
                            TrackLinkMenuSection(trackId: trackPath),
                            if (favorites != null)
                              MenuItemButton(
                                leadingIcon: Icon(
                                  isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                                  size: 19,
                                  color: FavoritesRepository.gold,
                                ),
                                onPressed: () async {
                                  try {
                                    await favorites.toggle(trackPath);
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(context.tr("Could not change favorite: {0}", [error]))),
                                      );
                                    }
                                  }
                                },
                                child: Text(
                                  isFavorite ? context.tr("Remove from favorites") : context.tr("Add to favorites"),
                                ),
                              ),
                            MenuItemButton(
                              leadingIcon: const Icon(Icons.open_in_new_rounded, size: 19),
                              onPressed: () =>
                                  unawaited(_openStandalone(context, handler, resolvedTitle, resolvedArtist)),
                              child: Text(context.tr("Open standalone player")),
                            ),
                            if (isStream)
                              ListenableBuilder(
                                listenable: DownloadQueueController.instance,
                                builder: (_, __) {
                                  final queue = DownloadQueueController.instance;
                                  final pending = queue.pendingEntryFor(trackPath, playlistNumber);
                                  return MenuItemButton(
                                    leadingIcon: const Icon(Icons.download_rounded, size: 19),
                                    onPressed: pending != null
                                        ? null
                                        : () async {
                                            final messenger = ScaffoldMessenger.of(context);
                                            messenger.showSnackBar(
                                              SnackBar(content: Text(context.tr("Download queued"))),
                                            );
                                            try {
                                              await queue.enqueue(
                                                YoutubeTrack(
                                                  url: trackPath,
                                                  title: resolvedTitle,
                                                  artist: resolvedArtist,
                                                  thumbnailUrl: artworkUrl,
                                                ),
                                                playlistNumber,
                                                replaceStream: true,
                                              );
                                              messenger.showSnackBar(
                                                SnackBar(content: Text(context.tr("{0} downloaded", [resolvedTitle]))),
                                              );
                                            } catch (error) {
                                              if (context.mounted) {
                                                await showYoutubeFailure(
                                                  context,
                                                  error,
                                                  sourceUrl: trackPath,
                                                  actionLabel: context.tr("Download failed"),
                                                );
                                              }
                                            }
                                          },
                                    child: Text(
                                      pending == null
                                          ? context.tr("Download")
                                          : '${pending.statusText} ${pending.progress.round()}%',
                                    ),
                                  );
                                },
                              ),
                            if (!isStream)
                              MenuItemButton(
                                leadingIcon: const Icon(Icons.content_cut_rounded, size: 19),
                                onPressed: () => showPlaybackRangeDialog(context, handler, trackPath, resolvedTitle),
                                child: Text(context.tr('Trim playback')),
                              ),
                            if (!isStream)
                              MenuItemButton(
                                leadingIcon: const Icon(Icons.edit_rounded, size: 19),
                                onPressed: () => onEditMetadata(context, resolvedTitle, resolvedArtist),
                                child: Text(context.tr("Edit metadata")),
                              ),
                            if (!isStream)
                              MenuItemButton(
                                style: ButtonStyle(
                                  foregroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.error),
                                ),
                                leadingIcon: const Icon(Icons.delete_forever_rounded, size: 19),
                                onPressed: onDeleteEverywhere,
                                child: Text(context.tr("Delete file everywhere")),
                              ),
                          ],
                          builder: (context, controller, _) => IconButton(
                            tooltip: context.tr("Track actions"),
                            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                            icon: Icon(
                              Icons.more_vert_rounded,
                              size: 18,
                              color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                        if (!modern)
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 16),
                            tooltip: context.tr("Remove from playlist"),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                            onPressed: onDelete,
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Skeleton loader with const colors.
class _SkeletonTile extends StatelessWidget {
  final bool isDark;
  const _SkeletonTile({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final windowsNative = useWindowsNativeControls(context);
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: resonanceBorderRadius(context, windowsNative ? 4 : 12, rounderRadius: windowsNative ? 11 : 23),
        border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: resonanceBorderRadius(context, 8),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 12,
                  width: 140,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: resonanceBorderRadius(context, 4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 80,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: resonanceBorderRadius(context, 4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Track icon — shows a loading spinner for streams that are buffering,
/// a waveform for playing, or a music/sensor icon otherwise.
class _TrackIcon extends StatelessWidget {
  final double size;
  final bool isPlaying;
  final bool isStream;
  final bool isLoading;
  final Uint8List? coverArt;
  final String? artworkUrl;

  const _TrackIcon({
    this.size = 34,
    required this.isPlaying,
    this.isStream = false,
    this.isLoading = false,
    this.coverArt,
    this.artworkUrl,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final isActive = isPlaying || isLoading;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isActive
            ? primary.withValues(alpha: isDark ? 0.2 : 0.12)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: resonanceBorderRadius(context, 8),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: isLoading
            ? Padding(
                key: const ValueKey('loading'),
                padding: const EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2, color: primary),
              )
            : coverArt != null
            ? ArtworkThumbnail(
                key: ValueKey('cover-${coverArt!.length}'),
                bytes: coverArt!,
                size: size,
                borderRadius: 6,
              )
            : artworkUrl != null
            ? isStream
                  ? _StreamArtworkThumbnail(url: artworkUrl!)
                  : ClipRRect(
                      borderRadius: resonanceBorderRadius(context, 6),
                      child: ProgressiveNetworkArtwork(
                        url: artworkUrl!,
                        fit: BoxFit.cover,
                        fallback: const Icon(Icons.music_note_rounded),
                      ),
                    )
            : Icon(
                isPlaying ? Icons.graphic_eq_rounded : (isStream ? Icons.sensors_rounded : Icons.music_note_rounded),
                key: ValueKey(
                  isPlaying
                      ? 'playing'
                      : isStream
                      ? 'stream'
                      : 'local',
                ),
                size: 17,
                color: isPlaying ? primary : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
              ),
      ),
    );
  }
}

class _StreamArtworkThumbnail extends StatelessWidget {
  final String url;

  const _StreamArtworkThumbnail({required this.url});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: resonanceBorderRadius(context, 8),
    child: Stack(
      fit: StackFit.expand,
      children: [
        ProgressiveNetworkArtwork(
          url: url,
          fit: BoxFit.cover,
          lowCacheSize: 102,
          highCacheSize: 384,
          fallback: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.sensors_rounded, size: 17),
          ),
        ),
        PositionedDirectional(
          end: 2,
          bottom: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
              borderRadius: resonanceBorderRadius(context, 4),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.cloud_rounded, size: 9, color: Theme.of(context).colorScheme.primary),
            ),
          ),
        ),
      ],
    ),
  );
}
