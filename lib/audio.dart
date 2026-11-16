import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model.dart';

const _block = 8192;
const _peakCount = 192;

List<double> readPeaks(String path, int frames) {
  final file = File(path).openSync();
  final peaks = List<double>.filled(_peakCount, 0);
  try {
    if (frames < 1 || file.lengthSync() != frames * frameBytes) {
      throw const FormatException(
          'The audio decoder returned incomplete samples.');
    }
    final bytes = Uint8List(_block * frameBytes);
    final data = ByteData.sublistView(bytes);
    for (int pos = 0; pos < frames; pos += _block) {
      final count = math.min(_block, frames - pos);
      if (file.readIntoSync(bytes, 0, count * frameBytes) !=
          count * frameBytes) {
        throw const FormatException('Could not read audio samples.');
      }
      for (int i = 0; i < count; i++) {
        final o = i * frameBytes;
        final amp = math.max(data.getInt16(o, Endian.little).abs(),
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

Uint8List _header(int frames) {
  final h = ByteData(44);
  for (final tag in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (int i = 0; i < 4; i++) {
      h.setUint8(tag.key + i, tag.value.codeUnitAt(i));
    }
  }
  final size = frames * frameBytes;
  h.setUint32(4, 36 + size, Endian.little);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 2, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * frameBytes, Endian.little);
  h.setUint16(32, frameBytes, Endian.little);
  h.setUint16(34, 16, Endian.little);
  h.setUint32(40, size, Endian.little);
  return h.buffer.asUint8List();
}

class _Source {
  _Source(this.clip, this.file)
      : gain = math.pow(10, clip.gain / 20).toDouble(),
        lowAmount = math.pow(10, clip.warmth / 20) - 1.0,
        highAmount = math.pow(10, clip.presence / 20) - 1.0;
  final Clip clip;
  final RandomAccessFile file;
  final double gain;
  final num lowAmount, highAmount;
  final low = [0.0, 0.0], band = [0.0, 0.0];
  static final lowAlpha = 1 - math.exp(-2 * math.pi * 240 / sampleRate);
  static final highAlpha = 1 - math.exp(-2 * math.pi * 2600 / sampleRate);

  double adjust(double x, int ch) {
    if (clip.type != LayerType.voice || (lowAmount == 0 && highAmount == 0))
      return x;
    low[ch] += lowAlpha * (x - low[ch]);
    band[ch] += highAlpha * (x - band[ch]);
    return (x + lowAmount * low[ch] + highAmount * (x - band[ch])).toDouble();
  }
}

void renderMix(String assets, Mix mix, String destination) {
  final frames = mix.end;
  if (frames < 1) throw const FormatException('Add a clip before rendering.');
  if (frames * frameBytes > 0xffffffff - 36) {
    throw const FormatException('This mix exceeds the 4 GB stereo WAV limit.');
  }
  final inputs = <_Source>[];
  final partial = File('$destination.part');
  final sink = partial.openSync(mode: FileMode.write);
  try {
    for (final clip in mix.clips.where((c) => !c.muted)) {
      final file = File('$assets/${clip.source}').openSync();
      inputs.add(_Source(clip, file));
      if (file.lengthSync() < (clip.trim + clip.length) * frameBytes) {
        throw FormatException('Missing samples in "${clip.name}".');
      }
      file.setPositionSync(clip.trim * frameBytes);
    }
    sink.writeFromSync(_header(frames));
    final scratch = Uint8List(_block * frameBytes);
    final data = ByteData.sublistView(scratch);
    final samples = Float64List(_block * 2);
    for (int pos = 0; pos < frames; pos += _block) {
      final n = math.min(_block, frames - pos);
      samples.fillRange(0, n * 2, 0);
      for (final input in inputs) {
        final clip = input.clip;
        final first = math.max(pos, clip.start);
        final last = math.min(pos + n, clip.end);
        if (first >= last) continue;
        final bytes = (last - first) * frameBytes;
        if (input.file.readIntoSync(scratch, 0, bytes) != bytes) {
          throw FileSystemException('Audio file ended early', clip.name);
        }
        for (int i = 0; i < last - first; i++) {
          final frame = first + i;
          final ramp = math.min(
              1.0, math.min(frame - clip.start, clip.end - frame - 1) / 128);
          for (int ch = 0; ch < 2; ch++) {
            final x =
                data.getInt16(i * frameBytes + ch * 2, Endian.little) / 32768;
            samples[(frame - pos) * 2 + ch] +=
                input.adjust(x, ch) * input.gain * ramp;
          }
        }
      }
      for (int i = 0; i < n; i++) {
        // Apply one soft overload gain to both channels, preserving stereo balance.
        final peak = math.max(samples[i * 2].abs(), samples[i * 2 + 1].abs());
        final excess = peak - 0.90;
        final scale =
            excess <= 0 ? 1.0 : (0.90 + 0.10 * excess / (0.10 + excess)) / peak;
        for (int ch = 0; ch < 2; ch++) {
          data.setInt16(i * frameBytes + ch * 2,
              (samples[i * 2 + ch] * scale * 32767).round(), Endian.little);
        }
      }
      sink.writeFromSync(scratch, 0, n * frameBytes);
    }
  } finally {
    for (final source in inputs) {
      source.file.closeSync();
    }
    sink.closeSync();
  }
  partial.renameSync(destination);
}
