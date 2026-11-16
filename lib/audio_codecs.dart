import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'model.dart';

enum ExportFormat {
  wav('WAV', 'wav', 'audio/wav', 'pcm_s16le', 'wav'),
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
  '-ar',
  '44100',
  '-ac',
  '2',
];

Future<void> _convert(List<String> args, String failure) async {
  final session = await FFmpegKit.executeWithArguments(args);
  if (ReturnCode.isSuccess(await session.getReturnCode())) return;
  final log = (await session.getOutput())?.trim() ?? '';
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
      'wav,mp3,mov,aac,aiff,flac,ogg',
      '-i',
      input.absolute.path,
      ..._stereoStream,
      '-c:a',
      'pcm_s16le',
      '-f',
      's16le',
      part.absolute.path,
    ], 'Could not decode this audio file.');
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
