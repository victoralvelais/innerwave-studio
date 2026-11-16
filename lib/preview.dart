import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'audio.dart';
import 'model.dart';

// Fills a hardware buffer across timeline wraps. Very short regions are
// cached for this mix revision so even a one-frame loop avoids repeated I/O.
class _PreviewReader {
  _PreviewReader(
      this.folder, this.mix, this.at, this.loop, this.rate, this.bytes) {
    final region = loop;
    if (region != null && region.end - region.start <= Preview._firstFrames) {
      final reader =
          MixReader(folder, mix, region.start, rate: rate, outputBytes: bytes);
      try {
        _cycle = Uint8List.fromList(reader.read(region.end - region.start));
      } finally {
        reader.close();
      }
    } else {
      _reader = MixReader(folder, mix, at, rate: rate, outputBytes: bytes);
    }
  }
  final String folder;
  final int rate, bytes;
  int get stride => bytes * 2;
  final Mix mix;
  final LoopRange? loop;
  int at;
  MixReader? _reader;
  Uint8List? _cycle;

  Uint8List read(int frames) {
    final region = loop;
    if (region == null) return _reader!.read(frames);
    final out = Uint8List(frames * stride);
    var filled = 0;
    while (filled < frames) {
      if (at == region.end) {
        at = region.start;
        if (_cycle == null) {
          _reader!.close();
          _reader = MixReader(folder, mix, at, rate: rate, outputBytes: bytes);
        }
      }
      final n = math.min(frames - filled, region.end - at);
      final cycle = _cycle;
      if (cycle != null) {
        out.setRange(filled * stride, (filled + n) * stride, cycle,
            (at - region.start) * stride);
      } else {
        out.setRange(filled * stride, (filled + n) * stride, _reader!.read(n));
      }
      at += n;
      filled += n;
    }
    return out;
  }

  void close() => _reader?.close();
}

void _mixWorker(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  _PreviewReader? reader;
  inbox.listen((dynamic message) {
    final (reply, command, args) = message as (SendPort, String, Object?);
    try {
      Object? result;
      switch (command) {
        case 'mix':
          final (folder, mix, frame, loop, rate, bytes) =
              args as (String, Mix, int, LoopRange?, int, int);
          final next = _PreviewReader(folder, mix, frame, loop, rate, bytes);
          reader?.close();
          reader = next;
        case 'read':
          result = TransferableTypedData.fromList([reader!.read(args as int)]);
        case 'close':
          reader?.close();
          reader = null;
        case 'quit':
          reader?.close();
          inbox.close();
      }
      reply.send((true, result));
    } catch (e) {
      reply.send((false, e.toString()));
    }
  });
}

/// A short, bounded stereo queue. Only export traverses the whole timeline.
class Preview {
  Preview(
      {required this.onPosition,
      required this.onStopped,
      required this.onError});
  static const _native = MethodChannel('innerwave/preview');
  static const _firstFrames = 4096, _blockFrames = 2048;
  final void Function(int frame) onPosition, onStopped;
  final void Function(Object error) onError;
  bool playing = false;
  int _frame = 0;
  int get frame => scaleFrames(_frame, rate, sampleRate);
  int rate = sampleRate;
  int _bytes = 2;
  int get _stride => _bytes * 2;
  int get _primeFrames =>
      scaleFrames(_firstFrames, sampleRate, rate).clamp(_firstFrames, 32768);
  int get _chunkFrames =>
      scaleFrames(_blockFrames, sampleRate, rate).clamp(_blockFrames, 16384);
  static Future<int> deviceRate() async =>
      await _native.invokeMethod<int>('rate') ?? sampleRate;
  int _origin = 0, _played = 0, _sent = 0, _end = 0;
  LoopRange? _loop;
  String _assets = '';
  SendPort? _worker;
  (Mix, LoopRange?)? _pending;
  Timer? _timer;
  bool _pumpScheduled = false;
  Future<void> _tail = Future.value();

  // One operation at a time across both the isolate and the physical queue.
  // A pending seek or stop therefore cannot receive bytes from an older read.
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Object?> _request(String command, [Object? args]) async {
    if (_worker == null) {
      final ready = ReceivePort();
      try {
        await Isolate.spawn(_mixWorker, ready.sendPort,
            debugName: 'Innerwave PCM mixer');
        _worker = await ready.first as SendPort;
      } finally {
        ready.close();
      }
    }
    final response = ReceivePort();
    try {
      _worker!.send((response.sendPort, command, args));
      final (ok, result) = await response.first as (bool, Object?);
      if (!ok) throw FormatException(result.toString());
      return result;
    } finally {
      response.close();
    }
  }

  Future<Uint8List> _read(int count) async {
    final memory = await _request('read', count) as TransferableTypedData;
    return memory.materialize().asUint8List();
  }

