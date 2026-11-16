import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/audio.dart';
import 'package:innerwave_studio/model.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('innerwave-audio-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Clip writeClip(String name, List<int> Function(int) sample,
      {int frames = 16000}) {
    final data = ByteData(frames * frameBytes);
    for (var i = 0; i < frames; i++) {
      final pair = sample(i);
      for (var ch = 0; ch < 2; ch++) {
        data.setInt16(i * frameBytes + 2 * ch, pair[ch], Endian.little);
      }
    }
    final path = '${dir.path}/$name.pcm';
    File(path).writeAsBytesSync(data.buffer.asUint8List());
    return Clip(
        id: name,
        name: name,
        source: '$name.pcm',
        type: LayerType.voice,
        frames: frames,
        length: frames,
        peaks: readPeaks(path, frames),
        gain: 0);
  }

  ByteData mix(List<Clip> clips) {
    final path = '${dir.path}/out.wav';
    renderMix(dir.path, Mix('test', 'Test mix', clips), path);
    return ByteData.sublistView(File(path).readAsBytesSync());
  }

  int value(ByteData wav, int frame, int channel) =>
      wav.getInt16(44 + frame * 4 + channel * 2, Endian.little);

  test('render places, trims and mixes stereo data across block boundaries',
      () {
    final first = writeClip('first', (i) => [i < 2000 ? 0 : 4096, 0])
      ..trim = 2000
      ..length = 12000
      ..start = 1000;
    final second = writeClip('second', (_) => [0, -4096])
      ..start = 6500
      ..length = 6500;
    final data = mix([first, second]);
    expect(data.lengthInBytes, 44 + 13000 * 4);
    expect(data.getUint32(24, Endian.little), sampleRate);
    expect(data.getUint16(22, Endian.little), 2);
    expect(data.getUint16(34, Endian.little), 16);
    expect(value(data, 999, 0), 0);
    expect(value(data, 1500, 0), closeTo(4096, 1));
    expect(value(data, 1500, 1), 0);
    for (final i in [8191, 8192, 8250, 12000]) {
      expect(value(data, i, 0), closeTo(4096, 1));
      expect(value(data, i, 1), closeTo(-4096, 1));
    }
    first.muted = true;
    second.gain = -6;
    final changed = mix([first, second]);
    expect(value(changed, 9000, 0), 0);
    expect(value(changed, 9000, 1), closeTo(-2053, 2));
  });

  test(
      'voice warmth boosts low-frequency content independently on each channel',
      () {
    final c = writeClip(
        'voice',
        (i) =>
            [(2000 * math.sin(2 * math.pi * 80 * i / sampleRate)).round(), 0]);
    final dry = mix([c]);
    c.warmth = 8;
    final wet = mix([c]);
    double energy(ByteData d, int ch) =>
        List.generate(4000, (i) => value(d, i + 1000, ch))
            .fold(0.0, (sum, n) => sum + n * n);
    expect(energy(wet, 0), greaterThan(energy(dry, 0) * 3));
    expect(energy(wet, 1), 0);
  });

  test('starter WAV retains the specified carrier in each ear', () {
    final path = '${dir.path}/beat.pcm';
    generateStarter(path, LayerType.beat, sampleRate * 2);
    final c = Clip(
        id: 'tone',
        name: 'Tone',
        source: 'beat.pcm',
        type: LayerType.beat,
        frames: sampleRate * 2,
        length: sampleRate * 2,
        peaks: readPeaks(path, sampleRate * 2),
        gain: 0);
    final data = mix([c]);
    int cycles(int ch) {
      var n = 0;
      for (int i = sampleRate ~/ 2; i < sampleRate * 3 ~/ 2; i++) {
        if (value(data, i, ch) <= 0 && value(data, i + 1, ch) > 0) n++;
      }
      return n;
    }

    expect(cycles(0), 180);
    expect(cycles(1), 186);
    expect(
        Mix.fromJson(Mix('test', 'Test mix', [c]).toJson())
            .clips
            .single
            .toJson(),
        c.toJson());
  });

  test(
      'linked center and independently crossed ears are synthesized at exact frequencies',
      () {
    const tone = BeatTone(base: 250, beat: 4, left: 432.12, right: 222.34);
    final c = Clip(
        id: 'tone',
        source: 'oscillator',
        name: 'tone',
        type: LayerType.beat,
        frames: sampleRate,
        length: sampleRate,
        tone: tone,
        peaks: [],
        gain: 0,
        trim: 0);
    final session = Mix('ear', 'Ear test', [c]);
    for (final separate in [false, true]) {
      if (separate) session.independentLayers.add(LayerType.beat);
      final path = '${dir.path}/beat-$separate.wav';
      renderMix(dir.path, Mix.fromJson(session.toJson()), path);
      final wav = ByteData.sublistView(File(path).readAsBytesSync());
      for (var i = 1000; i < 9000; i += 13) {
        for (var ch = 0; ch < 2; ch++) {
          final hz =
              ch == 0 ? (separate ? 432.12 : 248) : (separate ? 222.34 : 252);
          expect(wav.getFloat64(44 + 16 * i + ch * 8, Endian.little),
              closeTo(.4 * math.sin(2 * math.pi * hz * i / sampleRate), 1e-12));
        }
      }
    }
  });
}
