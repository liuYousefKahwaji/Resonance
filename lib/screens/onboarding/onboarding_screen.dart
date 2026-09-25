import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:resonance/app/theme.dart';
import 'package:resonance/providers/theme_provider.dart';
import 'package:resonance/screens/settings/youtube_access_screen.dart';
import 'package:resonance/services/youtube/youtube_access_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-run tour. Each choice is saved by its owning service immediately, so
/// closing the app in the middle never loses the user's selected preferences.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _page = 0;
  bool _finishing = false;
  bool _demoOpen = false;

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    if (mounted) widget.onFinished();
  }

  void _next() {
    if (_page == 4) {
      _finish();
    } else {
      setState(() => _page++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 620;
    final icon = [
      Icons.graphic_eq_rounded,
      Icons.library_music_rounded,
      Icons.shield_rounded,
      Icons.palette_rounded,
      Icons.album_rounded,
    ][_page];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 24 : 48, vertical: 24),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      const Text('RESONANCE', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
                      const Spacer(),
                      TextButton(onPressed: _finishing ? null : _finish, child: const Text('Skip tour')),
                    ],
                  ),
                  const SizedBox(height: 22),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: (_page + 1) / 5),
                      duration: const Duration(milliseconds: 430),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => LinearProgressIndicator(value: value, minHeight: 4),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 30, bottom: 18),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 390),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0.06, 0.03), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          ),
                          child: Column(
                            key: ValueKey(_page),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: Container(
                                  width: compact ? 118 : 150,
                                  height: compact ? 118 : 150,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        theme.colorScheme.primary.withValues(alpha: 0.30),
                                        theme.colorScheme.secondary.withValues(alpha: 0.05),
                                      ],
                                    ),
                                  ),
                                  child: Icon(icon, size: compact ? 64 : 80, color: theme.colorScheme.primary),
                                ),
                              ),
                              const SizedBox(height: 28),
                              Text(
                                _title,
                                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 10),
                              Text(_description, style: theme.textTheme.bodyLarge?.copyWith(height: 1.45)),
                              const SizedBox(height: 28),
                              _content(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      if (_page > 0)
                        TextButton.icon(
                          onPressed: () => setState(() => _page--),
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Back'),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _finishing ? null : _next,
                        icon: Icon(_page == 4 ? Icons.check_rounded : Icons.arrow_forward_rounded),
                        label: Text(_page == 4 ? 'Start listening' : 'Continue'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _title => switch (_page) {
    0 => 'Your music, your way',
    1 => 'Choose your starting place',
    2 => 'Connect YouTube Music',
    3 => 'Make it yours',
    _ => 'A few useful gestures',
  };

  String get _description => switch (_page) {
    0 =>
      'Play files from your device and discover music from YouTube in one place. Your playlists and settings stay on this device.',
    1 =>
      'Pick the view you want to open first. You can switch between Library and Discover by tapping their names at the top.',
    2 =>
      'Connect your YouTube session to see your YouTube Music home and history. Streaming and search remain available without this step.',
    3 => 'Choose a color style now. You can change it, the listening focus, and player colors any time in Settings.',
    _ =>
      'Tap the square album cover in the mini player to open the full player. Swipe left or right for the next or previous song, up for the queue, and down to return. Use the lyrics button to sing along.',
  };

  Widget _content(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    switch (_page) {
      case 0:
        return const _TourNote(
          icon: Icons.offline_bolt_rounded,
          text:
              'Local songs work offline. Streams play through your connection and can be saved to a playlist or downloaded.',
        );
      case 1:
        return Column(
          children: [
            _FocusOption(
              icon: Icons.library_music_rounded,
              title: 'Library first',
              description: 'Your files and playlists are ready on launch.',
              selected: provider.listeningFocus == ListeningFocus.local,
              onTap: () => provider.setListeningFocus(ListeningFocus.local),
            ),
            const SizedBox(height: 12),
            _FocusOption(
              icon: Icons.explore_rounded,
              title: 'Discover first',
              description: 'Open with YouTube search and music suggestions.',
              selected: provider.listeningFocus == ListeningFocus.stream,
              onTap: () => provider.setListeningFocus(ListeningFocus.stream),
            ),
          ],
        );
      case 2:
        final access = context.watch<YoutubeAccessService>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TourNote(
              icon: access.isConfigured ? Icons.verified_rounded : Icons.lock_outline_rounded,
              text: access.isConfigured
                  ? 'YouTube access is connected.'
                  : Platform.isWindows
                  ? 'Choose a signed-in browser profile or import a cookies.txt file. Your cookies stay on this device.'
                  : 'Import a YouTube cookies.txt file from your browser. Your cookies stay on this device.',
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const YoutubeAccessScreen())),
              icon: const Icon(Icons.settings_rounded),
              label: Text(access.isConfigured ? 'Manage YouTube access' : 'Set up YouTube access'),
            ),
          ],
        );
      case 3:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownMenu<ResonanceThemeStyle>(
              label: const Text('Color style'),
              initialSelection: provider.themeStyle,
              dropdownMenuEntries: [
                for (final style in ResonanceThemeStyle.values) DropdownMenuEntry(value: style, label: style.label),
              ],
              onSelected: (style) {
                if (style != null) provider.setThemeStyle(style);
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dark appearance'),
              value: provider.themeMode == ThemeMode.dark,
              onChanged: provider.toggleTheme,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use album art colors in the player'),
              value: provider.artworkPlayerColors,
              onChanged: provider.setArtworkPlayerColors,
            ),
          ],
        );
      default:
        return Column(
          children: [
            Text('Try it: tap the square cover below.', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            Card(
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          InkWell(
                            key: const Key('onboarding-cover-demo'),
                            onTap: () => setState(() => _demoOpen = !_demoOpen),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: 66,
                              height: 66,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    Theme.of(context).colorScheme.secondary,
                                  ],
                                ),
                              ),
                              child: const Icon(Icons.album_rounded, color: Colors.white, size: 38),
                            ),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Now playing', style: TextStyle(fontWeight: FontWeight.w700)),
                                Text('Tap the artwork to open the full player'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_demoOpen) ...[
                        const SizedBox(height: 18),
                        const Icon(Icons.keyboard_arrow_down_rounded),
                        const Text('Full player', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.skip_previous_rounded),
                            SizedBox(width: 28),
                            Icon(Icons.play_circle_filled_rounded, size: 42),
                            SizedBox(width: 28),
                            Icon(Icons.skip_next_rounded),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text('The queue and lyrics controls live here.'),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const _TourNote(icon: Icons.queue_music_rounded, text: 'Queue → upcoming songs and quick selection'),
            const SizedBox(height: 10),
            const _TourNote(
              icon: Icons.swipe_rounded,
              text: 'Swipe left / right → skip songs · up → queue · down → back',
            ),
            const SizedBox(height: 10),
            const _TourNote(icon: Icons.lyrics_rounded, text: 'Lyrics button → timed lyrics when available'),
          ],
        );
    }
  }
}

class _TourNote extends StatelessWidget {
  const _TourNote({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

class _FocusOption extends StatelessWidget {
  const _FocusOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: selected ? colors.primaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    Text(description),
                  ],
                ),
              ),
              if (selected) const Icon(Icons.check_circle_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
