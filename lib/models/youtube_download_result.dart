class YoutubeDownloadResult {
  final String localPath;
  final String? youtubeVideoId;
  final String? title;
  final String? artist;

  const YoutubeDownloadResult({required this.localPath, this.youtubeVideoId, this.title, this.artist});
}
