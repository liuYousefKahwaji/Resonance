import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resonance/services/app_update_service.dart';

Future<void> showAppUpdatePrompt(BuildContext context, AvailableUpdate update) async {
  final accept = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Resonance ${update.version} is available'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: SelectableText(
            update.notes.trim().isEmpty ? 'A new version is ready to install.' : update.notes.trim(),
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
  var progressShown = false;
  if (Platform.isWindows) {
    progressShown = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Downloading and verifying the update…')),
            ],
          ),
        ),
      ),
    );
  }
  try {
    await AppUpdateService().install(update);
    if (context.mounted && Platform.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Update is downloading in the background. Android will install it or ask for approval.'),
        ),
      );
    }
  } on PlatformException catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message ?? 'Update could not start')));
    }
  } catch (error) {
    if (progressShown && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update could not start: $error')));
    }
  }
}
