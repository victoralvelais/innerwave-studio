import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/main.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';

// Include both single-LSB 24-bit values and a signal above the bandwidth
// of a 44.1 kHz editor. The odd frame count catches duration rounding.
Uint8List _source() {
  const frames = 96003, rate = 96000, stride = 6;
  final data = ByteData(44 + frames * stride);
  for (final tag in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(tag.key + i, tag.value.codeUnitAt(i));
    }
  }
  void u32(int i, int v) => data.setUint32(i, v, Endian.little);
  void u16(int i, int v) => data.setUint16(i, v, Endian.little);
  u32(4, data.lengthInBytes - 8);
  u32(16, 16);
  u16(20, 1);
  u16(22, 2);
  u32(24, rate);
  u32(28, rate * stride);
  u16(32, stride);
  u16(34, 24);
  u32(40, frames * stride);
  for (var i = 0; i < frames; i++) {
    final pair = [
      i.isEven ? 1 : -1,
      (4000000 * math.sin(2 * math.pi * 30000 * i / rate)).round() + 3
    ];
    for (var ch = 0; ch < 2; ch++) {
      final o = 44 + i * 6 + ch * 3;
      for (var b = 0; b < 3; b++) {
        data.setUint8(o + b, (pair[ch] >> (8 * b)) & 255);
      }
    }
  }
  return data.buffer.asUint8List();
}

void registerStereoChecks() {
  testWidgets(
      'preserve all 96 kHz, 24-bit samples and route different layers independently',
      (tester) async {
    final studio = Studio();
    addTearDown(studio.dispose);
    await studio.init();
    final previous = studio.mix.id;
    addTearDown(() => studio.open(previous));
    await studio.create('Full precision');
    final project = studio.mix.id;
    final source = File('${studio.cache.path}/precision-${makeId()}.wav');
    final original = _source();
    await source.writeAsBytes(original);
    addTearDown(source.delete);
    final clip =
        await studio.importMedia(source, '96 kHz stereo', LayerType.texture, 0);
    expect(await File('${studio.assets}/${clip.original}').readAsBytes(),
        orderedEquals(original));
    final master =
        ByteData.sublistView(await (await studio.rendered()).readAsBytes());
    expect(master.getUint32(24, Endian.little), 96000);
    expect(master.getUint16(34, Endian.little), 64);
    expect(master.lengthInBytes, 44 + 96003 * 16);
    for (var i = 0; i < 96003 * 2; i++) {
      final o = 44 + i * 3;
      final integer =
          (original[o] | original[o + 1] << 8 | original[o + 2] << 16)
              .toSigned(24);
      if (master.getFloat64(44 + i * 8, Endian.little) != integer / 8388608) {
        fail('PCM mismatch at frame ${i ~/ 2}, channel ${i % 2}');
      }
    }
    await studio.setIndependent(LayerType.texture, true);
    studio.mix.clips[0] = clip.copyWith(ear: EarRoute.right);
    final voice = Clip.fromJson(
        {...clip.toJson(), 'id': 'left', 'type': 'voice', 'ear': 'left'});
    studio.mix.clips.add(voice);
    await studio.setIndependent(LayerType.voice, true);
    await studio.setLoopRange(frameAt(.01), frameAt(.04));
    await studio.setLoop(true);
    await studio.play();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(studio.playing, isTrue);
    expect(studio.liveFrame, inInclusiveRange(frameAt(.01), frameAt(.04) - 1));
    voice.muted = true;
    await studio.save();
    await studio.pause();
    final routed =
        ByteData.sublistView(await (await studio.rendered()).readAsBytes());
    expect(routed.lengthInBytes, master.lengthInBytes);
    for (var i = 0; i < 512; i++) {
      expect(routed.getFloat64(44 + 16 * i, Endian.little), 0);
      expect(
          routed.getFloat64(52 + 16 * i, Endian.little),
          (master.getFloat64(44 + 16 * i, Endian.little) +
                  master.getFloat64(52 + 16 * i, Endian.little)) /
              2);
    }
    await studio.open(project);
    expect(studio.mix.independent(LayerType.beat), isFalse);
    expect(studio.mix.independent(LayerType.texture), isTrue);
    expect(studio.mix.independent(LayerType.voice), isTrue);
    expect(studio.mix.clips.last.muted, isTrue);
    expect(studio.loopEnabled, isFalse);
  });

  testWidgets(
      'drag a track fader during loop playback and reopen its saved gain',
      (tester) async {
    final studio = Studio();
    addTearDown(studio.dispose);
    await studio.init();
    final previous = studio.mix.id;
    addTearDown(() => studio.open(previous));
    await studio.create('Fader gesture');
    final project = studio.mix.id;
    final selected =
        await studio.addTone(const BeatTone(), frameAt(2), gainDb: 0);
    final muted =
        await studio.addTone(const BeatTone(), frameAt(2), gainDb: -10);
    muted.muted = true;
    await studio.save();
    await tester.pumpWidget(const InnerwaveApp());
    final slider = find.byKey(ValueKey('volume-${selected.id}'));
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(finder, findsOneWidget);
    }

    await waitFor(slider);
    await tester.ensureVisible(find.byKey(const ValueKey('loop-playback')));
    await tester.tap(find.byKey(const ValueKey('loop-playback')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play mix'));
    await waitFor(find.byTooltip('Pause mix'));
    await tester.ensureVisible(slider);
    final rect = tester.getRect(slider);
    final gesture =
        await tester.startGesture(Offset(rect.right - 25, rect.center.dy));
    await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('Pause mix'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Pause mix'));
    await tester.tap(find.byTooltip('Pause mix'));
    await waitFor(find.byTooltip('Play mix'));
    await tester.pumpWidget(const SizedBox.shrink());
    await studio.open(project);
    final edited = studio.mix.clips.first;
    expect(edited.gain, lessThan(-5));
    expect(edited.muted, isFalse);
    expect(studio.mix.clips.last.gain, -10);
    expect(studio.mix.clips.last.muted, isTrue);
    final wave =
        ByteData.sublistView(await (await studio.rendered()).readAsBytes());
    final expected = .4 *
        math.pow(10, edited.gain / 20) *
        math.sin(2 * math.pi * 248 * 1000 / sampleRate);
    expect(wave.getFloat64(44 + 16 * 1000, Endian.little),
        closeTo(expected, 1e-10));
  });
}
