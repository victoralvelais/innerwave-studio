import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/audio_codecs.dart';
import 'package:innerwave_studio/export_sheet.dart';
import 'package:innerwave_studio/model.dart';

void main() {
  test(
      'WAV copies the render exactly, failed encoding preserves a prior export',
      () async {
    final dir = await Directory.systemTemp.createTemp('innerwave-export-');
    addTearDown(() => dir.delete(recursive: true));
    final input = await File('${dir.path}/source.wav')
        .writeAsBytes([82, 73, 70, 70, 8, 0, 0, 0]);
    final out = File('${dir.path}/Clouds.wav');
    await writeExport(input, out, const ExportSettings(ExportFormat.wav));
    expect(await out.readAsBytes(), await input.readAsBytes());
    final previous =
        await File('${dir.path}/Clouds.mp3').writeAsBytes([2, 3, 4]);
    await expectLater(
        writeExport(
            input, previous, const ExportSettings(ExportFormat.mp3, kbps: 0)),
        throwsArgumentError);
    expect(await previous.readAsBytes(), [2, 3, 4]);
    expect(await dir.list().where((f) => f.path.endsWith('.part')).isEmpty,
        isTrue);
  });

  test('codec, container, bitrate, share MIME and display extension agree', () {
    final variants = {
      ExportFormat.mp3: ('libmp3lame', 'mp3', 'audio/mpeg', 'mp3'),
      ExportFormat.aac: ('aac', 'ipod', 'audio/mp4', 'm4a'),
      ExportFormat.vorbis: ('libvorbis', 'ogg', 'audio/ogg', 'ogg'),
    };
    for (final e in variants.entries) {
      final settings = ExportSettings(e.key);
      expect(
          settings.encoderOptions,
          containsAllInOrder(
              ['-c:a', e.value.$1, '-b:a', '320k', '-f', e.value.$2]));
      expect(settings.format.mimeType, e.value.$3);
      expect(settings.fileName('../Drift #2'), 'Drift 2.${e.value.$4}');
      expect(settings.fileName('?!'), 'Innerwave mix.${e.value.$4}');
    }
  });

  testWidgets(
      'export sheet offers all formats and returns the selected bitrate',
      (t) async {
    ExportSettings? choice;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    child: const Text('Export'),
                    onPressed: () async {
                      choice = await showModalBottomSheet<ExportSettings>(
                          context: ctx,
                          isScrollControlled: true,
                          builder: (_) => const ExportSheet(
                              initial: ExportSettings(ExportFormat.wav),
                              frames: sampleRate * 20));
                    })))));
    await t.tap(find.text('Export'));
    await t.pumpAndSettle();
    expect(find.text('320 kbps'), findsNothing);
    for (final format in ExportFormat.values) {
      expect(find.text(format.label), findsOneWidget);
    }
    await t.tap(find.text('Ogg Vorbis'));
    await t.pumpAndSettle();
    await t.tap(find.text('256 kbps'));
    await t.pumpAndSettle();
    await t.tap(find.text('Export Ogg Vorbis'));
    await t.pumpAndSettle();
    expect(choice!.format, ExportFormat.vorbis);
    expect(choice!.targetKbps, 256);
  });
}
