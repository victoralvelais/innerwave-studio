import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model.dart';

const _block = 32768;
const _peakCount = 192;

List<double> readPeaks(String path, int frames) {
  final floating = path.endsWith('.f64');
  final stride = floating ? 16 : frameBytes;
  final file = File(path).openSync();
  final peaks = List<double>.filled(_peakCount, 0);
  try {
    if (frames < 1 || file.lengthSync() != frames * stride) {
      throw const FormatException(
          'The audio decoder returned incomplete samples.');
    }
    final bytes = Uint8List(_block * stride);
    final data = ByteData.sublistView(bytes);
    for (int pos = 0; pos < frames; pos += _block) {
      final count = math.min(_block, frames - pos);
      if (file.readIntoSync(bytes, 0, count * stride) != count * stride) {
        throw const FormatException('Could not read audio samples.');
      }
      for (int i = 0; i < count; i++) {
        final o = i * stride;
        final amp = floating
            ? math.max(data.getFloat64(o, Endian.little).abs(),
                data.getFloat64(o + 8, Endian.little).abs())
            : math.max(data.getInt16(o, Endian.little).abs(),
                    data.getInt16(o + 2, Endian.little).abs()) /
                32768;
        final bin = (pos + i) * _peakCount ~/ frames;
        if (amp > peaks[bin]) peaks[bin] = amp;
      }
    }
    return peaks;
  } finally {
    file.closeSync();
  }
}

/// Original synthesized starter sounds. The two oscillators stay in separate
/// channels from generation through preview and export.
void generateStarter(String path, LayerType kind, int frames) {
  final target = File(path);
  if (target.existsSync() && target.lengthSync() == frames * frameBytes) return;
  final pending = File('$path.part');
  final output = pending.openSync(mode: FileMode.write);
  final rng = math.Random(622);
  var leftNoise = 0.0, rightNoise = 0.0, droplet = 0.0;
  var dropPhase = 0.0, dropStep = 0.0, dropPan = 0.5;
  final bytes = Uint8List(_block * frameBytes);
  final data = ByteData.sublistView(bytes);
  try {
    for (int p = 0; p < frames; p += _block) {
      final count = math.min(_block, frames - p);
      for (int i = 0; i < count; i++) {
        final t = (p + i) / sampleRate;
        double l, r;
        if (kind == LayerType.beat) {
          l = 0.4 * math.sin(2 * math.pi * 180 * t);
          r = 0.4 * math.sin(2 * math.pi * 186 * t);
        } else {
          final n1 = rng.nextDouble() * 2 - 1, n2 = rng.nextDouble() * 2 - 1;
          leftNoise = 0.89 * leftNoise + 0.11 * n1;
          rightNoise = 0.89 * rightNoise + 0.11 * n2;
          if (rng.nextDouble() < 0.00035) {
            droplet = 0.07 + 0.12 * rng.nextDouble();
            dropPhase = 0;
            dropStep =
                2 * math.pi * (800 + rng.nextDouble() * 1700) / sampleRate;
            dropPan = rng.nextDouble();
          }
          dropPhase += dropStep;
          droplet *= 0.996;
          final tap = droplet * math.sin(dropPhase);
          final swell = 0.75 + 0.2 * math.sin(t * 0.63);
          l = (leftNoise * 0.8 + n1 * 0.08) * swell + tap * dropPan;
          r = (rightNoise * 0.8 + n2 * 0.08) * swell + tap * (1 - dropPan);
        }
        final edge =
            math.min(1.0, math.min(t, (frames - p - i - 1) / sampleRate) * 2);
        data.setInt16(i * 4, (l * edge * 32767).round(), Endian.little);
        data.setInt16(i * 4 + 2, (r * edge * 32767).round(), Endian.little);
      }
      output.writeFromSync(bytes, 0, count * frameBytes);
    }
  } finally {
    output.closeSync();
  }
  pending.renameSync(path);
}

