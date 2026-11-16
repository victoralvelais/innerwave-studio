import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/discover_page.dart';
import 'package:innerwave_studio/discovery.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/video_links.dart';

// Keep filesystem futures on the widget test clock while exercising real
// directory creation and cleanup.
class _Cache extends Fake implements Directory {
  _Cache(this.directory);
  final Directory directory;
  @override
  String get path => directory.path;
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _Cache(directory.createTempSync(prefix));
  @override
  Future<bool> exists() async => directory.existsSync();
  @override
  Future<Directory> delete({bool recursive = false}) async {
    directory.deleteSync(recursive: recursive);
    return this;
  }
}

class _Client implements DiscoveryClient {
  _Client(this.lookup);
  final Future<List<DiscoveredMedia>> Function(String) lookup;
  bool closed = false;
  @override
  Future<List<DiscoveredMedia>> search(String query) => lookup(query);
  @override
  Future<List<DiscoveredMedia>> findCopies(VideoSourceLink link) =>
      lookup(link.url.toString());
  @override
  Future<File> download(DiscoveredMedia media, Directory directory,
      {void Function(int, int?)? onProgress}) async {
    onProgress?.call(10, 10);
    return File('${directory.path}/media.ogg');
  }

  @override
  void close() {
    closed = true;
  }
}

final sound = DiscoveredMedia(
    title: 'River in spring',
    creator: 'Field recordist',
    license: 'CC BY 4.0',
    sourcePage: Uri.parse('https://commons.wikimedia.org/wiki/File:River.ogg'),
    mediaUrl: Uri.parse('https://upload.wikimedia.org/test/River.ogg'),
    mimeType: 'audio/ogg',
    bytes: 2000000);

Clip imported(File _, String name, LayerType type, int at,
    {String? credit, bool Function()? cancelled, void Function()? onCommit}) {
  expect(cancelled?.call(), isFalse);
  onCommit?.call();
  return Clip(
      id: 'clip',
      source: 'clip.pcm',
      name: name,
      type: type,
      frames: 10,
      length: 10,
      start: at,
      peaks: [.2],
      credit: credit);
}

