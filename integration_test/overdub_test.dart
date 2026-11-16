import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';
import 'package:integration_test/integration_test.dart';

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
    await studio.seek(at);
    await studio.record();
    expect(studio.recording, isTrue);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (studio.player.position < Studio.durationAt(at + frameAt(.5)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // The editor polls this value to align the take to the playback clock.
      studio.liveFrame;
    }
    expect(studio.player.position, greaterThan(Studio.durationAt(at)));
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
    expect(bytes.length, 44 + studio.mix.end * 4);

    // Exercise the same native channel used by the device file picker.
    final output = File('${studio.cache.path}/roundtrip-${makeId()}.pcm');
    final frames =
        await const MethodChannel('innerwave/audio').invokeMethod<int>(
      'decode',
      {'input': mix.path, 'output': output.path},
    );
    expect(frames, studio.mix.end);
    final pcm = ByteData.sublistView(await output.readAsBytes());
    expect(pcm.lengthInBytes, bytes.length - 44);
    var maxError = 0;
    for (int i = 0; i < pcm.lengthInBytes; i += 274) {
      final difference = (pcm.getInt16(i, Endian.little) -
              header.getInt16(44 + i, Endian.little))
          .abs();
      if (difference > maxError) maxError = difference;
    }
    expect(maxError, lessThanOrEqualTo(4));
    await output.delete();
  });
}
