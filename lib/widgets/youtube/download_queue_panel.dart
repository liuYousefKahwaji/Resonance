import 'package:flutter/material.dart';
import 'package:resonance/models/download_queue_entry.dart';
import 'package:resonance/services/download/download_queue_controller.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';

class DownloadQueuePanel extends StatelessWidget {
  final DownloadQueueController controller;
  final bool compact;

  const DownloadQueuePanel({super.key, required this.controller, this.compact = false});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final entries = controller.entries;
      if (compact) {
        final active = entries.where((entry) => entry.status == DownloadQueueStatus.downloading).firstOrNull;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: ListTile(
            dense: true,
            leading: Icon(active == null ? Icons.download_done_rounded : Icons.downloading_rounded),
            title: Text(active?.track.title ?? '${controller.pendingCount} downloads waiting', maxLines: 1),
            subtitle: active == null ? null : LinearProgressIndicator(value: (active.progress / 100).clamp(0, 1)),
            trailing: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
        );
      }
      return Column(
        children: [
          ListTile(
            title: const Text('Download queue'),
            subtitle: Text('${controller.pendingCount} remaining'),
            trailing: TextButton(onPressed: controller.clearFinished, child: const Text('Clear finished')),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('Queued downloads will appear here'))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final failed = entry.status == DownloadQueueStatus.failed;
                      final accessFailure =
                          entry.failureKind == YoutubeFailureKind.verificationRequired ||
                          entry.failureKind == YoutubeFailureKind.sessionRejected ||
                          entry.failureKind == YoutubeFailureKind.browserProfileMissing ||
                          entry.failureKind == YoutubeFailureKind.browserCookiesLocked ||
                          entry.failureKind == YoutubeFailureKind.browserDecryptionFailed;
                      return ListTile(
                        leading: _statusIcon(entry.status),
                        title: Text(entry.track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(failed ? (entry.error ?? 'Download failed') : entry.statusText, maxLines: 2),
                            if (entry.status == DownloadQueueStatus.downloading)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: LinearProgressIndicator(value: (entry.progress / 100).clamp(0, 1)),
                              ),
                          ],
                        ),
                        trailing: failed
                            ? Wrap(
                                spacing: 2,
                                children: [
                                  if (accessFailure)
                                    IconButton(
                                      tooltip: 'Fix access',
                                      icon: const Icon(Icons.verified_user_outlined),
                                      onPressed: () => Navigator.push<void>(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) => YoutubeAccessScreen(sourceUrl: entry.track.url),
                                        ),
                                      ),
                                    ),
                                  IconButton(
                                    tooltip: 'Retry',
                                    icon: const Icon(Icons.refresh_rounded),
                                    onPressed: () => controller.retry(entry.id),
                                  ),
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );

  Widget _statusIcon(DownloadQueueStatus status) => switch (status) {
    DownloadQueueStatus.queued => const Icon(Icons.schedule_rounded),
    DownloadQueueStatus.downloading => const SizedBox.square(
      dimension: 22,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    ),
    DownloadQueueStatus.completed => const Icon(Icons.check_circle_rounded, color: Colors.green),
    DownloadQueueStatus.failed => const Icon(Icons.error_rounded, color: Colors.redAccent),
  };
}
