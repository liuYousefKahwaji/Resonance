import 'package:resonance/l10n/app_strings.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:resonance/services/verified_update_downloader.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:resonance/widgets/android_update_status.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/audio/audio_service.dart';

Future<void>? _activeUpdateFlow;
UpdateDownloadController? _activeDownload;
bool get isUpdatePromptActive => _activeUpdateFlow != null;

Future<void> showAppUpdatePrompt(BuildContext context, AvailableUpdate update) async {
  final previous = _activeUpdateFlow;
  if (previous != null) {
    if (_activeDownload?.isCancelled != true) return;
    await previous;
    if (!context.mounted) return;
    if (_activeUpdateFlow != null && !identical(_activeUpdateFlow, previous)) return;
  }
  final task = _showAppUpdatePrompt(context, update);
  _activeUpdateFlow = task;
  try {
    await task;
  } finally {
    if (identical(_activeUpdateFlow, task)) {
      _activeUpdateFlow = null;
      _activeDownload = null;
    }
  }
}

Future<void> _showAppUpdatePrompt(BuildContext context, AvailableUpdate update) async {
  final accept = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.tr("Resonance {0} is available", [update.version])),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr("Download: {0}", [formatUpdateBytes(update.asset.size)]),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (update.savedDownloadBytes > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      context.tr("{0}% smaller than the full {1} download.", [
                        update.downloadSavingsPercent,
                        formatUpdateBytes(update.fullDownloadBytes),
                      ]),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  Platform.isAndroid
                      ? context.tr(
                          "Downloads in the background. Android may ask you to approve installation. Follow progress in Settings.",
                        )
                      : context.tr(
                          "Resonance will close briefly and reopen after installation. Your library and settings are kept.",
                        ),
                ),
                if (update.delta != null)
                  Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      context.tr(
                        "If the smaller update cannot be applied, the full package will be downloaded instead.",
                      ),
                    ),
                  ),
                const Divider(height: 28),
                MarkdownBody(
                  data: update.notes.trim().isEmpty
                      ? context.tr('A new version is ready to install.')
                      : update.notes.trim(),
                  shrinkWrap: true,
                  selectable: true,
                  onTapLink: (_, href, __) {
                    final uri = href == null ? null : Uri.tryParse(href);
                    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
                      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr("Later"))),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(Platform.isAndroid ? context.tr("Download update") : context.tr("Update and restart")),
        ),
      ],
    ),
  );
  if (accept != true || !context.mounted) return;
  final controller = UpdateDownloadController();
  _activeDownload = controller;
  final progress = Platform.isWindows ? ValueNotifier(UpdateDownloadProgress(0, update.asset.size)) : null;
  var progressShown = false;
  if (Platform.isWindows) {
    progressShown = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(context.tr("Updating Resonance to {0}", [update.version])),
            content: SizedBox(
              width: 400,
              child: ValueListenableBuilder<UpdateDownloadProgress>(
                valueListenable: progress!,
                builder: (_, value, __) {
                  final fraction = value.total == 0 ? 0.0 : (value.received / value.total).clamp(0.0, 1.0);
                  final downloadedMb = (value.received / 1048576).toStringAsFixed(1);
                  final totalMb = (value.total / 1048576).toStringAsFixed(1);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value.message ??
                            (value.verifying
                                ? context.tr("Verifying the download…")
                                : context.tr("Downloading {0} of {1} MB", [downloadedMb, totalMb])),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: value.verifying ? null : fraction),
                      if (!value.verifying) ...[
                        const SizedBox(height: 8),
                        Text('${(fraction * 100).toStringAsFixed(0)}%'),
                      ],
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  progressShown = false;
                  controller.cancel();
                  Navigator.of(dialogContext).pop();
                },
                child: Text(context.tr("Cancel")),
              ),
            ],
          ),
        ),
      ).whenComplete(progress!.dispose),
    );
  }
  try {
    await AppUpdateService().install(
      update,
      onProgress: (value) {
        if (progressShown) progress?.value = value;
      },
      controller: controller,
      beforeRestart: () => context.read<PlayerHandler>().saveState(),
    );
    if (context.mounted && Platform.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr("Update is downloading in the background. Android will install it or ask for approval."),
          ),
        ),
      );
    }
  } on UpdateDownloadCancelled {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr("Download paused. Try again to resume."))));
    }
  } on PlatformException catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message ?? context.tr("Update could not start"))));
    }
  } catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr("Update could not start: {0}", [error]))));
    }
  }
}
