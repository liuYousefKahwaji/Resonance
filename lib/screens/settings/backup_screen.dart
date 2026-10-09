import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';
import 'package:resonance/core/storage/file_service.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/providers/language_provider.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/services/backup_service.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/services/listening_history_repository.dart';
import 'package:resonance/services/listening_statistics.dart';
import 'package:resonance/services/metadata_cache_service.dart';
import 'package:resonance/services/playlist_offline_service.dart';
import 'package:resonance/services/portable_file_export.dart';
import 'package:resonance/screens/library/library_browser_screen.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final service = BackupService();
  BackupMode mode = BackupMode.settings;
  bool audio = false, busy = false;
  String status = '';
  Future<void> _export() async {
    setState(() {
      busy = true;
      status = context.tr('Preparing backup…');
    });
    File? temporary;
    try {
      await context.read<PlayerHandler>().saveState();
      await ListeningStatistics.instance.flush();
      await MetadataCacheService.flush();
      final preview = await service.previewExport(mode, includeAudio: audio && mode == BackupMode.everything);
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.tr('Export backup')),
          content: _preview(preview),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Export'))),
          ],
        ),
      );
      if (approved != true) return;
      temporary = File(
        p.join((await getTemporaryDirectory()).path, 'resonance-backup-${DateTime.now().microsecondsSinceEpoch}.zip'),
      );
      await service.export(
        temporary.path,
        preview,
        onProgress: (done, total) {
          if (mounted) setState(() => status = context.tr('Packing audio: {0}/{1}', [done, total]));
        },
      );
      if (mounted) setState(() => status = context.tr('Choose where to save the backup'));
      final saved = await savePortableFile(
        temporary.path,
        name: 'Resonance-${mode.name}-${DateTime.now().toIso8601String().split('T').first}.zip',
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('Backup saved'))));
      }
    } catch (error) {
      if (mounted) showLibraryError(context, error);
    } finally {
      if (temporary != null && await temporary.exists()) await temporary.delete();
      if (mounted) {
        setState(() {
          busy = false;
          status = '';
        });
      }
    }
  }

  Widget _preview(BackupPreview preview) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        context.tr('{0} settings · {1} playlists · {2} audio files', [
          (preview.manifest['settings'] as Map).length,
          preview.playlistCount,
          preview.audioCount,
        ]),
      ),
      const SizedBox(height: 10),
      Text(context.tr('Estimated size: {0} MB', [(preview.bytes / (1024 * 1024)).toStringAsFixed(1)])),
      if (preview.unresolved > 0) ...[
        const SizedBox(height: 10),
        Text(
          context.tr('{0} local files are references only. Keep their files or relink them after restoring.', [
            preview.unresolved,
          ]),
        ),
      ],
      const SizedBox(height: 10),
      Text(
        context.tr('YouTube sessions and companion pairing are excluded. Reconnect them on the destination device.'),
      ),
      if (preview.manifest['platform'] != Platform.operatingSystem) ...[
        const SizedBox(height: 10),
        Text(context.tr('Settings specific to another platform will be skipped.')),
      ],
    ],
  );
  Future<void> _restore() async {
    if (DownloadQueueController.instance.isWorking ||
        PlaylistOfflineService.instance.progress.values.any((state) => state.running)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('Finish or stop downloads before restoring a backup.'))));
      return;
    }
    final selection = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final source = selection?.files.single.path;
    if (source == null || !mounted) return;
    setState(() {
      busy = true;
      status = context.tr('Checking backup…');
    });
    try {
      final preview = service.inspect(source);
      var replace = false;
      String? relink;
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(context.tr('Restore backup')),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _preview(preview),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.tr('Replace existing data')),
                      subtitle: Text(
                        context.tr(
                          replace
                              ? 'Existing playlists and backed-up settings will be replaced.'
                              : 'Merge library data and apply backed-up settings.',
                        ),
                      ),
                      value: replace,
                      onChanged: (value) => update(() => replace = value),
                    ),
                    if (preview.unresolved > 0)
                      TextButton.icon(
                        onPressed: () async {
                          final folder = await FilePicker.getDirectoryPath();
                          if (context.mounted) update(() => relink = folder);
                        },
                        icon: const Icon(Icons.folder_open),
                        label: Text(relink ?? context.tr('Choose folder to relink missing files')),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Restore'))),
            ],
          ),
        ),
      );
      if (approved != true || !mounted) return;
      final handler = context.read<PlayerHandler>();
      final theme = context.read<ThemeProvider>();
      final language = context.read<LanguageProvider>();
      await handler.pause();
      await handler.saveState();
      await MetadataCacheService.flush();
      if (mounted) setState(() => status = context.tr('Restoring backup…'));
      await service.restore(source, replace: replace, relinkFolder: relink);
      await MetadataCacheService.reloadAfterRestore();
      await ListeningHistoryRepository.instance.initialize();
      await ListeningStatistics.instance.initialize();
      await handler.reloadPortablePreferences();
      await theme.reloadPortablePreferences();
      await language.initialize();
      // One final mutation lets the existing main library refresh after the transaction.
      await FileService().notifyLibraryRestored();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('Backup restored. Restart to apply desktop integrations.'))));
      }
    } catch (error) {
      if (mounted) showLibraryError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          status = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: Text(context.tr('Backup and restore'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            context.tr('Keep a portable copy of your Resonance settings and library.'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<BackupMode>(
            isExpanded: true,
            initialValue: mode,
            items: [
              DropdownMenuItem(value: BackupMode.settings, child: Text(context.tr('Settings only'))),
              DropdownMenuItem(value: BackupMode.everything, child: Text(context.tr('Complete backup'))),
            ],
            onChanged: busy ? null : (value) => setState(() => mode = value!),
          ),
          if (mode == BackupMode.everything)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('Include local audio files')),
              subtitle: Text(context.tr('Without audio, local tracks keep their file references.')),
              value: audio,
              onChanged: busy ? null : (value) => setState(() => audio = value!),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : _export,
            icon: const Icon(Icons.file_upload_outlined),
            label: Text(context.tr('Export backup')),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy ? null : _restore,
            icon: const Icon(Icons.restore),
            label: Text(context.tr('Import / restore')),
          ),
          if (busy) ...[
            const SizedBox(height: 22),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(status),
          ],
        ],
      ),
    ),
  );
}
