import 'package:flutter/material.dart';

import 'audio_codecs.dart';
import 'model.dart';
import 'studio_view.dart';

class ExportSheet extends StatefulWidget {
  const ExportSheet({super.key, required this.initial, required this.frames});
  final ExportSettings initial;
  final int frames;
  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  late ExportFormat format = widget.initial.format;
  late int bitrate = widget.initial.targetKbps;

  @override
  Widget build(BuildContext context) {
    final pcm = format == ExportFormat.wav;
    final bytes = pcm
        ? widget.frames * frameBytes + 44
        : (widget.frames / sampleRate * bitrate * 1000 / 8).round();
    final size = bytes >= 1000000
        ? '${(bytes / 1000000).toStringAsFixed(1)} MB'
        : '${(bytes / 1000).ceil()} KB';
    return SafeArea(
        child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Export mix',
                      style:
                          TextStyle(fontSize: 23, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                      '${timeOf(widget.frames, fraction: true)}   ·   Stereo   ·   44.1 kHz',
                      style: const TextStyle(color: softText, fontSize: 13)),
                  const SizedBox(height: 14),
                  for (final option in ExportFormat.values)
                    ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        dense: true,
                        title: Text(option.label),
                        subtitle: Text(switch (option) {
                          ExportFormat.wav => 'Uncompressed PCM · .wav',
                          ExportFormat.mp3 => 'MPEG Layer III · .mp3',
                          ExportFormat.aac => 'AAC-LC in MPEG-4 · .m4a',
                          ExportFormat.vorbis => 'Vorbis in Ogg · .ogg',
                        }),
                        trailing: Icon(
                            format == option
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: format == option ? mint : softText),
                        selected: format == option,
                        onTap: () => setState(() => format = option)),
                  if (!pcm) ...[
                    const SizedBox(height: 10),
                    const Text('Target bitrate',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, children: [
                      for (final rate in ExportSettings.bitrates)
                        ChoiceChip(
                            label: Text('$rate kbps'),
                            selected: bitrate == rate,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => bitrate = rate)),
                    ]),
                  ],
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                        child: Text('${pcm ? '' : '≈ '}$size',
                            style: const TextStyle(color: softText))),
                    FilledButton.icon(
                        onPressed: () => Navigator.pop(context,
                            ExportSettings(format, kbps: pcm ? null : bitrate)),
                        icon: const Icon(Icons.ios_share_rounded, size: 16),
                        label: Text('Export ${format.label}')),
                  ]),
                ])));
  }
}
