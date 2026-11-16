import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio.dart';
import 'model.dart';

void _render((String, Mix, String) args) =>
    renderMix(args.$1, args.$2, args.$3);
List<double> _peaks((String, int) args) => readPeaks(args.$1, args.$2);

Mix _seed((String, String) args) {
  final clips = <Clip>[];
  for (final kind in [LayerType.beat, LayerType.texture]) {
    final beat = kind == LayerType.beat;
    final file = beat ? 'dusk-carrier.pcm' : 'rain-on-glass.pcm';
    final path = '${args.$1}/$file';
    final length = (beat ? 24 : 20) * sampleRate;
    generateStarter(path, kind, length);
    clips.add(Clip(
        id: makeId(),
        source: file,
        name: beat ? 'Dusk carrier · 6 Hz' : 'Rain on glass',
        type: kind,
        frames: length,
        peaks: readPeaks(path, length),
        length: length,
        start: beat ? 0 : frameAt(2),
        gain: beat ? -9 : -4));
  }
  return Mix(args.$2, 'Night Current', clips);
}

class Studio {
  static const _decode = MethodChannel('innerwave/audio');
  final player = AudioPlayer(handleInterruptions: false);
  final recorder = AudioRecorder();
  late Directory root, cache;
  late Mix mix;
  int cursor = 0;
  bool recording = false;
  final _takeClock = Stopwatch();
  int _takeStart = 0, _leadFrames = 0;
  bool _timedTake = false;
  File? _preview;
  String? _loaded;
  bool initialized = false;
  String? playbackError;
  late AudioSession session;
  String get assets => '${root.path}/audio';
  Directory get sessions => Directory('${root.path}/sessions');
  bool get playing =>
      player.playing && player.processingState != ProcessingState.completed;
  int get liveFrame {
    if (recording) {
      final elapsed = (_takeClock.elapsedMicroseconds * sampleRate) ~/ 1000000;
      if (!_timedTake &&
          player.position.inMicroseconds >
              durationAt(_takeStart).inMicroseconds) {
        final delta =
            frameAt(player.position.inMicroseconds / 1e6) - _takeStart;
        _leadFrames = (elapsed - delta).clamp(0, elapsed);
        _timedTake = true;
      }
      return _takeStart + math.max(0, elapsed - _leadFrames);
    }
    if (playing)
      return frameAt(player.position.inMicroseconds / 1e6).clamp(0, mix.end);
    return cursor;
  }

  static Duration durationAt(int frame) =>
      Duration(microseconds: frame * 1000000 ~/ sampleRate);

  Future<void> init() async {
    root = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/innerwave');
    cache = await Directory('${(await getTemporaryDirectory()).path}/innerwave')
        .create(recursive: true);
    await Directory(assets).create(recursive: true);
    await sessions.create(recursive: true);
    final active = File('${root.path}/active');
    final choices = await library();
    final saved =
        await active.exists() ? (await active.readAsString()).trim() : '';
    final id =
        choices.any((m) => m.id == saved) ? saved : choices.firstOrNull?.id;
    if (id != null) {
      await open(id);
    } else {
      mix = await compute(_seed, (assets, makeId()));
      await save();
      await _markActive();
    }
    session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    initialized = true;
  }

