import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';

Future<void> _mux(List<String> args) async {
  final command = await FFmpegKit.executeWithArguments(
      ['-nostdin', '-loglevel', 'error', '-y', ...args]);
  expect(ReturnCode.isSuccess(await command.getReturnCode()), isTrue,
      reason: await command.getOutput());
}

void registerVideoFileChecks() {
  testWidgets(
      'import saved MP4 videos at the playhead; a silent video leaves the session intact',
      (tester) async {
    final studio = Studio();
    addTearDown(studio.dispose);
    await studio.init();
    final initial = studio.mix.id;
    addTearDown(() => studio.open(initial));
    await studio.create('Saved video import');
    final project = studio.mix.id;
    final directory = await studio.cache.createTemp('mp4-check-');
    addTearDown(() => directory.delete(recursive: true));

    // One original black H.264 frame per orientation. All test audio is
    // synthesized on the device; these compact fixtures stay out of the app.
    const frames = [
      (
        'landscape',
        'AAAAAWdCwAraEWwEQAAAAwBAAAADAIPEiagAAAABaM4PyAAAAWWIhDomKAAJAsnJyddddeA=',
        2
      ),
      (
        'portrait',
        'AAAAAWdCwAraImwEQAAAAwBAAAADAIPEiagAAAABaM4PyAAAAWWIhDomKAAJAsnXXXXXXg==',
        1
      )
    ];
    for (final frame in frames) {
      final raw = File('${directory.path}/${frame.$1}.h264');
      await raw.writeAsBytes(base64Decode(frame.$2));
      final mp4 = File('${directory.path}/${frame.$1}.mp4');
      await _mux([
        '-r',
        '1',
        '-f',
        'h264',
        '-i',
        raw.path,
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=400:sample_rate=48000:duration=0.8',
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c:v',
        'copy',
        '-c:a',
        'aac',
        '-ac',
        frame.$3.toString(),
        '-movflags',
        '+faststart',
        mp4.path
      ]);
      final before = await mp4.readAsBytes();
      final at = frameAt(1) + studio.mix.end;
      final clip =
          await studio.importMedia(mp4, frame.$1, LayerType.texture, at);
      expect(clip.frames, closeTo(frameAt(.8), 2048));
      expect(clip.peaks.any((p) => p > .01), isTrue);
      expect(await mp4.readAsBytes(), before);
      await studio.open(project);
      expect(studio.mix.clips.last.start, at);
      final rendered =
          ByteData.sublistView(await (await studio.rendered()).readAsBytes());
      expect(rendered.getUint32(24, Endian.little), sampleRate);
      expect(rendered.getUint16(22, Endian.little), 2);
      final start = 44 + at * frameBytes;
      expect(rendered.getInt16(start - frameBytes, Endian.little), 0);
      for (final channel in [0, 2]) {
        expect(
            [
              for (var f = 2200; f < 2300; f++)
                rendered
                    .getInt16(start + frameBytes * f + channel, Endian.little)
                    .abs()
            ].reduce((a, b) => a > b ? a : b),
            greaterThan(500));
      }
    }
    final silent = File('${directory.path}/silent.mp4');
    await _mux([
      '-i',
      '${directory.path}/portrait.mp4',
      '-map',
      '0:v:0',
      '-c',
      'copy',
      silent.path
    ]);
    final count = studio.mix.clips.length;
    final sources = await Directory(studio.assets).list().length;
    await expectLater(studio.importMedia(silent, 'Silent', LayerType.beat, 0),
        throwsFormatException);
    expect(studio.mix.clips.length, count);
    expect(await Directory(studio.assets).list().length, sources);
  });
}
