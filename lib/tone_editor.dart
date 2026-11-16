import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'model.dart';
import 'studio.dart';
import 'studio_view.dart';

typedef ToneDraft = ({BeatTone tone, double gain, int frames});

const _bands = [
  (name: 'Delta', value: 2.0, range: '1 to below 4 Hz', min: 1.0, max: 3.99),
  (name: 'Theta', value: 6.0, range: '4 to below 8 Hz', min: 4.0, max: 7.99),
  (name: 'Alpha', value: 10.0, range: '8–13 Hz', min: 8.0, max: 13.0),
  (name: 'Mu', value: 9.0, range: '7–11 Hz', min: 7.0, max: 11.0),
  (name: 'Beta', value: 20.0, range: '14–30 Hz', min: 14.0, max: 30.0),
  (
    name: 'Gamma',
    value: 40.0,
    range: 'above 30 to 50 Hz',
    min: 30.01,
    max: 50.0
  ),
];

String _bandDescription(double difference) {
  final hz = (difference * 100).round() / 100;
  if (hz == 0) return 'No beat · Both ears have the same frequency';
  if (hz < 1 || hz > 50) return 'Outside the 1–50 Hz beat range';
  final bands = _bands.where((band) => hz >= band.min && hz <= band.max);
  if (bands.isEmpty) return 'Between Alpha and Beta · above 13 to below 14 Hz';
  return bands.map((band) => '${band.name} · ${band.range}').join('   /   ');
}

class ToneEditor extends StatefulWidget {
  const ToneEditor({super.key, required this.studio, this.existing});
  final Studio studio;
  final Clip? existing;
  @override
  State<ToneEditor> createState() => _ToneEditorState();
}

class _ToneEditorState extends State<ToneEditor> {
  late BeatTone tone = widget.existing?.tone ?? const BeatTone();
  late double gain = widget.existing?.gain ?? -12;
  late final duration = TextEditingController(
      text: widget.existing == null
          ? '60'
          : (widget.existing!.length / sampleRate)
              .toStringAsFixed(5)
              .replaceFirst(RegExp(r'\.?0+$'), ''));
  int timerMinutes = 0;
  DateTime? deadline;
  Timer? clock;
  bool busy = false;
  String? durationError;
  bool get independent => widget.studio.mix.independent(LayerType.beat);
  bool get playing => widget.studio.tonePreviewing;

  @override
  void dispose() {
    clock?.cancel();
    duration.dispose();
    super.dispose();
  }

