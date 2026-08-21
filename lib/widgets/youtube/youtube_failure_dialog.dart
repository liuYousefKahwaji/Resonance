import 'package:flutter/material.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';

Future<void> showYoutubeFailure(BuildContext context, Object error, {String? sourceUrl, String? actionLabel}) async {
  final service = YoutubeAccessService.active;
  final failure = error is YoutubeFailure
      ? error.withSourceUrl(sourceUrl)
      : YoutubeFailureClassifier.classify(error, authenticated: service?.isConfigured ?? false, sourceUrl: sourceUrl);
  service?.observeFailure(failure);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        failure.isAccessFailure ? 'YouTube verification required' : (actionLabel ?? 'YouTube request failed'),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              failure.kind == YoutubeFailureKind.sessionRejected
                  ? 'Your saved YouTube session was rejected or expired. Reconnect the browser session or replace cookies.txt, then retry.'
                  : failure.kind == YoutubeFailureKind.verificationRequired
                  ? 'YouTube blocked this request until a signed-in session is provided.'
                  : failure.userMessage,
            ),
            if (!failure.isAccessFailure && failure.technicalSummary.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Details'),
                children: [
                  SelectableText(
                    failure.technicalSummary,
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                    maxLines: 12,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(failure.isAccessFailure ? 'Not now' : 'Close'),
        ),
        if (failure.isAccessFailure)
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(builder: (_) => YoutubeAccessScreen(sourceUrl: failure.sourceUrl)),
              );
            },
            child: const Text('Open YouTube access'),
          ),
      ],
    ),
  );
}
