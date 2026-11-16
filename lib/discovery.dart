import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' show parseFragment;

import 'model.dart';
import 'video_links.dart';

class DiscoveredMedia {
  const DiscoveredMedia({
    required this.title,
    required this.creator,
    required this.license,
    required this.sourcePage,
    required this.mediaUrl,
    required this.mimeType,
    required this.bytes,
    this.licenseUrl,
  });
  final String title, creator, license, mimeType;
  final Uri sourcePage, mediaUrl;
  final Uri? licenseUrl;
  final int bytes;

  String get credit => [
        title,
        if (creator.isNotEmpty) creator,
        license,
        if (licenseUrl != null) licenseUrl.toString(),
        sourcePage.toString(),
        'Edited in Innerwave Studio',
      ].join('\n');
}

class DiscoveryClient {
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent =
        'InnerwaveStudio (https://github.com/victoralvelais/innerwave-studio)';

  Future<List<DiscoveredMedia>> search(String query) async {
    final terms = query.trim();
    if (terms.isEmpty) return [];
    final groups = await Future.wait([
      _query('$terms filetype:video'),
      _query('$terms filetype:audio'),
    ]);
    // Keep both videos and field recordings visible in order of relevance.
    final seen = <Uri>{};
    return [
      for (var i = 0; groups.any((g) => i < g.length); i++)
        for (final group in groups)
          if (i < group.length && seen.add(group[i].sourcePage)) group[i],
    ];
  }

  Future<List<DiscoveredMedia>> findCopies(VideoSourceLink link) async {
    var source = link;
    // Short TikTok share URLs expose the post ID after a first-party redirect.
    for (var redirects = 0;
        source.videoId == null && redirects < 4;
        redirects++) {
      final request = await _http
          .openUrl('HEAD', source.url)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (!response.isRedirect || location == null) return [];
      final redirect =
          VideoSourceLink.parse(source.url.resolve(location).toString());
      if (redirect == null || redirect.platform != 'TikTok') return [];
      source = redirect;
    }
    final id = source.videoId;
    if (id == null) return [];
    return _query('insource:"$id" filetype:video', source: source);
  }