  void message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> work(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      message(e is FormatException ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void update(BeatTone next, [double? level]) {
    setState(() {
      tone = next;
      if (level != null) gain = level;
    });
    if (playing) widget.studio.updateTonePreview(tone, gain);
  }

  void linked(double base, double beat) =>
      update(tone.copyWith(base: math.max(base, 1 + beat / 2), beat: beat));

  void chooseBand(double beat) {
    if (!independent) {
      linked(tone.base, beat);
      return;
    }
    final center =
        ((tone.left + tone.right) / 2).clamp(1 + beat / 2, 1525 - beat / 2);
    final half = (tone.left <= tone.right ? beat : -beat) / 2;
    update(tone.copyWith(left: center - half, right: center + half));
  }

  Future<void> togglePreview() => work(() async {
        clock?.cancel();
        if (playing) {
          await widget.studio.stopTonePreview();
          deadline = null;
          return;
        }
        final limit =
            timerMinutes == 0 ? null : Duration(minutes: timerMinutes);
        await widget.studio.startTonePreview(tone, gain, timer: limit);
        deadline = limit == null ? null : DateTime.now().add(limit);
        if (!mounted) return;
        clock = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted || !playing) timer.cancel();
          if (mounted) setState(() {});
        });
      });

  Future<void> bandsInfo() => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Frequency bands'),
            content: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text(
                      'Each shortcut sets the difference between the left and right tones. Band names come from EEG reference ranges. Alpha and Mu overlap.'),
                  const SizedBox(height: 12),
                  for (final band in _bands)
                    Text('${band.name}  ·  ${band.range}'),
                  TextButton(
                      onPressed: () async {
                        final ok = await launchUrl(
                            Uri.parse(
                                'https://pmc.ncbi.nlm.nih.gov/articles/PMC6123891/'),
                            mode: LaunchMode.externalApplication);
                        if (!ok) message('The reference could not be opened.');
                      },
                      child: const Text('EEG glossary reference')),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'))
            ],
          ));

  Future<void> presets() => work(() async {
        final slots = await widget.studio.loadTonePresets();
        if (!mounted) return;
        final pick = await showModalBottomSheet<({int index, bool save})>(
            context: context,
            isScrollControlled: true,
            builder: (ctx) => SafeArea(
                child: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Tone presets',
                                  style: Theme.of(ctx).textTheme.titleLarge),
                              for (int i = 0; i < slots.length; i++)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                      slots[i]?.name ?? 'Empty slot ${i + 1}'),
                                  onTap: slots[i] == null
                                      ? null
                                      : () => Navigator.pop(
                                          ctx, (index: i, save: false)),
                                  trailing: IconButton(
                                      tooltip: 'Save to slot ${i + 1}',
                                      icon: const Icon(Icons.save_outlined),
                                      onPressed: () => Navigator.pop(
                                          ctx, (index: i, save: true))),
                                ),
                            ])))));
        if (pick == null || !mounted) return;
        if (!pick.save) {
          update(slots[pick.index]!.tone);
          return;
        }
        var name = slots[pick.index]?.name ?? '';
        final named = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: Text('Save preset ${pick.index + 1}'),
                  content: TextFormField(
                      initialValue: name,
                      autofocus: true,
                      maxLength: 60,
                      decoration:
                          const InputDecoration(labelText: 'Preset name'),
                      onChanged: (v) => name = v,
                      onFieldSubmitted: (v) {
                        if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
                      }),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () {
                          if (name.trim().isNotEmpty)
                            Navigator.pop(ctx, name.trim());
                        },
                        child: const Text('Save')),
                  ],
                ));
        if (named != null)
          await widget.studio.saveTonePreset(pick.index, named, tone);
      });

  Future<void> exact(String title, double value, double min, double max,
      ValueChanged<double> change) async {
    var text = value.toStringAsFixed(2);
    String? error;
    final result = await showDialog<double>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
              void apply() {
                final next = double.tryParse(text.trim().replaceAll(',', '.'));
                if (next == null ||
                    !next.isFinite ||
                    next < min ||
                    next > max) {
                  set(() => error =
                      'Enter ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} Hz.');
                  return;
                }
                Navigator.pop(ctx, (next * 100).round() / 100);
              }

              return AlertDialog(
                  title: Text(title),
                  content: TextFormField(
                      initialValue: text,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: 'Exact frequency',
                          suffixText: 'Hz',
                          errorText: error),
                      onFieldSubmitted: (_) => apply(),
                      onChanged: (v) => text = v),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    FilledButton(onPressed: apply, child: const Text('Apply'))
                  ]);
            }));
    if (result != null && mounted) change(result);
  }

  Widget frequency(String title, double value, double min, double max,
          Color color, ValueChanged<double> change) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        Row(children: [
          IconButton(
              tooltip: 'Decrease $title by 0.01 Hz',
              onPressed: value <= min
                  ? null
                  : () => change(((value * 100).round() - 1)
                          .clamp((min * 100).round(), (max * 100).round()) /
                      100),
              icon: const Icon(Icons.remove_circle_outline)),
          Expanded(
              child: TextButton(
                  key: ValueKey('exact-$title'),
                  onPressed: () => exact(title, value, min, max, change),
                  child: Text('${value.toStringAsFixed(2)} Hz',
                      style: TextStyle(
                          color: color,
                          fontSize: 21,
                          fontFamily: 'monospace')))),
          IconButton(
              tooltip: 'Increase $title by 0.01 Hz',
              onPressed: value >= max
                  ? null
                  : () => change(((value * 100).round() + 1)
                          .clamp((min * 100).round(), (max * 100).round()) /
                      100),
              icon: const Icon(Icons.add_circle_outline)),
        ]),
        Semantics(
            label: title,
            child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                activeColor: color,
                semanticFormatterCallback: (v) =>
                    '${v.toStringAsFixed(2)} hertz',
                onChanged: (v) => change((v * 100).round() / 100))),
      ]);

  void submit() {
    final value = double.tryParse(duration.text.trim().replaceAll(',', '.'));
    final at = widget.existing?.start ?? widget.studio.cursor;
    if (value == null ||
        !value.isFinite ||
        value <= 0 ||
        value > 24 * 3600 - at / sampleRate ||
        frameAt(value) < 1) {
      setState(() => durationError =
          'Enter a positive duration within the 24-hour timeline.');
      return;
    }
    Navigator.pop<ToneDraft>(
        context, (tone: tone, gain: gain, frames: frameAt(value)));
  }

  @override
  Widget build(BuildContext context) {
    final left = tone.leftHz(independent), right = tone.rightHz(independent);
    final percent = gain <= silentGainDb
        ? 0.0
        : (100 * math.pow(10, gain / 20)).clamp(0.0, 100.0).toDouble();
    final band = Text(_bandDescription((left - right).abs()),
        key: const ValueKey('current-beat-band'),
        style: const TextStyle(color: violet, fontWeight: FontWeight.w500));
    final remaining = deadline?.difference(DateTime.now()).inSeconds;
    final fastest = math.max(left, right);
    final window = fastest < 20
        ? 1.0
        : fastest < 100
            ? .10
            : fastest < 600
                ? .020
                : .010;
    return PopScope<ToneDraft>(
        canPop: !busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Tone generator'), actions: [
            IconButton(
                onPressed: busy ? null : presets,
                tooltip: 'Tone presets',
                icon: const Icon(Icons.bookmarks_outlined)),
          ]),
          bottomNavigationBar: SafeArea(
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Expanded(
                        child: OutlinedButton.icon(
                            key: const ValueKey('tone-preview'),
                            onPressed: busy ? null : togglePreview,
                            icon:
                                Icon(playing ? Icons.pause : Icons.play_arrow),
                            label: Text(playing ? 'Pause' : 'Audition'))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: FilledButton(
                            onPressed: busy ? null : submit,
                            child: Text(widget.existing == null
                                ? 'Add to timeline'
                                : 'Apply changes'))),
                  ]))),
          body: SafeArea(
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 650),
                      child: ListView(
                          padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
                          children: [
                            DecoratedBox(
                                decoration: BoxDecoration(
                                    color: panel,
                                    border: Border.all(color: line),
                                    borderRadius: BorderRadius.circular(12)),
                                child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(children: [
                                      for (final channel in [
                                        (ear: 'Left', hz: left, color: mint),
                                        (ear: 'Right', hz: right, color: violet)
                                      ]) ...[
                                        Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(channel.ear,
                                                  style: TextStyle(
                                                      color: channel.color)),
                                              Text(
                                                  '${channel.hz.toStringAsFixed(2)} Hz',
                                                  style: const TextStyle(
                                                      color: softText,
                                                      fontFamily: 'monospace',
                                                      fontSize: 11))
                                            ]),
                                        SizedBox(
                                            height: 36,
                                            width: double.infinity,
                                            child: CustomPaint(
                                                painter: _ToneTrace(channel.hz,
                                                    window, channel.color))),
                                      ],
                                      Align(
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                              '${(window * 1000).round()} ms',
                                              style: const TextStyle(
                                                  color: softText,
                                                  fontSize: 10))),
                                    ]))),
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title:
                                    const Text('Independent ear frequencies'),
                                subtitle: const Text(
                                    'Applies to beats in this session'),
                                value: independent,
                                onChanged: busy
                                    ? null
                                    : (v) => work(() => widget.studio
                                        .setIndependent(LayerType.beat, v!))),
                            Row(children: [
                              const Expanded(
                                  child: Text('Beat bands',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600))),
                              IconButton(
                                  onPressed: bandsInfo,
                                  tooltip: 'About frequency bands',
                                  icon:
                                      const Icon(Icons.info_outline, size: 20))
                            ]),
                            Wrap(spacing: 6, runSpacing: 4, children: [
                              for (final band in _bands)
                                ActionChip(
                                    label: Text(band.name),
                                    tooltip:
                                        '${band.name} · ${band.value.toStringAsFixed(0)} Hz',
                                    onPressed: () => chooseBand(band.value))
                            ]),
                            const SizedBox(height: 16),
                            if (independent) ...[
                              frequency('Left ear', tone.left, 1, 1525, mint,
                                  (v) => update(tone.copyWith(left: v))),
                              frequency(
                                  'Right ear',
                                  tone.right,
                                  1,
                                  1525,
                                  violet,
                                  (v) => update(tone.copyWith(right: v))),
                              Text(
                                  'Difference  ${(left - right).abs().toStringAsFixed(2)} Hz',
                                  style: const TextStyle(color: softText)),
                              band,
                            ] else ...[
                              frequency('Beat frequency', tone.beat, 1, 50,
                                  violet, (v) => linked(tone.base, v)),
                              band,
                              const SizedBox(height: 12),
                              frequency('Center frequency', tone.base, 20, 1500,
                                  mint, (v) => linked(v, tone.beat)),
                            ],
                            const Divider(),
                            Text(
                                'Volume   ${percent.toStringAsFixed(percent > 0 && percent < 1 ? 1 : 0)}%   ·   ${gainLabel(gain)}${gain > 0 ? ' timeline boost' : ''}'),
                            Semantics(
                                label: 'Tone volume',
                                child: Slider(
                                    key: const ValueKey('tone-volume'),
                                    max: 100,
                                    divisions: 100,
                                    value: percent,
                                    semanticFormatterCallback: (v) =>
                                        '${v.round()} percent',
                                    onChanged: (v) => update(
                                        tone,
                                        v == 0
                                            ? silentGainDb
                                            : 20 *
                                                math.log(v / 100) /
                                                math.ln10),
                                    onChangeEnd: (v) {
                                      if (v == 100 && gain > 0) update(tone, 0);
                                    })),
                            TextField(
                                controller: duration,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: InputDecoration(
                                    labelText: 'Timeline duration',
                                    suffixText: 'seconds',
                                    errorText: durationError),
                                onChanged: (_) {
                                  if (durationError != null)
                                    setState(() => durationError = null);
                                }),
                            const SizedBox(height: 16),
                            Row(children: [
                              const Expanded(child: Text('Audition timer')),
                              DropdownButton<int>(
                                  value: timerMinutes,
                                  onChanged: playing
                                      ? null
                                      : (n) =>
                                          setState(() => timerMinutes = n!),
                                  items: [
                                    const DropdownMenuItem(
                                        value: 0, child: Text('Off')),
                                    for (int n = 15; n <= 480; n += 15)
                                      DropdownMenuItem(
                                          value: n,
                                          child: Text(n % 60 == 0
                                              ? '${n ~/ 60} h'
                                              : '$n min')),
                                  ])
                            ]),
                            if (timerMinutes > 0)
                              Text(
                                  playing && remaining != null
                                      ? '${remaining.clamp(0, 1 << 30) ~/ 60}m ${remaining.clamp(0, 1 << 30) % 60}s remaining · fades in the final minute.'
                                      : 'The audition fades during the final minute.',
                                  style: const TextStyle(
                                      color: softText, fontSize: 12)),
                          ])))),
        ));
  }
}

class _ToneTrace extends CustomPainter {
  const _ToneTrace(this.hz, this.window, this.color);
  final double hz, window;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final middle = size.height / 2;
    canvas.drawLine(
        Offset(0, middle), Offset(size.width, middle), Paint()..color = line);
    final path = Path()..moveTo(0, middle);
    for (double x = 1; x <= size.width; x++) {
      path.lineTo(
          x,
          middle -
              middle *
                  .76 *
                  math.sin(x / size.width * window * hz * 2 * math.pi));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(_ToneTrace old) =>
      old.hz != hz || old.window != window || old.color != color;
}