Uint8List _header(int frames, int rate, bool floating) {
  final stride = floating ? 16 : frameBytes;
  final h = ByteData(44);
  for (final tag in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (int i = 0; i < 4; i++) {
      h.setUint8(tag.key + i, tag.value.codeUnitAt(i));
    }
  }
  final size = frames * stride;
  h.setUint32(4, 36 + size, Endian.little);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, floating ? 3 : 1, Endian.little);
  h.setUint16(22, 2, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * stride, Endian.little);
  h.setUint16(32, stride, Endian.little);
  h.setUint16(34, stride * 4, Endian.little);
  h.setUint32(40, size, Endian.little);
  return h.buffer.asUint8List();
}

class _Source {
  _Source(this.clip, this.file, int rate, bool independent)
      : gain = clip.gain <= silentGainDb
            ? 0
            : math.pow(10, clip.gain / 20).toDouble(),
        route = independent ? clip.ear : EarRoute.both,
        leftStep = 2 * math.pi * (clip.tone?.leftHz(independent) ?? 0) / rate,
        rightStep = 2 * math.pi * (clip.tone?.rightHz(independent) ?? 0) / rate,
        lowAlpha = 1 - math.exp(-2 * math.pi * 240 / rate),
        highAlpha = 1 - math.exp(-2 * math.pi * 2600 / rate),
        lowAmount = math.pow(10, clip.warmth / 20) - 1.0,
        highAmount = math.pow(10, clip.presence / 20) - 1.0;
  final Clip clip;
  final RandomAccessFile? file;
  final EarRoute route;
  final double leftStep, rightStep, lowAlpha, highAlpha;
  int get stride => clip.floatingSource ? 16 : frameBytes;
  double decode(ByteData data, int i) => clip.floatingSource
      ? data.getFloat64(i * 8, Endian.little)
      : data.getInt16(i * 2, Endian.little) / 32768;
  final double gain;
  final num lowAmount, highAmount;
  final low = [0.0, 0.0], band = [0.0, 0.0];

  double adjust(double x, int ch) {
    if (clip.type != LayerType.voice || (lowAmount == 0 && highAmount == 0))
      return x;
    low[ch] += lowAlpha * (x - low[ch]);
    band[ch] += highAlpha * (x - band[ch]);
    return (x + lowAmount * low[ch] + highAmount * (x - band[ch])).toDouble();
  }
}

/// Sequential, bounded PCM reader used by both the output device and export.
class MixReader {
  MixReader(String assets, Mix mix, this.position,
      {this.rate = sampleRate, this.outputBytes = 2})
      : end = mix.end {
    try {
      for (final clip in mix.clips.where((c) => !c.muted && c.end > position)) {
        final file = clip.tone != null
            ? null
            : File('$assets/${clip.source}').openSync();
        final source = _Source(clip, file, rate, mix.independent(clip.type));
        inputs.add(source);
        if (file == null) continue;
        if (file.lengthSync() < (clip.trim + clip.length) * source.stride) {
          throw FormatException('Missing samples in "${clip.name}".');
        }
        final offset = math.max(0, position - clip.start);
        // A bounded filter pre-roll reconstructs the voice EQ state on seek.
        final warm = clip.type == LayerType.voice &&
                (clip.warmth != 0 || clip.presence != 0)
            ? math.min(1024, offset)
            : 0;
        file.setPositionSync((clip.trim + offset - warm) * source.stride);
        if (warm > 0) {
          if (file.readIntoSync(scratch, 0, warm * source.stride) !=
              warm * source.stride) {
            throw FileSystemException('Audio file ended early', clip.name);
          }
          for (int i = 0; i < warm * 2; i++) {
            source.adjust(source.decode(data, i), i % 2);
          }
        }
      }
    } catch (_) {
      close();
      rethrow;
    }
  }

  final inputs = <_Source>[];
  final int rate, outputBytes;
  final scratch = Uint8List(_block * 16);
  late final data = ByteData.sublistView(scratch);
  final samples = Float64List(_block * 2);
  final int end;
  int position;

