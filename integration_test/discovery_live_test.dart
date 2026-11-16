// Optional network smoke test. The regular mobile suite uses offline fixtures.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:innerwave_studio/discovery.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';
import 'package:innerwave_studio/video_links.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerLiveDiscoveryTest();
}

void registerLiveDiscoveryTest() {
  testWidgets(
      'find public YouTube and TikTok source copies and play their audio',
      (tester) async {
    final studio = Studio();
    final client = DiscoveryClient();
    addTearDown(client.close);
    addTearDown(studio.dispose);
    await studio.init();
    final original = studio.mix.id;
    addTearDown(() => studio.open(original));
    await studio.create('Discover video compatibility test');
    final project = studio.mix.id;
    for (final sample in [
      (
        'https://youtu.be/BqOo6RKxKEA',
        '2023-08-18 ZOO LJUBLJANA - birds 5.webm',
        10.7
      ),
      (
        'https://www.tiktok.com/@.c1nd3r/video/7524797848240655671',
        'Wikipe-tan - Wow! Amazing!.webm',
        24.04
      ),
    ]) {
      final source = VideoSourceLink.parse(sample.$1)!;
      final copies = await client.findCopies(source);
      final media = copies.firstWhere((item) => item.title == sample.$2);
      final local = await client.download(media, studio.cache);
      final at = studio.mix.end;
      try {
        final clip = await studio.importMedia(
            local, media.title, LayerType.texture, at,
            credit: media.credit);
        expect(clip.frames / sampleRate, closeTo(sample.$3, .2));
        expect(clip.peaks.any((peak) => peak > .001), isTrue);
        await studio.open(project);
        expect(studio.mix.clips.last.credit,
            contains(media.sourcePage.toString()));
        await studio.seek(at);
        await studio.play();
        for (var i = 0; i < 100 && studio.liveFrame <= at; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(studio.liveFrame, greaterThan(at));
        await studio.pause();
        print(
            '${source.platform}: ${media.title}, ${clip.frames} stereo frames at ${clip.start}, playback verified');
      } finally {
        await local.delete();
      }
    }
    expect(await (await studio.rendered()).length(),
        44 + studio.mix.atRate(studio.mix.masterRate).end * 16);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
