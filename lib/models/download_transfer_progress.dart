import 'dart:convert';

/// Live transfer figures only. Resolver URLs, headers and file paths never enter this model.
class DownloadTransferProgress {
  const DownloadTransferProgress({
    this.downloadedBytes,
    this.totalBytes,
    this.estimatedTotal = false,
    this.bytesPerSecond,
    this.etaSeconds,
  });
  final int? downloadedBytes, totalBytes, etaSeconds;
  final double? bytesPerSecond;
  final bool estimatedTotal;
  static const marker = 'resonance_transfer:';
  static DownloadTransferProgress? parse(String event) {
    final index = event.indexOf(marker);
    if (index < 0) return null;
    try {
      final data = jsonDecode(event.substring(index + marker.length));
      if (data is! Map) return null;
      num? number(String key) {
        final value = data[key];
        return value is num && value.isFinite && value >= 0 ? value : null;
      }

      final reportedTotal = number('totalBytes');
      final exact = reportedTotal != null && reportedTotal > 0 ? reportedTotal : null;
      final reportedEstimate = number('estimatedTotalBytes');
      final estimate = reportedEstimate != null && reportedEstimate > 0 ? reportedEstimate : null;
      final speed = number('bytesPerSecond');
      return DownloadTransferProgress(
        downloadedBytes: number('downloadedBytes')?.toInt(),
        totalBytes: (exact ?? estimate)?.toInt(),
        estimatedTotal: exact == null && estimate != null,
        bytesPerSecond: speed != null && speed > 0 ? speed.toDouble() : null,
        etaSeconds: number('etaSeconds')?.ceil(),
      );
    } catch (_) {
      return null;
    }
  }

  String get sizeLabel {
    if (downloadedBytes == null) {
      return totalBytes == null ? '' : '${estimatedTotal ? '~' : ''}${formatBytes(totalBytes!)}';
    }
    return totalBytes == null
        ? formatBytes(downloadedBytes!)
        : '${formatBytes(downloadedBytes!)} / ${estimatedTotal ? '~' : ''}${formatBytes(totalBytes!)}';
  }

  static String formatBytes(num bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 || value >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

const windowsDownloadProgressTemplate =
    'download:resonance_progress:%(progress._percent_str)s|resonance_transfer:'
    '{"downloadedBytes":%(progress.downloaded_bytes|null)j,"totalBytes":%(progress.total_bytes|null)j,'
    '"estimatedTotalBytes":%(progress.total_bytes_estimate|null)j,"bytesPerSecond":%(progress.speed|null)j,"etaSeconds":%(progress.eta|null)j}';