  /// The returned block is valid until the next call to read.
  Uint8List read(int requested) {
    if (requested < 0 || requested > _block)
      throw RangeError.range(requested, 0, _block);
    final pos = position;
    final n = math.min(requested, math.max(0, end - pos));
    samples.fillRange(0, n * 2, 0);
    for (final input in inputs) {
      final clip = input.clip;
      final first = math.max(pos, clip.start);
      final last = math.min(pos + n, clip.end);
      if (first >= last) continue;
      final bytes = (last - first) * input.stride;
      final file = input.file;
      if (file != null && file.readIntoSync(scratch, 0, bytes) != bytes) {
        throw FileSystemException('Audio file ended early', clip.name);
      }
      for (int i = 0; i < last - first; i++) {
        final frame = first + i;
        final local = frame - clip.start;
        final ramp = clip.original != null
            ? 1.0
            : math.min(
                1.0,
                math.min(local, clip.end - frame - 1) /
                    (128 * rate / sampleRate));
        final phase = clip.trim + local;
        final l = input.adjust(
            file == null
                ? 0.4 * math.sin(input.leftStep * phase)
                : input.decode(data, i * 2),
            0);
        final r = input.adjust(
            file == null
                ? 0.4 * math.sin(input.rightStep * phase)
                : input.decode(data, i * 2 + 1),
            1);
        final fade = clip.fadeOut > 0
            ? ((clip.end - frame - 1) / clip.fadeOut).clamp(0.0, 1.0)
            : 1.0;
        final gain = input.gain * ramp * fade;
        final at = (frame - pos) * 2;
        if (input.route == EarRoute.both || clip.tone != null) {
          samples[at] += l * gain;
          samples[at + 1] += r * gain;
        } else {
          samples[at + (input.route == EarRoute.left ? 0 : 1)] +=
              (l + r) * 0.5 * gain;
        }
      }
    }
    if (outputBytes == 8) {
      for (var j = 0; j < n * 2; j++) {
        data.setFloat64(j * 8, samples[j], Endian.little);
      }
    } else if (outputBytes == 4) {
      for (var j = 0; j < n * 2; j++) {
        data.setFloat32(j * 4, samples[j], Endian.little);
      }
    } else {
      // Keep the historical overload curve on legacy 16-bit output.
      for (int i = 0; i < n; i++) {
        final peak = math.max(samples[i * 2].abs(), samples[i * 2 + 1].abs());
        final excess = peak - 0.90;
        final scale =
            excess <= 0 ? 1.0 : (0.90 + 0.10 * excess / (0.10 + excess)) / peak;
        for (int ch = 0; ch < 2; ch++) {
          final j = i * 2 + ch;
          data.setInt16(
              j * 2, (samples[j] * scale * 32767).round(), Endian.little);
        }
      }
    }
    position += n;
    return Uint8List.sublistView(scratch, 0, n * 2 * outputBytes);
  }

  void close() {
    for (final source in inputs) {
      source.file?.closeSync();
    }
    inputs.clear();
  }
}

void renderMix(String assets, Mix mix, String destination) {
  final rate = mix.masterRate;
  final floating = mix.highPrecision;
  final snapshot = mix.atRate(rate);
  final frames = snapshot.end;
  if (frames < 1) throw const FormatException('Add a clip before rendering.');
  if (frames * (floating ? 16 : frameBytes) > 0xffffffff - 36) {
    throw const FormatException('This mix exceeds the 4 GB stereo WAV limit.');
  }
  final reader =
      MixReader(assets, snapshot, 0, rate: rate, outputBytes: floating ? 8 : 2);
  final partial = File('$destination.part');
  try {
    final sink = partial.openSync(mode: FileMode.write);
    try {
      sink.writeFromSync(_header(frames, rate, floating));
      while (reader.position < reader.end) {
        sink.writeFromSync(reader.read(_block));
      }
    } finally {
      sink.closeSync();
    }
  } finally {
    reader.close();
  }
  partial.renameSync(destination);
}
