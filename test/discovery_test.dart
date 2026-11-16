import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/discovery.dart';
import 'package:innerwave_studio/video_links.dart';

void main() {
  test('shared links are recognized and tracking parameters are dropped', () {
    const id = 'BqOo6RKxKEA';
    for (final url in [
      'https://youtu.be/$id?si=x',
      'https://m.youtube.com/watch?v=$id&t=12',
      'https://www.youtube.com/shorts/$id'
    ]) {
      expect(VideoSourceLink.parse(url)?.url.toString(),
          'https://www.youtube.com/watch?v=$id');
    }
    const tik = 'https://www.tiktok.com/@.c1nd3r/video/7524797848240655671';
    expect(VideoSourceLink.parse('Watch this $tik?_r=1')?.url.toString(), tik);
    expect(VideoSourceLink.parse('https://vm.tiktok.com/ZXabc/')?.platform,
        'TikTok');
    expect(VideoSourceLink.parse('https://www.tiktok.com/t/ZXabc/')?.videoId,
        isNull);
    for (final other in [
      'https://youtube.com.example/watch?v=$id',
      'https://youtube.com/playlist?list=$id',
      'https://www.tiktok.com/@a',
      'rain sounds'
    ]) {
      expect(VideoSourceLink.parse(other), isNull);
    }
    expect(videoSearchUrl('YouTube', 'birds & rain').queryParameters,
        {'search_query': 'birds & rain'});
    expect(videoSearchUrl('TikTok', 'birds & rain').queryParameters,
        {'q': 'birds & rain'});
  });

  test('a linked source must be credited by the specific Commons file', () {
    const id = 'BqOo6RKxKEA';
    final link = VideoSourceLink.parse('https://youtu.be/$id')!;
    Map page(String source, String title, int index) => {
          'title': 'File:$title',
          'index': index,
          'revisions': [
            {
              'slots': {
                'main': {'content': source}
              }
            }
          ],
          'imageinfo': [
            {
              'url':
                  'https://upload.wikimedia.org/wikipedia/commons/a/a0/test.webm',
              'mime': 'video/webm',
              'descriptionurl':
                  'https://commons.wikimedia.org/wiki/File:$title',
              'size': 20,
              'extmetadata': {
                'Artist': {'value': '<b>Birds &amp; Bees</b>'},
                'LicenseShortName': {'value': 'CC BY 4.0'}
              }
            }
          ],
        };
    final input = {
      'query': {
        'pages': [
          page('|source=[https://youtu.be/$id direct]', 'Linked', 2),
          page('|source={{From YouTube|1=$id|2=Birds}}', 'Template', 1),
          page('|description=https://youtu.be/$id\n|source=Own work',
              'Unrelated', 0),
          page('|source=Own work\n|author=https://youtu.be/$id', 'Profile', 3),
        ]
      }
    };
    final hits = parseCommonsResults(input, source: link);
    expect(hits.map((e) => e.title), ['Template', 'Linked']);
    expect(hits.first.credit, contains('Birds & Bees'));
    expect(hits.first.credit, contains('CC BY 4.0'));
    final tik = VideoSourceLink.parse(
        'https://www.tiktok.com/@user/video/1234567890123456789')!;
    expect(parseCommonsResults(input, source: tik), isEmpty);
    expect(
        parseCommonsResults({
          'query': {
            'pages': [
              page('|source=[${tik.url} Original video]', 'TikTok original', 1)
            ]
          }
        }, source: tik)
            .single
            .title,
        'TikTok original');
    expect(parseCommonsResults({}), isEmpty);
    expect(
        () => parseCommonsResults({
              'error': {'code': 'ratelimited'}
            }),
        throwsFormatException);
  });
}
