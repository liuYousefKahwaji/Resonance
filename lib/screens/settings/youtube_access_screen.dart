import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/windows_browser_detector.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:url_launcher/url_launcher.dart';

class YoutubeAccessScreen extends StatefulWidget {
  const YoutubeAccessScreen({super.key, this.sourceUrl, this.windows, this.android, this.browserDetector});

  final String? sourceUrl;
  final bool? windows;
  final bool? android;
  final WindowsBrowserDetector? browserDetector;

  @override
  State<YoutubeAccessScreen> createState() => _YoutubeAccessScreenState();
}

class _YoutubeAccessScreenState extends State<YoutubeAccessScreen> {
  bool _busy = false;
  bool _showGuide = true;
  bool _firefoxInstalled = false;
  String? _screenMessage;
  String? _screenDetails;

  bool get _isWindows => widget.windows ?? Platform.isWindows;
  bool get _isAndroid => widget.android ?? Platform.isAndroid;
  WindowsBrowserDetector get _detector => widget.browserDetector ?? const WindowsBrowserDetector();

  @override
  void initState() {
    super.initState();
    if (_isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final installed = await context.read<YoutubeAccessService>().androidBackend.isFirefoxInstalled();
        if (mounted) setState(() => _firefoxInstalled = installed);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<YoutubeAccessService>();
    final content = <Widget>[
      _StatusCard(status: service.status),
      const SizedBox(height: 12),
      const _SafetyCard(),
      if (_screenMessage != null) ...[
        const SizedBox(height: 12),
        _MessageCard(message: _screenMessage!, details: _screenDetails),
      ],
      const SizedBox(height: 16),
      if (_isWindows) _buildWindows(service) else if (_isAndroid) _buildAndroid(service),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('YouTube access')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _isWindows ? 720 : double.infinity),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), children: content),
          ),
        ),
      ),
    );
  }

  Widget _buildWindows(YoutubeAccessService service) {
    if (service.isConfigured) {
      return _AccessCard(
        title: 'Browser session',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'yt-dlp reads ${YoutubeAccessService.browserDisplayName(service.windowsBrowserId)} cookies locally when Resonance uses YouTube. '
              'Resonance does not save a Windows cookie file or your Google password.',
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _run(() => service.testCurrent(sourceUrl: widget.sourceUrl)),
                  icon: const Icon(Icons.verified_rounded),
                  label: const Text('Test access'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _connect(service, service.windowsBrowserId),
                  child: const Text('Reconnect'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _chooseAndConnect(service),
                  child: const Text('Choose another browser'),
                ),
                TextButton(onPressed: _busy ? null : () => _confirmClear(service), child: const Text('Disconnect')),
              ],
            ),
          ],
        ),
      );
    }
    return _AccessCard(
      title: 'Connect your browser',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Open YouTube, sign in or complete its verification page, then let Resonance test the current browser session.',
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : () => _connect(service, null),
            icon: const Icon(Icons.open_in_browser_rounded),
            label: const Text('Connect browser session'),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroid(YoutubeAccessService service) {
    if (service.isConfigured && !_showGuide) {
      return _AccessCard(
        title: 'Imported cookies.txt',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Delete the original cookies.txt from Downloads. Treat it like a password.'),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _run(() => service.testCurrent(sourceUrl: widget.sourceUrl)),
                  child: const Text('Test access'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _importCookies(service),
                  child: const Text('Replace cookies'),
                ),
                OutlinedButton(onPressed: () => setState(() => _showGuide = true), child: const Text('Show guide')),
                TextButton(onPressed: _busy ? null : () => _confirmClear(service), child: const Text('Clear cookies')),
              ],
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        _TutorialCard(
          number: 1,
          title: 'Install Firefox',
          body:
              'Install Firefox for Android. Resonance uses Firefox because it can export a YouTube session as the cookie file yt-dlp understands.',
          actions: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _openAndroidUrl(
                      _firefoxInstalled
                          ? 'https://support.mozilla.org/en-US/products/mobile'
                          : 'https://play.google.com/store/apps/details?id=org.mozilla.firefox',
                    ),
              child: Text(_firefoxInstalled ? 'Open Firefox' : 'Install Firefox'),
            ),
          ],
        ),
        _TutorialCard(
          number: 2,
          title: 'Keep YouTube inside Firefox',
          body:
              'In Firefox, open ⋮ → Settings → Advanced → Open links in apps, then choose Never. '
              'This stops YouTube links from jumping into the YouTube app while you sign in.\n\n'
              'If links still jump away, open “Open by default” in YouTube app settings and turn off supported-link opening.',
          actions: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _openAndroidUrl(
                      'https://support.mozilla.org/en-US/kb/set-firefox-android-open-links-native-apps',
                    ),
              child: const Text('View Firefox instructions'),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await context.read<YoutubeAccessService>().androidBackend.openYoutubeAppSettings();
                    }),
              child: const Text('YouTube app settings'),
            ),
          ],
        ),
        _TutorialCard(
          number: 3,
          title: 'Install cookies.txt',
          body:
              'Install the “cookies.txt” add-on by Lennon Hill from Mozilla Add-ons. During installation, allow it in private browsing. '
              'This is a third-party add-on and requests access to site data, tabs, downloads, and the clipboard.',
          actions: [
            OutlinedButton(
              key: const Key('youtube-cookies-addon-link'),
              onPressed: _busy
                  ? null
                  : () => _openAndroidUrl('https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/'),
              child: const Text('Open cookies.txt add-on'),
            ),
          ],
        ),
        _TutorialCard(
          number: 4,
          title: 'Create a durable YouTube session',
          body:
              'Open one new private Firefox tab and sign in at youtube.com. Confirm your profile avatar/account menu is visible before continuing. '
              'In that same tab, open youtube.com/robots.txt and reload it once. '
              'Keep it as the only private tab. If the add-on is absent: Firefox ⋮ → Extensions → cookies.txt → Run in private browsing → On.',
          actions: [
            OutlinedButton(
              key: const Key('youtube-open-firefox'),
              onPressed: _busy ? null : () => _openAndroidUrl('https://www.youtube.com/'),
              child: const Text('Open YouTube in Firefox'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => _openAndroidUrl('https://www.youtube.com/robots.txt'),
              child: const Text('Open robots.txt in Firefox'),
            ),
          ],
        ),
        const _TutorialCard(
          number: 5,
          title: 'Export only YouTube cookies',
          body:
              'While robots.txt is open, open cookies.txt and choose Current Site → Download. Do not choose ALL. '
              'Then close every private Firefox tab and do not reopen that session.',
        ),
        _TutorialCard(
          number: 6,
          title: 'Import into Resonance',
          body:
              'Import the downloaded .txt file. Resonance verifies that it contains a signed-in YouTube session, keeps an app-private copy, and tests it without downloading audio.',
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _importCookies(service),
              icon: const Icon(Icons.file_open_rounded),
              label: Text(service.isConfigured ? 'Replace cookies.txt' : 'Import cookies.txt'),
            ),
            if (service.isConfigured)
              TextButton(onPressed: () => setState(() => _showGuide = false), child: const Text('Hide guide')),
          ],
        ),
      ],
    );
  }

  Future<void> _connect(YoutubeAccessService service, String? browserId) async {
    if (!await _ensureWarning(service)) return;
    var selected = browserId ?? await _detector.detectDefaultBrowser();
    if (selected == null && mounted) selected = await _pickBrowser();
    if (selected == null || !mounted) return;
    var launched = await _detector.launchBrowser(selected, 'https://www.youtube.com/');
    launched = launched || await launchUrl(Uri.parse('https://www.youtube.com/'), mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      setState(
        () => _screenMessage =
            'Could not open YouTube. Open youtube.com in ${YoutubeAccessService.browserDisplayName(selected)} manually.',
      );
    }
    if (!mounted) return;
    final test = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finish in your browser'),
        content: Text(
          'Sign in to YouTube or complete any verification page in ${YoutubeAccessService.browserDisplayName(selected)}. '
          'Return when YouTube opens normally. If extraction says the cookie database is locked, close all browser windows first.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("I'm signed in — test access"),
          ),
        ],
      ),
    );
    if (test == true) await _run(() => service.connectWindowsBrowser(selected!, sourceUrl: widget.sourceUrl));
  }

  Future<void> _chooseAndConnect(YoutubeAccessService service) async {
    final browser = await _pickBrowser();
    if (browser != null) await _connect(service, browser);
  }

  Future<String?> _pickBrowser() => showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Choose the browser where you are signed in to YouTube'),
      children: [
        for (final browser in WindowsBrowserDetector.supported)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, browser.id),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(browser.name)),
          ),
      ],
    ),
  );

  Future<void> _importCookies(YoutubeAccessService service) async {
    if (!await _ensureWarning(service)) return;
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose cookies.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null) return;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) bytes = await File(file.path!).readAsBytes();
    if (bytes == null) {
      setState(() => _screenMessage = 'Resonance could not read the selected file.');
      return;
    }
    await _run(() async {
      await service.importAndroidCookies(bytes!, sourceUrl: widget.sourceUrl);
      if (mounted) setState(() => _showGuide = false);
    });
  }

  Future<bool> _ensureWarning(YoutubeAccessService service) async {
    if (service.warningAcknowledged) return true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Account safety'),
        content: const Text(
          'This uses a signed-in YouTube session. Automated requests can cause YouTube to temporarily restrict or permanently disable an account. '
          'Use it only when verification is required, avoid large batches, and consider a separate account.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('I understand')),
        ],
      ),
    );
    if (accepted == true) await service.acknowledgeWarning();
    return accepted == true;
  }

  Future<void> _confirmClear(YoutubeAccessService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isWindows ? 'Disconnect browser session?' : 'Clear imported cookies?'),
        content: const Text('YouTube requests will return to anonymous access.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) await _run(service.clear);
  }

  Future<void> _openAndroidUrl(String url) => _run(() async {
    final launched = await context.read<YoutubeAccessService>().androidBackend.openFirefoxUrl(url);
    if (!launched && mounted) {
      final fallback = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!fallback) throw StateError('Could not open this link: $url');
    }
  });

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _screenMessage = null;
      _screenDetails = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        final failure = error is YoutubeFailure
            ? error
            : YoutubeFailureClassifier.classify(
                error,
                authenticated: context.read<YoutubeAccessService>().isConfigured,
                sourceUrl: widget.sourceUrl,
              );
        setState(() {
          _screenMessage = failure.userMessage;
          _screenDetails = failure.technicalSummary.isEmpty ? null : failure.technicalSummary;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final YoutubeAccessStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, title) = switch (status.state) {
      YoutubeAccessState.ready => (Icons.verified_user_rounded, 'Ready'),
      YoutubeAccessState.testing => (Icons.shield_outlined, 'Testing…'),
      YoutubeAccessState.verificationRequired ||
      YoutubeAccessState.rejected => (Icons.warning_amber_rounded, 'Verification required'),
      YoutubeAccessState.unavailable => (Icons.warning_amber_rounded, 'Could not verify'),
      _ => (Icons.shield_outlined, 'Setup required'),
    };
    return _AccessCard(
      title: title,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: status.state == YoutubeAccessState.ready ? Theme.of(context).colorScheme.primary : null),
          const SizedBox(width: 12),
          Expanded(child: Text(status.shortMessage ?? _statusExplanation(status))),
        ],
      ),
    );
  }

  static String _statusExplanation(YoutubeAccessStatus status) => switch (status.state) {
    YoutubeAccessState.ready => 'Authenticated YouTube access is configured and tested.',
    YoutubeAccessState.testing => 'Resonance is testing this session without downloading media.',
    YoutubeAccessState.configuredUntested => 'A session is configured but still needs a live test.',
    YoutubeAccessState.verificationRequired => 'YouTube blocked a request until a signed-in session is provided.',
    YoutubeAccessState.rejected => 'The saved session was rejected or expired. Reconnect or replace it.',
    YoutubeAccessState.unavailable => 'The session could not be verified. Review the message below and try again.',
    YoutubeAccessState.notConfigured =>
      'No authenticated session is configured. Anonymous YouTube access remains available.',
  };
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard();
  @override
  Widget build(BuildContext context) => const _AccessCard(
    title: 'Use only when required',
    child: Text(
      'A signed-in session is password-equivalent. Avoid large automated batches and consider using a separate YouTube account.',
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, this.details});
  final String message;
  final String? details;
  @override
  Widget build(BuildContext context) => _AccessCard(
    title: 'Could not complete that action',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, maxLines: 6, overflow: TextOverflow.ellipsis),
        if (details != null) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('Details'),
            children: [SelectableText(details!, maxLines: 12)],
          ),
        ],
      ],
    ),
  );
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      border: Border.all(color: Theme.of(context).colorScheme.outline),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

class _TutorialCard extends StatelessWidget {
  const _TutorialCard({required this.number, required this.title, required this.body, this.actions = const []});
  final int number;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: _AccessCard(
      title: '$number. $title',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(body),
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: actions)],
        ],
      ),
    ),
  );
}
