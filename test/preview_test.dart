import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/audio.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Clip voice;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('innerwave-live-');
    const frames = sampleRate * 2;
    final samples = ByteData(frames * frameBytes);
    for (int i = 0; i < frames; i++) {
      samples.setInt16(
          i * 4, (7800 * math.sin(i * .013)).round(), Endian.little);
      samples.setInt16(
          i * 4 + 2, (3900 * math.sin(i * .019)).round(), Endian.little);
    }
    File('${dir.path}/voice.pcm')
        .writeAsBytesSync(samples.buffer.asUint8List());
    voice = Clip(
        id: 'take',
        source: 'voice.pcm',
        name: 'My take',
        type: LayerType.voice,
        frames: frames,
        length: frames - 500,
        start: 1000,
        trim: 500,
        peaks: [.2, .3],
        gain: -2,
        warmth: 7,
        presence: -4);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('streamed blocks and mid-voice seek match offline stereo render', () {
    final mix = Mix('id', 'Mix', [voice]);
    final path = '${dir.path}/mix.wav';
    renderMix(dir.path, mix, path);
    final wav = File(path).readAsBytesSync();
    final reader = MixReader(dir.path, mix, 0);
    try {
      while (reader.position < reader.end) {
        final offset = 44 + reader.position * 4;
        final part = reader.read(1937);
        expect(part, wav.sublist(offset, offset + part.length));
      }
    } finally {
      reader.close();
    }
    const seek = 45000;
    final mid = MixReader(dir.path, mix, seek);
    try {
      final got = ByteData.sublistView(mid.read(2048));
      final expected = ByteData.sublistView(wav);
      for (int p = 0; p < got.lengthInBytes; p += 2) {
        expect(
            got.getInt16(p, Endian.little),
            closeTo(
                expected.getInt16(44 + seek * frameBytes + p, Endian.little),
                1));
      }
    } finally {
      mid.close();
    }
  });

  test(
      'the device queue adopts edits, repositions on seek, and renders no file',
      () async {
    const channel = MethodChannel('innerwave/preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final writes = <Uint8List>[];
    var starts = 0, stops = 0, nativeHead = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          starts++;
          nativeHead = 0;
          writes.add(call.arguments as Uint8List);
        case 'write':
          writes.add(call.arguments as Uint8List);
        case 'position':
          return nativeHead;
        case 'stop':
          stops++;
          return nativeHead;
        default:
          throw UnsupportedError(call.method);
      }
      return null;
    });
    final errors = <Object>[];
    final transport =
        Preview(onPosition: (_) {}, onStopped: (_) {}, onError: errors.add);
    try {
      final mix = Mix('id', 'Test', [voice]);
      await transport.play(dir.path, mix, 1000);
      expect(writes.first.any((n) => n != 0), isTrue);
      expect(writes.first.length, 4096 * frameBytes);
      voice.muted = true;
      transport.revise(mix);
      nativeHead = 2000;
      final timeout = DateTime.now().add(const Duration(seconds: 3));
      while (writes.length < 2 && DateTime.now().isBefore(timeout)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(writes.last.every((n) => n == 0), isTrue);
      expect(starts, 1);
      expect(stops, 0);
      expect(transport.frame, 3000);
      // A distant clip extends the timeline by an hour. Preview still only
      // primes one block and seeking directly to it requires no intermediate PCM.
      voice.muted = false;
      voice.start = sampleRate * 3600;
      await transport.play(dir.path, mix, voice.start);
      expect(starts, 2);
      expect(writes.last.any((n) => n != 0), isTrue);
      nativeHead = 715;
      expect(await transport.pause(), voice.start + 715);
      expect(transport.playing, isFalse);
      expect(errors, isEmpty);
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['voice.pcm']);
    } finally {
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
      'undo removal restores source, offsets, tone and position after reopening',
      () {
    final first = Clip.fromJson({...voice.toJson(), 'id': 'first'});
    final last = Clip.fromJson({...voice.toJson(), 'id': 'last'});
    final mix = Mix('id', 'Session', [first, voice, last]);
    mix.removeLayer(voice);
    final reopened = Mix.fromJson(mix.toJson());
    expect(reopened.clips.map((c) => c.id), ['first', 'last']);
    expect(reopened.restoreLayer().toJson(), voice.toJson());
    expect(reopened.clips.map((c) => c.id), ['first', 'take', 'last']);
    expect(
        Mix.fromJson({'version': 1, 'id': 'old', 'name': 'Legacy', 'clips': []})
            .removed,
        isEmpty);
  });

  test(
      'loop fills every device buffer with the unmuted timeline between A and B',
      () async {
    const channel = MethodChannel('innerwave/preview');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final blocks = <Uint8List>[];
    var head = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          head = 0;
          blocks.add(call.arguments as Uint8List);
        case 'write':
          blocks.add(call.arguments as Uint8List);
        case 'position':
        case 'stop':
          return head;
      }
      return null;
    });
    final errors = <Object>[];
    final preview =
        Preview(onPosition: (_) {}, onStopped: (_) {}, onError: errors.add);
    try {
      final muted =
          Clip.fromJson({...voice.toJson(), 'id': 'muted', 'muted': true});
      final mix = Mix('loop', 'Loop', [muted, voice]);
      for (final width in [1, 127, 5071]) {
        blocks.clear();
        const start = 4234;
        final region = (start: start, end: start + width);
        final reader = MixReader(dir.path, mix, start);
        final single = Uint8List.fromList(reader.read(width));
        reader.close();
        final offset = width ~/ 2;
        await preview.play(dir.path, mix, start + offset, loop: region);
        head = 3000;
        for (var i = 0; i < 100 && blocks.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(blocks.length, greaterThanOrEqualTo(2));
        var p = offset * frameBytes;
        for (final bytes in blocks) {
          for (final b in bytes) {
            if (single[p++ % single.length] != b)
              fail('Wrong loop sample, width $width at byte $p');
          }
        }
        expect(await preview.pause(), start + (offset + head) % width);
      }
      expect(errors, isEmpty);
    } finally {
      await preview.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
