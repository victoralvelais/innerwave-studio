/// A provider page opened in its own app or browser. Audio is imported from
/// the saved file; the canonical page can travel with its clip as a credit.
class VideoSourceLink {
  const VideoSourceLink._(this.platform, this.url);
  final String platform;
  final Uri url;
  String? get videoId => platform == 'YouTube'
      ? url.queryParameters['v']
      : (url.pathSegments.contains('video') ? url.pathSegments.last : null);

  String get instructions => platform == 'YouTube'
      ? 'Choose your original video or an MP4 saved from your uploads in YouTube Studio.'
      : 'In TikTok, use Share → Save video when available, then choose the saved video.';

  static VideoSourceLink? parse(String text) {
    final value = text.trim();
    // A TikTok share copied from a phone can include a caption around the URL.
    final match =
        RegExp(r'https?://[^\s<>"“”]+', caseSensitive: false).firstMatch(value);
    final raw =
        (match?.group(0) ?? value).replaceFirst(RegExp(r'[.,!?)\]]+$'), '');
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) return null;
    final host = uri.host.toLowerCase();
    final parts = uri.pathSegments;
    String? video;
    if (host == 'youtu.be' && parts.length == 1) {
      video = parts[0];
    } else if ({
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com'
    }.contains(host)) {
      if (uri.path == '/watch') video = uri.queryParameters['v'];
      if (parts.length == 2 && {'shorts', 'embed', 'live'}.contains(parts[0]))
        video = parts[1];
    }
    if (video != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(video)) {
      return VideoSourceLink._(
          'YouTube', Uri.https('www.youtube.com', '/watch', {'v': video}));
    }
    final token = RegExp(r'^[A-Za-z0-9_-]+$');
    final segments = parts.where((p) => p.isNotEmpty).toList();
    if ({'vm.tiktok.com', 'vt.tiktok.com'}.contains(host) &&
        segments.length == 1 &&
        token.hasMatch(segments[0])) {
      return VideoSourceLink._('TikTok', Uri.https(host, '/${segments[0]}/'));
    }
    if ({'www.tiktok.com', 'tiktok.com', 'm.tiktok.com'}.contains(host)) {
      if (segments.length == 2 &&
          segments[0] == 't' &&
          token.hasMatch(segments[1])) {
        return VideoSourceLink._(
            'TikTok', Uri.https('www.tiktok.com', '/t/${segments[1]}/'));
      }
      if (segments.length == 3 &&
          segments[1] == 'video' &&
          (segments[0] == 'share' ||
              RegExp(r'^@[A-Za-z0-9._]+$').hasMatch(segments[0])) &&
          RegExp(r'^[0-9]{1,20}$').hasMatch(segments[2])) {
        return VideoSourceLink._(
            'TikTok', Uri.https('www.tiktok.com', '/${segments.join('/')}'));
      }
    }
    return null;
  }
}

Uri videoSearchUrl(String platform, String query) => switch (platform) {
      'YouTube' => Uri.https(
          'www.youtube.com', '/results', {'search_query': query.trim()}),
      'TikTok' => Uri.https('www.tiktok.com', '/search', {'q': query.trim()}),
      _ => throw ArgumentError.value(platform, 'platform'),
    };
