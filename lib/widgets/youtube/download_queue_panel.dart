import 'package:resonance/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:resonance/widgets/common/track_link_menu.dart';
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
            title: Text(
              active?.track.title ?? context.tr("{0} downloads waiting", [controller.pendingCount]),
              maxLines: 1,
            ),
            subtitle: active == null ? null : LinearProgressIndicator(value: (active.progress / 100).clamp(0, 1)),
            trailing: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
        );
      }
      return Column(
        children: [
          ListTile(
            title: Text(context.tr("Download queue")),
            subtitle: Text(context.tr("{0} remaining", [controller.pendingCount])),
            trailing: PopupMenuButton<String>(
              tooltip: context.tr('Queue options'),
              onSelected: (value) {
                if (value == 'all') {
                  controller.clearAll();
                } else {
                  controller.clearFinished();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'finished', child: Text(context.tr('Clear finished'))),
                PopupMenuItem(value: 'all', child: Text(context.tr('Cancel and clear queue'))),
              ],
            ),
          ),
          SwitchListTile.adaptive(
            dense: true,
            title: Text(context.tr('Queue downloads')),
            subtitle: Text(context.tr('Add downloads without waiting on the current page')),
            value: controller.queueMode,
            onChanged: controller.setQueueMode,
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(child: Text(context.tr("Queued downloads will appear here")))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final failed = entry.status == DownloadQueueStatus.failed;
                      final stopped = failed || entry.status == DownloadQueueStatus.cancelled;
                      final pending =
                          entry.status == DownloadQueueStatus.downloading || entry.status == DownloadQueueStatus.queued;
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
                            Text(
                              failed
                                  ? (entry.error ?? context.tr("Download failed"))
                                  : context.trRendered(entry.statusText),
                              maxLines: 2,
                            ),
                            if (entry.status == DownloadQueueStatus.downloading)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: LinearProgressIndicator(
                                  value: entry.progress > 0 ? (entry.progress / 100).clamp(0, 1) : null,
                                ),
                              ),
                          ],
                        ),
                        trailing: stopped
                            ? Wrap(
                                spacing: 2,
                                children: [
                                  TrackLinkMenu(trackId: entry.track.url),
                                  if (accessFailure)
                                    IconButton(
                                      tooltip: context.tr("Fix access"),
                                      icon: const Icon(Icons.verified_user_outlined),
                                      onPressed: () => Navigator.push<void>(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) => YoutubeAccessScreen(sourceUrl: entry.track.url),
                                        ),
                                      ),
                                    ),
                                  IconButton(
                                    tooltip: context.tr("Retry"),
                                    icon: const Icon(Icons.refresh_rounded),
                                    onPressed: () => controller.retry(entry.id),
                                  ),
                                ],
                              )
                            : pending
                            ? IconButton(
                                tooltip: context.tr('Cancel download'),
                                onPressed: () => controller.cancel(entry.id),
                                icon: const Icon(Icons.close_rounded),
                              )
                            : TrackLinkMenu(trackId: entry.track.url),
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
    DownloadQueueStatus.cancelled => const Icon(Icons.block_rounded),
    DownloadQueueStatus.failed => const Icon(Icons.error_rounded, color: Colors.redAccent),
  };
}

/// The root overlay makes the same queue reachable from every listening tab.
Future<void> showDownloadQueue(BuildContext context, {DownloadQueueController? controller}) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: DownloadQueuePanel(controller: controller ?? DownloadQueueController.instance),
      ),
    );
