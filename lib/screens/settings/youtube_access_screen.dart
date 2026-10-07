import 'package:resonance/l10n/app_strings.dart';
import 'package:resonance/app/theme.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:resonance/core/youtube/youtube_access_models.dart';
import 'package:resonance/core/youtube/youtube_failure_classifier.dart';
import 'package:resonance/services/youtube/windows_browser_detector.dart';
import 'package:resonance/services/youtube/windows_chromium_connector.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:resonance/services/youtube/youtube_history_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const _browserSessionNote =
    'Resonance tries your default browser directly. Some browsers protect their saved sessions and may need the optional browser connector.';

enum _BrowserFallback { retry, connector }

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
    final historyPreferences = context.watch<YoutubeHistoryPreferences?>();
    final content = <Widget>[
      _StatusCard(status: service.status),
      const SizedBox(height: 12),
      const _SafetyCard(),
      if (historyPreferences != null) ...[
        const SizedBox(height: 12),
        _HistorySyncCard(
          enabled: historyPreferences.enabled,
          accessReady: service.isReady,
          busy: _busy,
          onChanged: historyPreferences.setEnabled,
        ),
      ],
      if (_screenMessage != null) ...[
        const SizedBox(height: 12),
        _MessageCard(message: _screenMessage!, details: _screenDetails),
      ],
      const SizedBox(height: 16),
      if (_isWindows) _buildWindows(service) else if (_isAndroid) _buildAndroid(service),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.tr("YouTube access"))),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _isWindows ? 720 : double.infinity),
            child: ListView(padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 28), children: content),
          ),
        ),
      ),
    );
  }

  Widget _buildWindows(YoutubeAccessService service) {
    if (service.status.method == YoutubeAccessMethod.windowsCookieFile) {
      return _AccessCard(
        title: context.tr("Imported cookies.txt"),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                "yt-dlp will read this selected Netscape cookies.txt file. Treat it like a password and keep it in a private location.",
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _run(() => service.testCurrent(sourceUrl: widget.sourceUrl)),
                  icon: const Icon(Icons.verified_rounded),
                  label: Text(context.tr("Test access")),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _importWindowsCookies(service),
                  child: Text(context.tr("Replace cookies.txt")),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _connect(service, null),
                  child: Text(context.tr("Use browser instead")),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _confirmClear(service),
                  child: Text(context.tr("Disconnect")),
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (service.isConfigured) {
      return _AccessCard(
        title: context.tr("Browser session"),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              WindowsChromiumConnector.isSource(service.windowsBrowserId)
                  ? context.tr(
                      'The {0} connector keeps your YouTube session refreshed. Resonance stores an encrypted copy on this PC; your Google password is never saved.',
                      [YoutubeAccessService.browserDisplayName(service.windowsBrowserId)],
                    )
                  : context.tr(
                      'Resonance reads your connected browser profile locally when you use YouTube. Your Google password is never saved.',
                    ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _run(() => service.testCurrent(sourceUrl: widget.sourceUrl)),
                  icon: const Icon(Icons.verified_rounded),
                  label: Text(context.tr("Test access")),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _connect(service, service.windowsBrowserId),
                  child: Text(context.tr("Reconnect")),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _chooseAndConnect(service),
                  child: Text(context.tr("Choose another browser")),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _confirmClear(service),
                  child: Text(context.tr("Disconnect")),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return _AccessCard(
      title: context.tr("Connect your browser"),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr(
              "Open YouTube Music, sign in or complete its verification page, then let Resonance test and remember that browser profile.",
            ),
          ),
          const SizedBox(height: 8),
          Text(context.tr(_browserSessionNote), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : () => _connect(service, null),
            icon: const Icon(Icons.open_in_browser_rounded),
            label: Text(context.tr("Connect browser session")),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('youtube-windows-import-cookies'),
            onPressed: _busy ? null : () => _importWindowsCookies(service),
            icon: const Icon(Icons.file_open_rounded),
            label: Text(context.tr("Import cookies.txt instead")),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroid(YoutubeAccessService service) {
    if (service.isConfigured && !_showGuide) {
      return _AccessCard(
        title: context.tr("Imported cookies.txt"),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr("Delete the original cookies.txt from Downloads. Treat it like a password.")),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _run(() => service.testCurrent(sourceUrl: widget.sourceUrl)),
                  child: Text(context.tr("Test access")),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _importCookies(service),
                  child: Text(context.tr("Replace cookies")),
                ),
                OutlinedButton(
                  onPressed: () => setState(() => _showGuide = true),
                  child: Text(context.tr("Show guide")),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _confirmClear(service),
                  child: Text(context.tr("Clear cookies")),
                ),
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
          title: context.tr("Install Firefox"),
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
              child: Text(_firefoxInstalled ? context.tr("Open Firefox") : context.tr("Install Firefox")),
            ),
          ],
        ),
        _TutorialCard(
          number: 2,
          title: context.tr("Keep YouTube inside Firefox"),
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
              child: Text(context.tr("View Firefox instructions")),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await context.read<YoutubeAccessService>().androidBackend.openYoutubeAppSettings();
                    }),
              child: Text(context.tr("YouTube app settings")),
            ),
          ],
        ),
        _TutorialCard(
          number: 3,
          title: context.tr("Install cookies.txt"),
          body:
              'Install the “cookies.txt” add-on by Lennon Hill from Mozilla Add-ons. During installation, allow it in private browsing. '
              'This is a third-party add-on and requests access to site data, tabs, downloads, and the clipboard.',
          actions: [
            OutlinedButton(
              key: const Key('youtube-cookies-addon-link'),
              onPressed: _busy
                  ? null
                  : () => _openAndroidUrl('https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/'),
              child: Text(context.tr("Open cookies.txt add-on")),
            ),
          ],
        ),
        _TutorialCard(
          number: 4,
          title: context.tr("Create a durable YouTube session"),
          body:
              'Open one new private Firefox tab and sign in at youtube.com. Confirm your profile avatar/account menu is visible before continuing. '
              'In that same tab, open youtube.com/robots.txt and reload it once. '
              'Keep it as the only private tab. If the add-on is absent: Firefox ⋮ → Extensions → cookies.txt → Run in private browsing → On.',
          actions: [
            OutlinedButton(
              key: const Key('youtube-open-firefox'),
              onPressed: _busy ? null : () => _openAndroidUrl('https://www.youtube.com/'),
              child: Text(context.tr("Open YouTube in Firefox")),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => _openAndroidUrl('https://www.youtube.com/robots.txt'),
              child: Text(context.tr("Open robots.txt in Firefox")),
            ),
          ],
        ),
        _TutorialCard(
          number: 5,
          title: context.tr("Export only YouTube cookies"),
          body:
              'While robots.txt is open, open cookies.txt and choose Current Site → Download. Do not choose ALL. '
              'Then close every private Firefox tab and do not reopen that session.',
        ),
        _TutorialCard(
          number: 6,
          title: context.tr("Import into Resonance"),
          body:
              'Import the downloaded .txt file. Resonance verifies that it contains a signed-in YouTube session, keeps an app-private copy, and tests it without downloading audio.',
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _importCookies(service),
              icon: const Icon(Icons.file_open_rounded),
              label: Text(service.isConfigured ? context.tr("Replace cookies.txt") : context.tr("Import cookies.txt")),
            ),
            if (service.isConfigured)
              TextButton(onPressed: () => setState(() => _showGuide = false), child: Text(context.tr("Hide guide"))),
          ],
        ),
      ],
    );
  }

  Future<void> _connect(YoutubeAccessService service, String? browserId) async {
    if (!await _ensureWarning(service)) return;
    var selected = browserId == null
        ? await _detector.detectDefaultBrowser()
        : WindowsBrowserDetector.baseBrowserId(browserId);
    if (selected == null && mounted) selected = await _pickBrowser();
    if (selected == null || !mounted) return;
    final selectedBrowser = selected;
    var launched = await _detector.launchBrowser(selected, 'https://music.youtube.com/');
    launched =
        launched || await launchUrl(Uri.parse('https://music.youtube.com/'), mode: LaunchMode.externalApplication);
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
        title: Text(context.tr("Finish in your browser")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                'Sign in to YouTube Music in {0}, then return here when your personalized home opens normally.',
                [YoutubeAccessService.browserDisplayName(selected)],
              ),
            ),
            const SizedBox(height: 12),
            Text(context.tr(_browserSessionNote), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(context.tr("Cancel"))),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr("I'm signed in — test access")),
          ),
        ],
      ),
    );
    if (test == true) {
      final cookieSource = await _detector.resolveCookieSource(selected);
      await _run(() async {
        while (mounted) {
          try {
            await service.connectWindowsBrowser(cookieSource, sourceUrl: widget.sourceUrl);
            return;
          } catch (error) {
            final failure = YoutubeFailureClassifier.classify(error, authenticated: true);
            final browserReadBlocked =
                failure.kind == YoutubeFailureKind.browserCookiesLocked ||
                failure.kind == YoutubeFailureKind.browserDecryptionFailed;
            if (!mounted || !WindowsChromiumConnector.supports(selectedBrowser) || !browserReadBlocked) rethrow;
            final choice = await showDialog<_BrowserFallback>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Text(context.tr('Could not read this browser session')),
                content: Text(
                  context.tr(
                    failure.kind == YoutubeFailureKind.browserCookiesLocked
                        ? 'The browser is keeping its session locked. Close its windows and retry, or use the optional Resonance browser connector.'
                        : 'This browser protects its saved session, so direct access did not work. You can use the optional Resonance browser connector instead.',
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.tr('Cancel'))),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(dialogContext, _BrowserFallback.retry),
                    child: Text(context.tr('Retry')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, _BrowserFallback.connector),
                    child: Text(context.tr('Use browser connector')),
                  ),
                ],
              ),
            );
            if (choice == _BrowserFallback.retry) continue;
            if (choice == _BrowserFallback.connector) {
              await _connectChromium(service, selectedBrowser);
              return;
            }
            rethrow;
          }
        }
      });
    }
  }

  Future<void> _connectChromium(YoutubeAccessService service, String browser) async {
    final connector = service.windowsConnector;
    final pending = await connector.begin(browser);
    try {
      await _detector.launchBrowser(browser, 'https://music.youtube.com/');
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.tr('Connect {0}', [YoutubeAccessService.browserDisplayName(browser)])),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr(
                      'One-time setup: install the Resonance YouTube Connector in this browser. If it is already installed, skip to step 3.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(context.tr('1. Open the extensions page and enable Developer mode.')),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final url = browser == 'edge'
                          ? 'edge://extensions/'
                          : browser == 'brave'
                          ? 'brave://extensions/'
                          : 'chrome://extensions/';
                      if (!await _detector.launchBrowser(browser, url) && dialogContext.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(context.tr('Open the extensions page from your browser menu.'))),
                        );
                      }
                    },
                    icon: const Icon(Icons.extension_outlined),
                    label: Text(context.tr('Open extensions')),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr(
                      '2. Choose Load unpacked, then select the connector folder. Paste its path into the folder picker.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: pending.extensionDirectory));
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(context.tr('Connector folder path copied.'))));
                      }
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(context.tr('Copy folder path')),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr(
                      '3. Sign in to YouTube Music. Open the Resonance connector from your browser’s extensions menu and press Connect.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr(
                      'Return here and test access. Keep the connector enabled to refresh your session automatically.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(context.tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(context.tr('Test access'))),
          ],
        ),
      );
      if (accepted == true) await service.connectWindowsBrowser(pending.source, sourceUrl: widget.sourceUrl);
    } finally {
      if (service.windowsBrowserId != pending.source) await connector.revoke(pending.source);
    }
  }

  Future<void> _chooseAndConnect(YoutubeAccessService service) async {
    final browser = await _pickBrowser();
    if (browser != null) await _connect(service, browser);
  }

  Future<void> _importWindowsCookies(YoutubeAccessService service) async {
    if (!await _ensureWarning(service)) return;
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose cookies.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || file.path == null) return;
    final path = file.path!;
    await _run(() => service.connectWindowsCookieFile(path, sourceUrl: widget.sourceUrl));
  }

  Future<String?> _pickBrowser() => showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(context.tr("Choose the browser where you are signed in to YouTube")),
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
        title: Text(context.tr("Account safety")),
        content: Text(
          context.tr(
            "This uses a signed-in YouTube session. Automated requests can cause YouTube to temporarily restrict or permanently disable an account. Use it only when verification is required, avoid large batches, and consider a separate account.",
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(context.tr("Cancel"))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(context.tr("I understand"))),
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
        title: Text(_isWindows ? context.tr("Disconnect browser session?") : context.tr("Clear imported cookies?")),
        content: Text(context.tr("YouTube requests will return to anonymous access.")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(context.tr("Cancel"))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(context.tr("Clear"))),
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

class _HistorySyncCard extends StatelessWidget {
  const _HistorySyncCard({
    required this.enabled,
    required this.accessReady,
    required this.busy,
    required this.onChanged,
  });

  final bool enabled;
  final bool accessReady;
  final bool busy;
  final Future<void> Function(bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _AccessCard(
      title: context.tr("YouTube Music history"),
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: enabled,
        onChanged: !accessReady || busy ? null : (value) => unawaited(onChanged(value)),
        title: Text(context.tr("Sync plays to YouTube Music history")),
        subtitle: Text(
          accessReady
              ? context.tr("Adds YouTube tracks played in Resonance to your YouTube Music listening history.")
              : context.tr("Connect and test YouTube access before enabling history sync."),
        ),
      ),
    );
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
          Expanded(child: Text(context.trRendered(status.shortMessage ?? _statusExplanation(status)))),
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
  Widget build(BuildContext context) => _AccessCard(
    title: context.tr("Use only when required"),
    child: Text(
      context.tr(
        "A signed-in session is password-equivalent. Avoid large automated batches and consider using a separate YouTube account.",
      ),
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, this.details});
  final String message;
  final String? details;
  @override
  Widget build(BuildContext context) => _AccessCard(
    title: context.tr("Could not complete that action"),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.trRendered(message), maxLines: 6, overflow: TextOverflow.ellipsis),
        if (details != null) ...[
          const SizedBox(height: 8),
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(context.tr("Details")),
              children: [SelectableText(details!, maxLines: 12)],
            ),
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
      borderRadius: resonanceBorderRadius(context, 14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr(title), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
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
      title: '$number. ${context.tr(title)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr(body)),
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: actions)],
        ],
      ),
    ),
  );
}
