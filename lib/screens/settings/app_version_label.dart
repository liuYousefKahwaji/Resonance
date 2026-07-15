import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

typedef AppVersionLoader = Future<String> Function();

class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key, this.versionLoader});

  final AppVersionLoader? versionLoader;

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  late final Future<String> _version = _loadVersion();

  Future<String> _loadVersion() async {
    try {
      final version = await (widget.versionLoader?.call() ?? _loadPackagedVersion());
      return version.trim().isEmpty ? 'Unavailable' : version.trim();
    } catch (_) {
      return 'Unavailable';
    }
  }

  Future<String> _loadPackagedVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _version,
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? 'Loading…',
          key: const ValueKey('settings-about-version'),
          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        );
      },
    );
  }
}
