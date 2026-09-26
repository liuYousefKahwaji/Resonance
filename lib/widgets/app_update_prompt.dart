import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:resonance/services/app_update_service.dart';
import 'package:resonance/services/verified_update_downloader.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showAppUpdatePrompt(BuildContext context, AvailableUpdate update) async {
  final accept = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Resonance ${update.version} is available'),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
          child: SingleChildScrollView(
            child: MarkdownBody(
              data: update.notes.trim().isEmpty ? 'A new version is ready to install.' : update.notes.trim(),
              shrinkWrap: true,
              selectable: true,
              onTapLink: (_, href, __) {
                final uri = href == null ? null : Uri.tryParse(href);
                if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
                  unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
                }
              },
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(Platform.isAndroid ? 'Download update' : 'Update and restart'),
        ),
      ],
    ),
  );
  if (accept != true || !context.mounted) return;
  final controller = UpdateDownloadController();
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
            title: Text('Updating Resonance to ${update.version}'),
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
                      Text(value.verifying ? 'Verifying the download…' : 'Downloading $downloadedMb of $totalMb MB'),
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
                child: const Text('Cancel'),
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
    );
    if (context.mounted && Platform.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Update is downloading in the background. Android will install it or ask for approval.'),
        ),
      );
    }
  } on UpdateDownloadCancelled {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Download paused. Try again to resume.')));
    }
  } on PlatformException catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message ?? 'Update could not start')));
    }
  } catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progressShown = false;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update could not start: $error')));
    }
  }
}
