// lib/platform/android/storage_permission_service.dart
//
// Handles runtime audio/storage permissions on Android using permission_handler.
// On Android 13+ (API 33+) we request Permission.audio → READ_MEDIA_AUDIO.
// On Android ≤12 (API ≤32) we request Permission.storage → READ_EXTERNAL_STORAGE.
//
// This file is imported on ALL platforms (so the desktop build doesn't break),
// but every public method guards itself with Platform.isAndroid before
// calling into permission_handler — on desktop the calls are no-ops.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class StoragePermissionService {
  /// Returns the correct [Permission] for the current Android API level.
  /// On Android 13+ → Permission.audio (READ_MEDIA_AUDIO)
  /// On Android ≤12 → Permission.storage (READ_EXTERNAL_STORAGE)
  static Permission get _audioPermission {
    // DeviceInfoPlugin would give us the exact SDK int, but for the
    // READ_MEDIA_AUDIO vs READ_EXTERNAL_STORAGE split the simplest reliable
    // approach is to check the permission status of .audio first; if that
    // throws a PlatformException on older SDKs, .storage is the fallback.
    // In practice, permission_handler 12.x maps Permission.audio to
    // READ_MEDIA_AUDIO on SDK 33+ and returns PermissionStatus.denied (not an
    // exception) on older SDKs, so this is safe.
    return Permission.audio;
  }

  /// True if the app currently has audio read access.
  static Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await _audioPermission.status;
    if (status.isGranted) return true;
    // Fallback: check legacy storage permission for Android ≤12
    final legacyStatus = await Permission.storage.status;
    return legacyStatus.isGranted;
  }

  /// Requests audio read access.
  /// Returns true if granted (either the modern or legacy permission).
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;

    // Try the modern READ_MEDIA_AUDIO first (Android 13+)
    final audioStatus = await _audioPermission.request();
    if (audioStatus.isGranted) return true;

    // If permanently denied or restricted, don't try storage fallback
    if (audioStatus.isPermanentlyDenied) return false;

    // On older Android (≤12), READ_MEDIA_AUDIO may not exist — try storage
    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  /// Opens the OS app-settings page so the user can manually grant permission.
  static Future<void> openSettings() async {
    await openAppSettings();
  }

  /// Shows the permission rationale dialog, then requests.
  /// Returns true if permission was ultimately granted.
  static Future<bool> requestWithRationale(BuildContext context) async {
    if (!Platform.isAndroid) return true;

    final already = await hasPermission();
    if (already) return true;

    final permStatus = await _audioPermission.status;
    if (permStatus.isPermanentlyDenied) {
      // Can't request again — send user to settings
      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text(
              'Resonance needs access to your audio files to import songs. '
              'Please grant the permission in app settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await openSettings();
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
      }
      return false;
    }

    // Show rationale if needed
    if (context.mounted) {
      bool proceed = true;
      if (permStatus.isDenied) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text(
              'Resonance needs access to your audio files to import songs.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  proceed = false;
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Allow'),
              ),
            ],
          ),
        );
      }
      if (!proceed) return false;
    }

    return requestPermission();
  }
}
