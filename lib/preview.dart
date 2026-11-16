import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'audio.dart';
import 'model.dart';

void _mixWorker(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  MixReader? reader;
  inbox.listen((dynamic message) {
    final (reply, command, args) = message as (SendPort, String, Object?);
    try {
      Object? result;
      switch (command) {
        case 'mix':
          final (folder, mix, frame) = args as (String, Mix, int);
          final next = MixReader(folder, mix, frame);
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
  int frame = 0;
  int _origin = 0, _sent = 0, _end = 0;
  String _assets = '';
  SendPort? _worker;
  Mix? _pending;
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

  Future<void> play(String assets, Mix mix, int start) => _serial(() async {
        await _stop();
        _assets = assets;
        await _prime(mix, start);
      });

  Future<void> _prime(Mix mix, int at) async {
    _origin = _sent = frame = at;
    _end = mix.end;
    _pending = null;
    if (at >= _end) {
      onStopped(_end);
      return;
    }
    await _setMix(mix, at);
    try {
      final first = await _read(_firstFrames);
      _sent += first.length ~/ frameBytes;
      // Some output routes require a minimum priming buffer for tiny clips.
      final buffer = first.length == _firstFrames * frameBytes
          ? first
          : (Uint8List(_firstFrames * frameBytes)
            ..setRange(0, first.length, first));
      await _native.invokeMethod<void>('start', buffer);
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
  void revise(Mix mix) {
    if (!playing) return;
    _pending = mix;
    _schedule();
  }

  Future<Object?> _setMix(Mix mix, int at) =>
      _request('mix', (_assets, Mix(mix.id, mix.name, mix.clips), at));

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
    frame = (_origin + count).clamp(frame, _sent);
    onPosition(frame);
    final next = _pending;
    if (next != null) {
      _pending = null;
      if (next.end < _sent) {
        await _stop();
        await _prime(next, math.min(frame, next.end));
        return;
      }
      await _setMix(next, _sent);
      _end = next.end;
    }
    if (frame >= _end) {
      await _stop();
      onStopped(frame);
      return;
    }
    while (_sent < _end && _sent - frame < _firstFrames) {
      final bytes = await _read(_blockFrames);
      if (bytes.isEmpty)
        throw StateError('The preview mixer returned no frames.');
      await _native.invokeMethod<void>('write', bytes);
      _sent += bytes.length ~/ frameBytes;
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
      if (count != null) frame = (_origin + count).clamp(frame, _sent);
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
