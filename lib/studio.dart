import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio.dart';
import 'audio_codecs.dart';
import 'model.dart';
import 'preview.dart';

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
  late final preview = Preview(
      onPosition: _alignTake,
      onStopped: (frame) {
        cursor = frame;
        onTransportChanged?.call();
      },
      onError: (e) => playbackError = 'Playback stopped. $e');
  void Function()? onTransportChanged;
  final recorder = AudioRecorder();
  late Directory root, cache;
  late Mix mix;
  int cursor = 0;
  bool recording = false;
  final _takeClock = Stopwatch();
  int _takeStart = 0, _leadFrames = 0;
  bool _timedTake = false;
  File? _exportRender;
  bool initialized = false;
  String? playbackError;
  late AudioSession session;
  String get assets => '${root.path}/audio';
  Directory get sessions => Directory('${root.path}/sessions');
  bool get playing => preview.playing;
  void _alignTake(int shown) {
    if (!recording || _timedTake || shown <= _takeStart) return;
    final elapsed = _takeClock.elapsedMicroseconds * sampleRate ~/ 1000000;
    _leadFrames = (elapsed - (shown - _takeStart)).clamp(0, elapsed);
    _timedTake = true;
  }

  int get liveFrame {
    if (recording) {
      if (!_timedTake) return _takeStart;
      final elapsed = _takeClock.elapsedMicroseconds * sampleRate ~/ 1000000;
      return _takeStart + math.max(0, elapsed - _leadFrames);
    }
    return playing ? preview.frame : cursor;
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
    final previous = _exportRender;
    _exportRender = null;
    if (previous != null && await previous.exists()) await previous.delete();
  }

  Future<void> save() async {
    preview.revise(mix);
    await _invalidate();
    final path = '${sessions.path}/${mix.id}.json';
    final pending = File('$path.tmp');
    await pending.writeAsString(jsonEncode(mix.toJson()), flush: true);
    await pending.rename(path);
  }

  /// Audition a draft in the running transport without committing source edits.
  void audition(Clip? draft) {
    if (!playing) return;
    if (draft == null) {
      preview.revise(mix);
      return;
    }
    preview.revise(Mix(mix.id, mix.name, [
      for (final clip in mix.clips) clip.id == draft.id ? draft : clip,
    ]));
  }

  Future<void> open(String id) async {
    final data = await File('${sessions.path}/$id.json').readAsString();
    await pause();
    mix = Mix.fromJson(jsonDecode(data));
    cursor = 0;
    await _invalidate();
    await _markActive();
  }

  Future<void> create(String name) async {
    await pause();
    mix = Mix(makeId(), name, []);
    cursor = 0;
    await save();
    await _markActive();
  }

  Future<File> rendered() async {
    if (_exportRender != null && await _exportRender!.exists())
      return _exportRender!;
    final file = File('${cache.path}/mix-${makeId()}.wav');
    try {
      await compute(_render, (assets, mix, file.path));
    } catch (_) {
      final partial = File('${file.path}.part');
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    _exportRender = file;
    return file;
  }

  Future<File> exportMix(ExportSettings settings) async {
    final mixdown = await rendered();
    final dir = await Directory('${cache.path}/exports/${mix.id}')
        .create(recursive: true);
    final file = File('${dir.path}/${settings.fileName(mix.name)}');
    return writeExport(mixdown, file, settings);
  }

  Future<void> play() async {
    if (mix.end == 0)
      throw const FormatException('Add a layer to play this session.');
    if (cursor >= mix.end) cursor = 0;
    if (!await session.setActive(true))
      throw const FormatException('Audio output is busy. Try again.');
    await preview.play(assets, mix, cursor);
  }

  Future<void> pause() async {
    if (playing) cursor = await preview.pause();
  }

  Future<void> seek(int frame) async {
    cursor = frame.clamp(0, mix.end);
    if (playing) await preview.play(assets, mix, cursor);
  }

  Future<Clip> _import(
      String path, String name, LayerType type, int start) async {
    final id = makeId();
    final source = '$id.pcm';
    final out = File('$assets/$source');
    try {
      final frames = await decodeToPcm(File(path), out);
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
              // audio_session owns focus so the recorder and backing player
              // do not interrupt each other on Android.
              audioInterruption: AudioInterruptionMode.none,
              autoGain: false,
              echoCancel: false,
              noiseSuppress: false),
          path: path);
      _takeClock.reset();
      _takeClock.start();
      _timedTake = !hasBed;
      _leadFrames = 0;
      recording = true;
      if (hasBed) await preview.play(assets, mix, cursor);
    } catch (_) {
      if (recording) {
        recording = false;
        _takeClock.stop();
        await recorder.cancel();
        await preview.pause();
      }
      await session.configure(const AudioSessionConfiguration.music());
      rethrow;
    }
  }

  Future<void> finishTake() async {
    _takeClock.stop();
    recording = false;
    final path = await recorder.stop();
    await preview.pause();
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
    await preview.dispose();
    await recorder.dispose();
  }
}