  Future<List<Mix>> library() async {
    final entries = <(DateTime, Mix)>[];
    await for (final file in sessions.list()) {
      if (file is File && file.path.endsWith('.json')) {
        final m = Mix.fromJson(jsonDecode(await file.readAsString()));
        entries.add(((await file.stat()).modified, m));
      }
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    return entries.map((e) => e.$2).toList();
  }

  Future<void> _markActive() async {
    final pending = File('${root.path}/active.tmp');
    await pending.writeAsString(mix.id, flush: true);
    await pending.rename('${root.path}/active');
  }

  Future<void> _invalidate() async {
    if (_loaded != null) await player.stop();
    _loaded = null;
    final previous = _preview;
    _preview = null;
    if (previous != null && await previous.exists()) await previous.delete();
  }

  Future<void> save() async {
    final path = '${sessions.path}/${mix.id}.json';
    final pending = File('$path.tmp');
    await pending.writeAsString(jsonEncode(mix.toJson()), flush: true);
    await pending.rename(path);
    await _invalidate();
  }

  Future<void> open(String id) async {
    final data = await File('${sessions.path}/$id.json').readAsString();
    mix = Mix.fromJson(jsonDecode(data));
    cursor = 0;
    await _invalidate();
    await _markActive();
  }

  Future<void> create(String name) async {
    mix = Mix(makeId(), name, []);
    cursor = 0;
    await save();
    await _markActive();
  }

  Future<File> rendered() async {
    if (_preview != null && await _preview!.exists()) return _preview!;
    final file = File('${cache.path}/mix-${makeId()}.wav');
    try {
      await compute(_render, (assets, mix, file.path));
    } catch (_) {
      final partial = File('${file.path}.part');
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    _preview = file;
    return file;
  }

  Future<void> _cue(int frame) async {
    final audio = await rendered();
    if (_loaded != audio.path) {
      await player.setFilePath(audio.path);
      _loaded = audio.path;
    }
    await player.seek(durationAt(frame));
  }

  void _play() {
    unawaited(player.play().catchError((Object e) {
      playbackError = 'Playback stopped. $e';
    }));
  }

  Future<void> play() async {
    if (mix.end == 0)
      throw const FormatException('Add a layer to play this session.');
    if (cursor >= mix.end) cursor = 0;
    await _cue(cursor);
    _play();
  }

  Future<void> pause() async {
    if (playing) cursor = liveFrame;
    await player.pause();
  }

  Future<void> seek(int frame) async {
    cursor = frame.clamp(0, mix.end);
    if (_loaded != null) await player.seek(durationAt(cursor));
  }

  Future<Clip> _import(
      String path, String name, LayerType type, int start) async {
    final id = makeId();
    final source = '$id.pcm';
    final out = File('$assets/$source');
    try {
      final frames = await _decode
          .invokeMethod<int>('decode', {'input': path, 'output': out.path});
      if (frames == null || frames <= 0)
        throw const FormatException('This file has no decodable audio.');
      final peaks = await compute(_peaks, (out.path, frames));
      return Clip(
          id: id,
          source: source,
          name: name,
          type: type,
          frames: frames,
          peaks: peaks,
          length: frames,
          start: start);
    } catch (_) {
      if (await out.exists()) await out.delete();
      rethrow;
    }
  }

  Future<bool> importClip(LayerType type) async {
    await pause();
    final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'wav',
          'mp3',
          'm4a',
          'aac',
          'aif',
          'aiff',
          'flac',
          'ogg',
          'opus'
        ]);
    if (selection == null) return false;
    final file = selection.files.single;
    if (file.path == null)
      throw const FormatException(
          'Download this audio file to your device and try again.');
    final name = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    mix.clips.add(await _import(file.path!, name, type, cursor));
    await save();
    return true;
  }

  Future<void> record() async {
    await pause();
    if (!await recorder.hasPermission()) {
      throw const FormatException(
          'Microphone access is disabled. Allow it in device settings to record a take.');
    }
    _takeStart = cursor;
    final hasBed = cursor < mix.end;
    if (hasBed) await _cue(cursor);
    const attrs = AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media);
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      androidAudioAttributes: attrs,
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ));
    final path = '${cache.path}/take-${makeId()}.wav';
    try {
      if (!await session.setActive(true))
        throw const FormatException('Audio input is busy. Try again.');
      await recorder.ios?.manageAudioSession(false);
      await recorder.start(
          const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: sampleRate,
              numChannels: 1,
              autoGain: false,
              echoCancel: false,
              noiseSuppress: false),
          path: path);
      _takeClock.reset();
      _takeClock.start();
      _timedTake = !hasBed;
      _leadFrames = 0;
      recording = true;
      if (hasBed) _play();
    } catch (_) {
      await session.configure(const AudioSessionConfiguration.music());
      rethrow;
    }
  }

  Future<void> finishTake() async {
    _takeClock.stop();
    recording = false;
    final path = await recorder.stop();
    await player.pause();
    await session.configure(const AudioSessionConfiguration.music());
    if (path == null)
      throw const FormatException('The microphone returned no recording.');
    final count = mix.clips.where((c) => c.type == LayerType.voice).length + 1;
    final clip =
        await _import(path, 'Voice take $count', LayerType.voice, _takeStart);
    clip.trim = math.min(_leadFrames, clip.frames - 1);
    clip.length = clip.frames - clip.trim;
    mix.clips.add(clip);
    cursor = _takeStart;
    await save();
    final original = File(path);
    if (await original.exists()) await original.delete();
  }

  Future<void> dispose() async {
    await player.dispose();
    await recorder.dispose();
  }
}