Future<void> page(WidgetTester t, DiscoverPage body,
    {void Function(Clip?)? result}) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final clip = await Navigator.push<Clip>(
                        context, MaterialPageRoute(builder: (_) => body));
                    result?.call(clip);
                  },
                  child: const Text('Find media'))))));
  await t.tap(find.text('Find media'));
  await t.pumpAndSettle();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('discover-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('cancel ignores an old search; retry can return an empty result',
      (t) async {
    final pending = Completer<List<DiscoveredMedia>>();
    final calls = <_Client>[];
    final answers = <Future<List<DiscoveredMedia>> Function()>[
      () => pending.future,
      () async => throw const FormatException('Connection lost'),
      () async => [],
    ];
    await page(
        t,
        DiscoverPage(
            at: 0,
            cache: tmp,
            importMedia: (f, n, k, a, {credit, cancelled, onCommit}) async =>
                imported(f, n, k, a,
                    credit: credit, cancelled: cancelled, onCommit: onCommit),
            clientFactory: () {
              final next = answers[calls.length];
              final c = _Client((_) => next());
              calls.add(c);
              return c;
            }),
        result: (_) {});
    await t.enterText(find.byType(TextField), 'rain');
    await t.pump();
    await t.tap(find.text('Search Wikimedia Commons'));
    await t.pump();
    await t.ensureVisible(find.text('Cancel'));
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(calls.first.closed, isTrue);
    pending.complete([sound]);
    await t.pump();
    expect(find.text(sound.title), findsNothing);
    await t.ensureVisible(find.text('Search Wikimedia Commons'));
    await t.tap(find.text('Search Wikimedia Commons'));
    await t.pumpAndSettle();
    expect(find.text('Connection lost'), findsOneWidget);
    await t.ensureVisible(find.text('Retry'));
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.textContaining('No audio or video found'), findsOneWidget);
  });

  for (final platform in ['YouTube', 'TikTok']) {
    testWidgets(
        '$platform link opens officially and imports a saved video at the captured playhead',
        (t) async {
      final url = platform == 'YouTube'
          ? 'https://youtu.be/jNQXAC9IVRw?t=1'
          : 'https://www.tiktok.com/@maker/video/1234567890?tracking=foo';
      final sanitized = VideoSourceLink.parse(url)!.url;
      final requests = <String>[], opened = <Uri>[], picked = <bool>[];
      Clip? result;
      await page(
          t,
          DiscoverPage(
              at: frameAt(2.5),
              cache: tmp,
              clientFactory: () => _Client((q) async {
                    requests.add(q);
                    return [];
                  }),
              pickVideo: (gallery) async {
                picked.add(gallery);
                return PlatformFile(
                    name: 'My video.mp4', path: 'source.mp4', size: 20);
              },
              openLink: (u) async {
                opened.add(u);
                return true;
              },
              importMedia: (f, n, k, a, {credit, cancelled, onCommit}) async =>
                  imported(f, n, k, a,
                      credit: credit,
                      cancelled: cancelled,
                      onCommit: onCommit)),
          result: (c) => result = c);
      await t.enterText(find.byType(TextField), url);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(requests, [sanitized.toString()]);
      expect(find.textContaining('No matching copy'), findsOneWidget);
      final openButton = find.text('Open on $platform');
      await t.ensureVisible(openButton);
      await t.tap(openButton);
      await t.pump();
      expect(opened, [sanitized]);
      final gallery = platform == 'TikTok';
      final pickButton = find.text(gallery ? 'Photos / Gallery' : 'Files');
      await t.ensureVisible(pickButton);
      await t.tap(pickButton);
      await t.pumpAndSettle();
      await t.tap(find.text(LayerType.voice.label));
      await t.pumpAndSettle();
      expect(picked, [gallery]);
      expect(result!.start, frameAt(2.5));
      expect(result!.type, LayerType.voice);
      expect(result!.name, 'My video');
      expect(Clip.fromJson(result!.toJson()).credit, '$platform\n$sanitized');
    });
  }

  for (final source in [null, 'https://youtu.be/jNQXAC9IVRw']) {
    testWidgets(
        'direct ${source == null ? 'keyword' : 'platform copy'} import retains credit and removes its download',
        (t) async {
      Clip? result;
      String? input;
      await page(
          t,
          DiscoverPage(
              at: 4000,
              cache: _Cache(tmp),
              clientFactory: () => _Client((_) async => [sound]),
              importMedia: (f, n, k, a, {credit, cancelled, onCommit}) async {
                input = f.path;
                return imported(f, n, k, a,
                    credit: credit, cancelled: cancelled, onCommit: onCommit);
              }),
          result: (c) => result = c);
      if (source == null) {
        await t.tap(find.text('Rain'));
      } else {
        await t.enterText(find.byType(TextField), source);
        await t.pump(const Duration(milliseconds: 400));
      }
      await t.pumpAndSettle();
      await t.ensureVisible(find.text(sound.title));
      await t.tap(find.text(sound.title));
      await t.pumpAndSettle();
      await t.tap(find.text(LayerType.texture.label));
      await t.pumpAndSettle();
      expect(
          result?.credit,
          source == null
              ? sound.credit
              : '${sound.credit}\nYouTube source: ${VideoSourceLink.parse(source)!.url}');
      expect(result?.start, 4000);
      expect(result?.type, LayerType.texture);
      expect(input, isNotNull);
      expect(File(input!).parent.existsSync(), isFalse);
    });
  }
  testWidgets('cancel during extraction prevents committing a saved video',
      (t) async {
    final decoding = Completer<void>();
    var committed = false;
    bool Function()? isCancelled;
    await page(
        t,
        DiscoverPage(
            at: 0,
            cache: tmp,
            pickVideo: (_) async =>
                PlatformFile(name: 'sample.mov', path: 'source.mov', size: 4),
            importMedia: (f, n, k, a, {credit, cancelled, onCommit}) async {
              isCancelled = cancelled;
              await decoding.future;
              if (cancelled!()) throw StateError('Cancelled');
              committed = true;
              return imported(f, n, k, a,
                  credit: credit, cancelled: cancelled, onCommit: onCommit);
            }));
    await t.tap(find.text('Files'));
    await t.pumpAndSettle();
    await t.tap(find.text(LayerType.texture.label));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.ensureVisible(find.text('Cancel'));
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(isCancelled!.call(), isTrue);
    decoding.complete();
    await t.pumpAndSettle();
    expect(committed, isFalse);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Discover'), findsOneWidget);
  });
}
