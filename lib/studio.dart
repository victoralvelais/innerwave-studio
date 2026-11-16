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
    if (!beat) generateStarter(path, kind, length);
    clips.add(Clip(
        id: makeId(),
        source: file,
        name: beat ? 'Dusk carrier · 6 Hz' : 'Rain on glass',
        type: kind,
        frames: length,
        tone: beat ? BeatTone.dusk : null,
        peaks: beat ? List.filled(192, 0.4) : readPeaks(path, length),
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
  int _revision = 0;
  Future<void> _saving = Future.value();
  bool _loopEnabled = false;
  LoopRange? _customLoop;
  bool get loopEnabled => _loopEnabled;
  LoopRange? get customLoopRange {
    final r = _customLoop;
    if (r == null || r.start >= mix.end) return null;
    return (start: r.start, end: math.min(r.end, mix.end));
  }

  LoopRange? get loopRange => _loopEnabled && !recording && mix.end > 0
      ? customLoopRange ?? (start: 0, end: mix.end)
      : null;
  Future<void> setLoop(bool enabled) async {
    _loopEnabled = enabled;
    audition(null);
  }

  Future<void> setLoopRange(int start, int end) async {
    if (start < 0 || start >= end || end > mix.end)
      throw const FormatException(
          'Choose an end after the start, within the timeline.');
    _customLoop = (start: start, end: end);
    audition(null);
  }

  Future<void> clearLoopRange() async {
    _customLoop = null;
    audition(null);
  }

  void _resetLoop() {
    _loopEnabled = false;
    _customLoop = null;
  }

  bool initialized = false;
  String? playbackError;
  late AudioSession session;
  String get assets => '${root.path}/audio';
  Directory get sessions => Directory('${root.path}/sessions');
  Future<void> setIndependent(LayerType layer, bool value) async {
    if (value) {
      mix.independentLayers.add(layer);
    } else {
      mix.independentLayers.remove(layer);
    }
    await save();
    if (tonePreviewing && layer == LayerType.beat)
      updateTonePreview(_tone, _toneGain);
  }

  Clip _toneClip(BeatTone tone, int frames, double gain,
          {int start = 0, int fade = 0}) =>
      Clip(
          id: makeId(),
          source: 'oscillator',
          name: 'Binaural tone',
          type: LayerType.beat,
          frames: frames,
          length: frames,
          start: start,
          tone: tone,
          gain: gain,
          peaks: List.filled(192, .4),
          fadeOut: fade);
  Future<Clip> addTone(BeatTone tone, int frames, {double gainDb = -12}) async {
    if (frames < 1)
      throw const FormatException('Choose a positive tone duration.');
    final clip = _toneClip(tone, frames, gainDb, start: cursor);
    mix.clips.add(clip);
    try {
      await save();
    } catch (_) {
      mix.clips.remove(clip);
      audition(null);
      rethrow;
    }
    return clip;
  }

  Future<Clip> restoreLayer() async {
    final removed = mix.removed.last;
    if (playing) {
      await prepareSources(assets, mix.withClips([removed.$2]), preview.rate);
    }
    final clip = mix.restoreLayer();
    try {
      await save();
    } catch (_) {
      mix.clips.remove(clip);
      mix.removed.add(removed);
      audition(null);
      rethrow;
    }
    return clip;
  }

  late final _tonePreview = Preview(
      onPosition: (_) {},
      onStopped: (_) => onTransportChanged?.call(),
      onError: (error) {
        playbackError = 'Tone preview stopped. $error';
        onTransportChanged?.call();
      });
  bool get tonePreviewing => _tonePreview.playing;
  BeatTone _tone = const BeatTone();
  double _toneGain = -12;
  Duration? _toneTimer;
  Mix get _auditionMix {
    final limit = _toneTimer ?? const Duration(hours: 24);
    final clip = _toneClip(
        _tone, frameAt(limit.inMicroseconds / 1000000), _toneGain,
        fade: _toneTimer == null ? 0 : sampleRate * 60);
    return mix.withClips([clip]);
  }

  Future<void> startTonePreview(BeatTone tone, double gainDb,
      {Duration? timer}) async {
    await pause();
    if (!await session.setActive(true))
      throw const FormatException('Audio output is busy.');
    _tone = tone;
    _toneGain = gainDb;
    _toneTimer = timer;
    await _tonePreview.play(assets, _auditionMix, 0,
        outputRate: await Preview.deviceRate());
  }

  void updateTonePreview(BeatTone tone, double gainDb) {
    _tone = tone;
    _toneGain = gainDb;
    if (tonePreviewing) _tonePreview.revise(_auditionMix);
  }

  Future<void> stopTonePreview() async {
    if (tonePreviewing) await _tonePreview.pause();
  }

  Future<List<({String name, BeatTone tone})?>> loadTonePresets() async {
    final file = File('${root.path}/tone-presets.json');
    final slots = List<({String name, BeatTone tone})?>.filled(5, null);
    if (await file.exists()) {
      final entries = jsonDecode(await file.readAsString()) as List;
      for (var i = 0; i < math.min(entries.length, slots.length); i++) {
        final item = entries[i];
        if (item != null)
          slots[i] = (
            name: item['name'] as String,
            tone: BeatTone.fromJson(item['tone'])
          );
      }
    }
    return slots;
  }

  Future<void> saveTonePreset(int index, String name, BeatTone tone) async {
    final slots = await loadTonePresets();
    slots[index] = (name: name, tone: tone);
    final file = File('${root.path}/tone-presets.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode([
          for (final s in slots)
            s == null ? null : {'name': s.name, 'tone': s.tone.toJson()}
        ]),
        flush: true);
    await tmp.rename(file.path);
  }

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

  Future<void> save() {
    _revision++;
    audition(null);
    final path = '${sessions.path}/${mix.id}.json';
    final contents = jsonEncode(mix.toJson());
    final invalidation = _invalidate();
    final next = _saving.then((_) async {
      await invalidation;
      final pending = File('$path.tmp');
      await pending.writeAsString(contents, flush: true);
      await pending.rename(path);
    });
    _saving = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Audition a draft in the running transport without committing source edits.
  void audition(Clip? draft) {
    if (!playing) return;
    if (draft == null) {
      preview.revise(mix, loop: loopRange);
      return;
    }
    preview.revise(
        mix.withClips([
          for (final clip in mix.clips) clip.id == draft.id ? draft : clip,
        ]),
        loop: loopRange);
  }

  Future<void> open(String id) async {
    await _saving;
    final data = await File('${sessions.path}/$id.json').readAsString();
    await pause();
    await stopTonePreview();
    _resetLoop();
    _revision++;
    mix = Mix.fromJson(jsonDecode(data));
    cursor = 0;
    await _invalidate();
    await _markActive();
  }

  Future<void> create(String name) async {
    await pause();
    await stopTonePreview();
    _resetLoop();
    mix = Mix(makeId(), name, []);
    cursor = 0;
    await save();
    await _markActive();
  }

  Future<File> rendered() async {
    if (_exportRender != null && await _exportRender!.exists())
      return _exportRender!;
    final file = File('${cache.path}/mix-${makeId()}.wav');
    final snapshot = Mix.fromJson(mix.toJson());
    final revision = _revision;
    try {
      await prepareSources(assets, snapshot, snapshot.masterRate);
      await compute(_render, (assets, snapshot, file.path));
    } catch (_) {
      final partial = File('${file.path}.part');
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    if (revision == _revision) _exportRender = file;
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
    await stopTonePreview();
    await _startTimeline();
  }

  Future<void> _startTimeline() async {
    final rate = mix.highPrecision ? await Preview.deviceRate() : sampleRate;
    await prepareSources(assets, mix, rate);
    await preview.play(assets, mix, cursor, loop: loopRange, outputRate: rate);
  }

  Future<void> pause() async {
    if (playing) cursor = await preview.pause();
  }

  Future<void> seek(int frame) async {
    cursor = frame.clamp(0, mix.end);
    if (playing) await _startTimeline();
  }

  Future<Clip> _import(String path, String name, LayerType type, int start,
      {String? credit, bool Function()? cancelled}) async {
    final id = makeId();
    final source = '$id.f64';
    final original = File('$assets/$id.original');
    final out = File('$assets/$source');
    try {
      await File(path).copy(original.path);
      final native = await decodeNative(original, out);
      final frames =
          math.max(1, scaleFrames(native.frames, native.rate, sampleRate));
      if (cancelled?.call() == true) throw StateError('Import cancelled.');
      final peaks = await compute(_peaks, (out.path, native.frames));
      if (cancelled?.call() == true) throw StateError('Import cancelled.');
      return Clip(
          id: id,
          source: source,
          original: '$id.original',
          gain: 0,
          sourceRate: native.rate,
          sourceFrames: native.frames,
          name: name,
          type: type,
          frames: frames,
          peaks: peaks,
          length: frames,
          credit: credit,
          start: start);
    } catch (_) {
      if (await out.exists()) await out.delete();
      if (await original.exists()) await original.delete();
      rethrow;
    }
  }

  Future<Clip> importMedia(File media, String name, LayerType type, int at,
      {String? credit,
      bool Function()? cancelled,
      void Function()? onCommit}) async {
    if (at < 0) throw ArgumentError.value(at, 'at');
    if (recording) throw StateError('Finish the voice take before importing.');
    final session = mix;
    final clip = await _import(media.path, name, type, at,
        credit: credit, cancelled: cancelled);
    Future<void> discard() async {
      for (final name in {
        clip.source,
        clip.original!,
        if (playing) clip.fileAtRate(preview.rate)
      }) {
        final f = File('$assets/$name');
        if (await f.exists()) await f.delete();
      }
    }

    if (playing) {
      try {
        await prepareSources(assets, session.withClips([clip]), preview.rate);
      } catch (_) {
        await discard();
        rethrow;
      }
    }
    if (cancelled?.call() == true || !identical(mix, session)) {
      await discard();
      throw StateError('Import cancelled.');
    }
    onCommit?.call();
    mix.clips.add(clip);
    try {
      await save();
      return clip;
    } catch (_) {
      mix.clips.remove(clip);
      audition(null);
      await discard();
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
    await importMedia(File(file.path!), name, type, cursor);
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
      if (hasBed) await _startTimeline();
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
    await _saving;
    await _tonePreview.dispose();
    await preview.dispose();
    await recorder.dispose();
  }
}