  Future<List<DiscoveredMedia>> _query(String search,
      {VideoSourceLink? source}) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'search',
      'gsrnamespace': '6',
      'gsrlimit': '10',
      'gsrsearch': search,
      'prop': source == null ? 'imageinfo' : 'imageinfo|revisions',
      if (source != null) ...{'rvslots': 'main', 'rvprop': 'content'},
      'iiprop': 'url|mime|size|extmetadata',
      'iiextmetadatafilter': 'Artist|LicenseShortName|LicenseUrl',
    });
    final response = await _get(uri);
    final raw = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 25));
    return parseCommonsResults(jsonDecode(raw) as Map<String, dynamic>,
        source: source);
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    final request =
        await _http.getUrl(uri).timeout(const Duration(seconds: 20));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(const Duration(seconds: 10));
      if (response.statusCode == 429) {
        throw const FormatException(
            'Wikimedia Commons is busy. Try again in a moment.');
      }
      throw HttpException(
          'Wikimedia Commons returned HTTP ${response.statusCode}.');
    }
    return response;
  }

  Future<File> download(DiscoveredMedia media, Directory directory,
      {void Function(int bytes, int? total)? onProgress}) async {
    if (!_commonsFile(media.mediaUrl)) {
      throw const FormatException(
          'This item has no downloadable Wikimedia file.');
    }
    await directory.create(recursive: true);
    final path = File('${directory.path}/commons-${makeId()}.media');
    final partial = File('${path.path}.part');
    try {
      final response = await _get(media.mediaUrl);
      if (response.headers.contentType?.mimeType == 'text/html') {
        await response.drain<void>();
        throw const FormatException(
            'The source returned a web page instead of media.');
      }
      final total = media.bytes > 0
          ? media.bytes
          : (response.contentLength >= 0 ? response.contentLength : null);
      var received = 0;
      final sink = partial.openWrite();
      try {
        // addStream applies back-pressure while a large file is downloading.
        await sink.addStream(
            response.timeout(const Duration(seconds: 45)).map((chunk) {
          received += chunk.length;
          onProgress?.call(received, total);
          return chunk;
        }));
      } finally {
        await sink.close();
      }
      if (received == 0 || (total != null && received != total)) {
        throw const FormatException(
            'The media download was incomplete. Try again.');
      }
      return await partial.rename(path.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  void close() => _http.close(force: true);
}

bool _commonsFile(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'upload.wikimedia.org' &&
    uri.userInfo.isEmpty &&
    !uri.hasPort;

bool _creditsVideo(String wiki, VideoSourceLink source) {
  // Only the source field establishes provenance. A matching link in the
  // description, review or an author's social profile is insufficient.
  final start = RegExp(r'(?:^|\n)\s*\|\s*source\s*=', caseSensitive: false)
      .firstMatch(wiki);
  if (start == null) return false;
  final rest = wiki.substring(start.end);
  final end = RegExp(r'\n\s*(?:\|\s*[\w -]+\s*=|\}\})').firstMatch(rest);
  final field = rest.substring(0, end?.start);
  for (final match in RegExp(r'https?://[^\s\]|}<>]+').allMatches(field)) {
    final link = VideoSourceLink.parse(match[0]!);
    if (link?.platform == source.platform && link?.videoId == source.videoId)
      return true;
  }
  if (source.platform != 'YouTube') return false;
  final templates = RegExp(
      r'\{\{\s*(?:from[ _]+youtube|youtube)\s*\|\s*(?:1\s*=\s*)?([A-Za-z0-9_-]{11})(?=\s*[|}])',
      caseSensitive: false);
  return templates.allMatches(field).any((m) => m[1] == source.videoId);
}

List<DiscoveredMedia> parseCommonsResults(Map<String, dynamic> data,
    {VideoSourceLink? source}) {
  if (data.containsKey('error')) {
    throw const FormatException(
        'Wikimedia Commons could not complete this search. Try another search.');
  }
  final pages = (data['query']?['pages'] as List? ?? [])
      .whereType<Map>()
      .toList()
    ..sort(
        (a, b) => (a['index'] as int? ?? 0).compareTo(b['index'] as int? ?? 0));
  final results = <DiscoveredMedia>[];
  for (final page in pages) {
    if (source != null) {
      final revision = (page['revisions'] as List?)?.firstOrNull;
      final wiki = revision?['slots']?['main']?['content'];
      if (wiki is! String || !_creditsVideo(wiki, source)) continue;
    }
    final info = (page['imageinfo'] as List?)?.firstOrNull;
    if (info is! Map) continue;
    final media = Uri.tryParse(info['url'] as String? ?? '');
    final sourcePage = Uri.tryParse(info['descriptionurl'] as String? ?? '');
    if (media == null ||
        !_commonsFile(media) ||
        sourcePage?.scheme != 'https' ||
        sourcePage?.host != 'commons.wikimedia.org') continue;
    final mime = info['mime'] as String? ?? '';
    if (!mime.startsWith('audio/') &&
        !mime.startsWith('video/') &&
        mime != 'application/ogg') continue;
    final metadata = info['extmetadata'] as Map? ?? {};
    String field(String key) {
      final value = metadata[key]?['value'];
      return value is String
          ? (parseFragment(value).text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim()
          : '';
    }

    final title =
        (page['title'] as String? ?? '').replaceFirst(RegExp(r'^File:'), '');
    final license = field('LicenseShortName');
    final licenseLink = Uri.tryParse(field('LicenseUrl'));
    results.add(DiscoveredMedia(
        title: title,
        creator: field('Artist'),
        license: license.isEmpty ? 'See source for license' : license,
        licenseUrl: licenseLink != null &&
                {'https', 'http'}.contains(licenseLink.scheme)
            ? licenseLink
            : null,
        mediaUrl: media,
        sourcePage: sourcePage!,
        mimeType: mime,
        bytes: info['size'] as int? ?? 0));
  }
  return results;
}
