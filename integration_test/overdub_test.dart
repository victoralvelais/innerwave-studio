import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/audio_codecs.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';
import 'package:integration_test/integration_test.dart';
import 'video_file_checks.dart';
import 'stereo_checks.dart';
import 'discovery_live_test.dart' show registerLiveDiscoveryTest;

// The first second of the starter mix contains a different tone in each ear.
double tonePower(ByteData pcm, int channel, int hz) {
  final coefficient = 2 * math.cos(2 * math.pi * hz / sampleRate);
  var last = 0.0, prior = 0.0;
  for (var frame = sampleRate ~/ 2; frame < sampleRate * 3 ~/ 2; frame++) {
    final x = pcm.getInt16(frame * 4 + channel * 2, Endian.little);
    final next = x + coefficient * last - prior;
    prior = last;
    last = next;
  }
  return last * last + prior * prior - coefficient * last * prior;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('overdub on the stereo bed, reopen the session, export the mix',
      (tester) async {
    final studio = Studio();
    addTearDown(studio.dispose);
    await studio.init();
    final session = studio.mix.id;
    final before = studio.mix.clips.length;
    final at = frameAt(3);
    final texture =
        studio.mix.clips.firstWhere((c) => c.type == LayerType.texture);
    final source = File('${studio.assets}/${texture.source}');
    final sourceBefore = await source.readAsBytes();
    final originalStart = texture.start;
    await studio.seek(at);
    await studio.play();
    final playDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (studio.liveFrame < at + frameAt(.25) &&
        DateTime.now().isBefore(playDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(studio.liveFrame, greaterThan(at));
    texture.start = frameAt(5);
    await studio.save();
    expect(studio.playing, isTrue);
    await studio.seek(frameAt(7));
    expect(studio.playing, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await studio.pause();
    expect(studio.cursor, greaterThanOrEqualTo(frameAt(7)));
    await studio.open(session);
    final reopened = studio.mix.clips.firstWhere((c) => c.id == texture.id);
    expect(reopened.start, frameAt(5));
    expect(listEquals(await source.readAsBytes(), sourceBefore), isTrue);
    expect(
        await studio.cache.list().any((f) => f.path.endsWith('.wav')), isFalse,
        reason:
            'Live playback and edits must work before any WAV is rendered.');
    reopened.start = originalStart;
    await studio.save();
    await studio.seek(at);
    await studio.record();
    expect(studio.recording, isTrue);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (studio.liveFrame < at + frameAt(.5) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(studio.liveFrame, greaterThan(at));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await studio.finishTake();
    expect(studio.recording, isFalse);
    await studio.open(session);
    expect(studio.mix.clips.length, before + 1);
    final voice = studio.mix.clips.last;
    expect(voice.type, LayerType.voice);
    expect(voice.start, at);
    expect(voice.length, greaterThan(frameAt(.3)));
    final mix = await studio.rendered();
    final bytes = await mix.readAsBytes();
    final header = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
    expect(header.getUint16(22, Endian.little), 2);
    expect(header.getUint32(24, Endian.little), 44100);
    expect(bytes.length, 44 + studio.mix.end * 16);

    // Exercise the same normalizer used for files selected on the phone.
    final output = File('${studio.cache.path}/roundtrip-${makeId()}.pcm');
    final frames = await decodeToPcm(mix, output);
    expect(frames, studio.mix.end);
    final pcm = ByteData.sublistView(await output.readAsBytes());
    expect(pcm.lengthInBytes, (bytes.length - 44) ~/ 4);
    var maxError = 0;
    for (int i = 0; i < pcm.lengthInBytes; i += 274) {
      final difference = (pcm.getInt16(i, Endian.little) -
              (header.getFloat64(44 + i * 4, Endian.little) * 32768)
                  .round()
                  .clamp(-32768, 32767))
          .abs();
      if (difference > maxError) maxError = difference;
    }
    expect(maxError, lessThanOrEqualTo(4));
    await output.delete();

    final codecs = {
      ExportFormat.wav: 'pcm_f64le',
      ExportFormat.mp3: 'mp3',
      ExportFormat.aac: 'aac',
      ExportFormat.vorbis: 'vorbis',
    };
    for (final entry in codecs.entries) {
      final file = await studio.exportMix(ExportSettings(entry.key, kbps: 320));
      final probe = await FFprobeKit.getMediaInformation(file.path);
      final stream = probe.getMediaInformation()!.getStreams().single;
      expect(stream.getCodec(), entry.value);
      expect(stream.getSampleRate(), '44100');
      expect(stream.getNumberProperty('channels'), 2);
      if (entry.key == ExportFormat.mp3) expect(stream.getBitrate(), '320000');
      if (entry.key == ExportFormat.aac)
        // FFprobe's small build reports the AV_PROFILE_AAC_LOW numeric ID.
        expect(stream.getProperty('profile').toString(), isIn(['LC', '1']));
      if (entry.key == ExportFormat.vorbis)
        expect(stream.getBitrate(), '320000');
      final length = await decodeToPcm(file, output);
      expect((length - frames).abs(), lessThanOrEqualTo(2048));
      final decoded = ByteData.sublistView(await output.readAsBytes());
      expect(tonePower(decoded, 0, 180),
          greaterThan(8 * tonePower(decoded, 0, 186)));
      expect(tonePower(decoded, 1, 186),
          greaterThan(8 * tonePower(decoded, 1, 180)));
      await output.delete();
    }
  });
  registerVideoFileChecks();
  registerStereoChecks();
  if (const bool.fromEnvironment('TEST_LIVE_SOURCES'))
    registerLiveDiscoveryTest();
}
