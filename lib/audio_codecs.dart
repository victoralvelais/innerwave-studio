import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'model.dart';

enum ExportFormat {
  wav('WAV', 'wav', 'audio/wav', 'pcm_f64le', 'wav'),
  mp3('MP3', 'mp3', 'audio/mpeg', 'libmp3lame', 'mp3'),
  aac('AAC', 'm4a', 'audio/mp4', 'aac', 'ipod'),
  vorbis('Ogg Vorbis', 'ogg', 'audio/ogg', 'libvorbis', 'ogg');

  const ExportFormat(
      this.label, this.extension, this.mimeType, this.encoder, this.muxer);
  final String label;
  final String extension;
  final String mimeType;
  final String encoder;
  final String muxer;
}

class ExportSettings {
  const ExportSettings(this.format, {this.kbps});
  static const bitrates = [192, 256, 320];
  final ExportFormat format;
  final int? kbps;
  int get targetKbps {
    final rate = kbps ?? 320;
    if (!bitrates.contains(rate)) throw ArgumentError.value(rate, 'kbps');
    return rate;
  }

  String fileName(String name) {
    var safe = name
        .replaceAll(RegExp(r'[^\p{L}\p{N} _.-]', unicode: true), '')
        .trim()
        .replaceFirst(RegExp(r'^\.+'), '')
        .trim();
    // Leave sufficient bytes in a filesystem component for the extension.
    if (utf8.encode(safe).length > 245) {
      safe = String.fromCharCodes(safe.runes.take(60));
    }
    return '${safe.isEmpty ? 'Innerwave mix' : safe}.${format.extension}';
  }

  List<String> get encoderOptions {
    return [
      '-c:a',
      format.encoder,
      if (format != ExportFormat.wav) ...['-b:a', '${targetKbps}k'],
      if (format == ExportFormat.aac) ...[
        '-profile:a',
        'aac_low',
        '-movflags',
        '+faststart'
      ],
      '-f',
      format.muxer,
    ];
  }
}

const _localInput = [
  '-nostdin',
  '-hide_banner',
  '-loglevel',
  'error',
  '-xerror',
  '-y',
  '-protocol_whitelist',
  'file',
];
const _stereoStream = [
  '-map',
  '0:a:0',
  '-vn',
  '-sn',
  '-dn',
  '-map_metadata',
  '-1',
  '-ac',
  '2',
];
const _containers =
    'wav,mp3,mov,aac,aiff,flac,ogg,matroska,webm,avi,mpeg,mpegts';

Future<void> _convert(List<String> args, String failure) async {
  final session = await FFmpegKit.executeWithArguments(args);
  if (ReturnCode.isSuccess(await session.getReturnCode())) return;
  final log = (await session.getOutput())?.trim() ?? '';
  if (log.contains('matches no streams')) {
    throw const FormatException(
        'This file has no audio track. Choose a video with sound.');
  }
  final detail = log.split('\n').where((s) => s.trim().isNotEmpty).firstOrNull;
  throw FormatException(detail == null ? failure : '$failure\n$detail');
}

/// Published only after the decoder finishes and the output has whole frames.
Future<int> decodeToPcm(File input, File output) async {
  final part = File('${output.parent.path}/.innerwave-${makeId()}.part');
  try {
    await _convert([
      ..._localInput,
      '-format_whitelist',
      _containers,
      '-i',
      input.absolute.path,
      ..._stereoStream,
      '-ar',
      '44100',
      '-c:a',
      'pcm_s16le',
      '-f',
      's16le',
      part.absolute.path,
    ], 'Could not read an audio track from this file.');
    final bytes = await part.length();
    if (bytes < frameBytes || bytes % frameBytes != 0) {
      throw const FormatException('The decoder returned incomplete audio.');
    }
    await part.rename(output.path);
    return bytes ~/ frameBytes;
  } finally {
    if (await part.exists()) await part.delete();
  }
}

/// Decode once at the stream's native rate. Binary64 can represent all
/// integer PCM up to 32 bits and floating PCM through double precision.
Future<({int rate, int frames})> decodeNative(File input, File output) async {
  final info = await FFprobeKit.executeWithArguments([
    '-v',
    'error',
    '-protocol_whitelist',
    'file',
    '-format_whitelist',
    _containers,
    '-select_streams',
    'a:0',
    '-show_entries',
    'stream=sample_rate,channels',
    '-of',
    'json',
    input.absolute.path
  ]);
  if (!ReturnCode.isSuccess(await info.getReturnCode())) {
    throw const FormatException('Could not read the audio stream.');
  }
  final streams = jsonDecode((await info.getOutput())!)['streams'] as List;
  if (streams.isEmpty)
    throw const FormatException(
        'This file has no audio track. Choose a video with sound.');
  final stream = streams.first;
  final rate = int.parse(stream['sample_rate'].toString());
  if (rate <= 0)
    throw const FormatException('The source has no usable sample rate.');
  final part = File('${output.path}.part');
  try {
    await _convert([
      ..._localInput,
      '-format_whitelist',
      _containers,
      '-i',
      input.absolute.path,
      ..._stereoStream,
      if (stream['channels'] == 1) ...['-af', 'pan=stereo|c0=c0|c1=c0'],
      '-c:a',
      'pcm_f64le',
      '-f',
      'f64le',
      part.path
    ], 'Could not decode the audio stream.');
    final bytes = await part.length();
    if (bytes < 16 || bytes % 16 != 0)
      throw const FormatException('The decoder returned incomplete audio.');
    await part.rename(output.path);
    return (rate: rate, frames: bytes ~/ 16);
  } finally {
    if (await part.exists()) await part.delete();
  }
}

/// Only clips with a different clock need a rate-specific playback cache.
/// The immutable native-rate source remains the input to every conversion.
Future<void> prepareSources(String assets, Mix mix, int rate) async {
  for (final c in mix.clips) {
    if (c.tone != null || c.sourceRate == rate) continue;
    final out = File('$assets/${c.fileAtRate(rate)}');
    if (await out.exists()) continue;
    final part = File('${out.path}.${makeId()}.part');
    try {
      final frames =
          scaleFrames(c.sourceFrames ?? c.frames, c.sourceRate, rate);
      await _convert([
        ..._localInput,
        '-f',
        c.floatingSource ? 'f64le' : 's16le',
        '-ar',
        '${c.sourceRate}',
        '-ac',
        '2',
        '-i',
        '$assets/${c.source}',
        '-af',
        'aresample=$rate:filter_size=64:osf=dbl,apad=whole_len=$frames,atrim=end_sample=$frames',
        '-c:a',
        'pcm_f64le',
        '-f',
        'f64le',
        part.path
      ], 'Could not match audio sample rates.');
      if (await part.length() != frames * 16)
        throw const FormatException('Incomplete sample-rate conversion.');
      if (!await out.exists()) await part.rename(out.path);
    } finally {
      if (await part.exists()) await part.delete();
    }
  }
}

Future<File> writeExport(File mix, File output, ExportSettings settings) async {
  final part = File('${output.parent.path}/.innerwave-${makeId()}.part');
  try {
    if (settings.format == ExportFormat.wav) {
      await mix.copy(part.path);
    } else {
      await _convert([
        ..._localInput,
        '-f',
        'wav',
        '-i',
        mix.absolute.path,
        ..._stereoStream,
        ...settings.encoderOptions,
        part.absolute.path,
      ], 'Could not encode the ${settings.format.label} mix.');
    }
    if (await part.length() == 0)
      throw const FormatException('The exported mix is empty.');
    return await part.rename(output.path);
  } finally {
    if (await part.exists()) await part.delete();
  }
}