  LoopRange? _range(LoopRange? loop, Mix original, Mix snapshot) {
    if (loop == null || snapshot.end == 0) return null;
    final end = loop.end == original.end
        ? snapshot.end
        : scaleFrames(loop.end, sampleRate, rate).clamp(1, snapshot.end);
    return (
      start: scaleFrames(loop.start, sampleRate, rate).clamp(0, end - 1),
      end: end
    );
  }

  Future<void> play(String assets, Mix mix, int start,
          {LoopRange? loop, int outputRate = sampleRate}) =>
      _serial(() async {
        await _stop();
        _assets = assets;
        rate = outputRate;
        _bytes = mix.highPrecision || rate != sampleRate ? 4 : 2;
        final snapshot = mix.atRate(rate);
        await _prime(snapshot, scaleFrames(start, sampleRate, rate),
            _range(loop, mix, snapshot));
      });

  Future<void> _prime(Mix mix, int at, LoopRange? loop) async {
    if (loop != null) {
      if (loop.start < 0 || loop.end > mix.end || loop.start >= loop.end) {
        throw ArgumentError.value(
            loop, 'loop', 'Expected a nonempty timeline range.');
      }
      if (at < loop.start || at >= loop.end) at = loop.start;
    }
    _loop = loop;
    _origin = _played = _sent = _frame = at;
    _end = mix.end;
    _pending = null;
    if (at >= _end) {
      onStopped(frame);
      return;
    }
    await _setMix(mix, at);
    try {
      final first = await _read(_primeFrames);
      _sent += first.length ~/ _stride;
      // Some output routes require a minimum priming buffer for tiny clips.
      final buffer = first.length == _primeFrames * _stride
          ? first
          : (Uint8List(_primeFrames * _stride)
            ..setRange(0, first.length, first));
      await _native.invokeMethod<void>(
          'start', _bytes == 2 ? buffer : {'data': buffer, 'rate': rate});
      playing = true;
      _timer =
          Timer.periodic(const Duration(milliseconds: 18), (_) => _schedule());
      _schedule();
    } catch (_) {
      try {
        await _native.invokeMethod<int>('stop');
      } finally {
        await _request('close');
      }
      rethrow;
    }
  }

  // During edits the next unqueued block adopts the newest entire arrangement.
  // Coalescing slider events prevents stale revisions from building a backlog.
  void revise(Mix mix, {LoopRange? loop}) {
    if (!playing) return;
    final next = mix.atRate(rate);
    _pending = (next, _range(loop, mix, next));
    _schedule();
  }

  Future<Object?> _setMix(Mix mix, int at) =>
      _request('mix', (_assets, mix, at, _loop, rate, _bytes));

  int _timelineFrame(int absolute) {
    final loop = _loop;
    return loop == null
        ? absolute
        : loop.start + (absolute - loop.start) % (loop.end - loop.start);
  }

  void _position(int count) {
    _played = (_origin + count).clamp(_played, _sent);
    _frame = _timelineFrame(_played);
  }

  void _schedule() {
    if (!playing || _pumpScheduled) return;
    _pumpScheduled = true;
    unawaited(_serial(() async {
      try {
        if (playing) await _pump();
      } catch (e) {
        try {
          await _stop();
        } finally {
          onError(e);
          onStopped(frame);
        }
      } finally {
        _pumpScheduled = false;
      }
    }).catchError((Object error) {
      onError(error);
    }));
  }

  Future<void> _pump() async {
    final count = await _native.invokeMethod<int>('position');
    if (count == null)
      throw const FormatException(
          'The audio route did not report a playback position.');
    _position(count);
    onPosition(frame);
    final change = _pending;
    if (change != null) {
      final (next, loop) = change;
      _pending = null;
      if (loop != _loop || (loop == null && next.end < _sent)) {
        await _stop();
        await _prime(next, math.min(_frame, next.end), loop);
        return;
      }
      await _setMix(next, _timelineFrame(_sent));
      _end = next.end;
    }
    if (_loop == null && _played >= _end) {
      await _stop();
      onStopped(frame);
      return;
    }
    while ((_loop != null || _sent < _end) && _sent - _played < _primeFrames) {
      final bytes = await _read(_chunkFrames);
      if (bytes.isEmpty)
        throw StateError('The preview mixer returned no frames.');
      await _native.invokeMethod<void>('write', bytes);
      _sent += bytes.length ~/ _stride;
    }
  }

  Future<int> pause() => _serial(_stop);
  Future<int> _stop() async {
    _timer?.cancel();
    _timer = null;
    if (!playing) return frame;
    playing = false;
    _pending = null;
    try {
      final count = await _native.invokeMethod<int>('stop');
      if (count != null) _position(count);
    } finally {
      await _request('close');
    }
    return frame;
  }

  Future<void> dispose() => _serial(() async {
        try {
          await _stop();
        } finally {
          if (_worker != null) {
            await _request('quit');
            _worker = null;
          }
        }
      });
}
