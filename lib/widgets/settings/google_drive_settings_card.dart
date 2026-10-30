import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/screens/settings/google_drive_playlists_screen.dart';
import 'package:resonance/screens/google_drive/drive_music_screen.dart';
import 'package:resonance/services/google_drive/drive_music_service.dart';
import 'package:resonance/services/google_drive/google_drive_models.dart';
import 'package:resonance/services/google_drive/google_drive_service.dart';

class GoogleDriveSettingsCard extends StatefulWidget {
  const GoogleDriveSettingsCard({super.key, this.service});
  final GoogleDriveService? service;
  @override
  State<GoogleDriveSettingsCard> createState() => _GoogleDriveSettingsCardState();
}

class _GoogleDriveSettingsCardState extends State<GoogleDriveSettingsCard> {
  late final service = widget.service ?? GoogleDriveService.instance;
  @override
  void initState() {
    super.initState();
    unawaited(_attempt(service.initialize));
  }

  Future<void> _attempt(Future<void> Function() action) async {
    try {
      await action();
    } on GoogleDriveCancelled {
      /* Closing Google sign-in leaves Settings intact. */
    } catch (_) {
      /* The service publishes a safe, localizable error below. */
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) {
      final account = service.account;
      final theme = Theme.of(context);
      return Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: resonanceBorderRadius(context, 12),
          side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (account != null) ...[
                Row(
                  children: [
                    GoogleDriveAvatar(account: account),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        account.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => _attempt(service.logout), child: Text(context.tr('Logout'))),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_queue_rounded),
                  title: Text(context.tr('Drive playlists')),
                  subtitle: const Text('ResonanceMusic'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(
                    context,
                  ).push<void>(MaterialPageRoute(builder: (_) => GoogleDrivePlaylistsScreen(service: service))),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.library_music_outlined),
                  title: Text(context.tr('Drive music')),
                  subtitle: Text(context.tr('Browse, play and upload audio files')),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => DriveMusicScreen(
                        service: identical(service, GoogleDriveService.instance)
                            ? null
                            : DriveMusicService(drive: service),
                      ),
                    ),
                  ),
                ),
                if (service.error != null)
                  TextButton.icon(
                    onPressed: service.busy ? null : () => _attempt(service.connect),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.tr('Reconnect Google Drive')),
                  ),
              ] else ...[
                Text(
                  context.tr('Sync or transfer playlists between your devices with Google Drive.'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: service.busy ? null : () => _attempt(service.connect),
                      icon: const Icon(Icons.add_to_drive_rounded, size: 18),
                      label: Text(context.tr(service.busy ? 'Connecting…' : 'Connect Google Drive')),
                    ),
                    if (service.busy)
                      TextButton(onPressed: () => _attempt(service.logout), child: Text(context.tr('Cancel'))),
                  ],
                ),
              ],
              if (service.busy) ...[const SizedBox(height: 8), const LinearProgressIndicator()],
              if (service.error case final error?) ...[
                const SizedBox(height: 8),
                Text(context.trRendered(error), style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class GoogleDriveAvatar extends StatelessWidget {
  const GoogleDriveAvatar({super.key, required this.account});
  final GoogleDriveAccount account;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 36,
    child: ClipOval(
      child: account.photoUrl == null
          ? const Icon(Icons.account_circle_outlined, size: 36)
          : Image.network(
              account.photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.account_circle_outlined, size: 36),
            ),
    ),
  );
}
