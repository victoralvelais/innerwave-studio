import 'package:flutter/material.dart';
import 'model.dart';
import 'studio_view.dart';

class ClipEditor extends StatefulWidget {
  const ClipEditor({super.key, required this.original, this.onAudition});
  final Clip original;
  final ValueChanged<Clip>? onAudition;
  @override
  State<ClipEditor> createState() => _ClipEditorState();
}

class _ClipEditorState extends State<ClipEditor> {
  late final Clip clip = Clip.fromJson(widget.original.toJson());
  late final name = TextEditingController(text: clip.name);
  late final start = TextEditingController(text: _seconds(clip.start));
  late final trim = TextEditingController(text: _seconds(clip.trim));
  late final end =
      TextEditingController(text: _seconds(clip.trim + clip.length));
  String? error;

  String _seconds(int frame) => (frame / sampleRate)
      .toStringAsFixed(5)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  int? _frame(TextEditingController c) {
    final value = double.tryParse(c.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value < 0 || value > 24 * 3600)
      return null;
    return frameAt(value);
  }

  @override
  void dispose() {
    for (final c in [name, start, trim, end]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final a = _frame(start), b = _frame(trim), d = _frame(end);
    String? message;
    if (name.text.trim().isEmpty) {
      message = 'Give the clip a name.';
    } else if (a == null || b == null || d == null) {
      message = 'Enter a valid time in seconds.';
    } else if (d <= b || d > clip.frames) {
      message =
          'Source out must follow source in and fit within ${_seconds(clip.frames)} s.';
    } else if (a + d - b > frameAt(24 * 3600)) {
      message = 'That placement exceeds 24 hours.';
    } else {
      clip.name = name.text.trim();
      clip.start = a;
      clip.trim = b;
      clip.length = d - b;
      Navigator.pop(context, clip);
      return;
    }
    setState(() => error = message);
  }

  void _audition() {
    if (widget.onAudition == null) return;
    final a = _frame(start), b = _frame(trim), d = _frame(end);
    if (a == null || b == null || d == null || d <= b || d > clip.frames)
      return;
    clip.start = a;
    clip.trim = b;
    clip.length = d - b;
    widget.onAudition!(clip);
  }

  Widget _field(String title, TextEditingController controller,
          {bool numeric = true}) =>
      TextField(
          controller: controller,
          onChanged: numeric ? (_) => _audition() : null,
          maxLength: numeric ? null : 120,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          decoration: InputDecoration(
              labelText: title,
              suffixText: numeric ? 's' : null,
              counterText: ''));

  Widget _slider(String title, double value, double min, double max,
          ValueChanged<double> set) =>
      Column(children: [
        Row(children: [
          Expanded(child: Text(title)),
          Text(gainLabel(value),
              style: TextStyle(
                  color: tone(clip.type),
                  fontFamily: 'monospace',
                  fontSize: 12))
        ]),
        Slider(
            min: min,
            max: max,
            divisions: ((max - min) * 2).round(),
            value: value.clamp(min, max),
            activeColor: tone(clip.type),
            onChanged: (v) {
              setState(() => set(v));
              _audition();
            }),
      ]);

  @override
  Widget build(BuildContext context) => SafeArea(
      child: Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 24),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(glyph(clip.type), color: tone(clip.type)),
                      const SizedBox(width: 10),
                      const Expanded(
                          child: Text('Edit clip',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w600))),
                      IconButton(
                          onPressed: () => Navigator.pop(context),
                          tooltip: 'Close editor',
                          icon: const Icon(Icons.close))
                    ]),
                    const SizedBox(height: 14),
                    _field('Clip name', name, numeric: false),
                    const SizedBox(height: 14),
                    _field('Start on timeline', start),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(child: _field('Source in', trim)),
                      const SizedBox(width: 12),
                      Expanded(child: _field('Source out', end))
                    ]),
                    const SizedBox(height: 18),
                    _slider('Clip level', clip.gain, minClipGain, maxClipGain,
                        (v) => clip.gain = v),
                    if (clip.type == LayerType.voice) ...[
                      const Divider(),
                      const SizedBox(height: 10),
                      const Text('Voice tone',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 5),
                      const Text('Shape the low and high frequencies by ear.',
                          style: TextStyle(color: softText, fontSize: 13)),
                      const SizedBox(height: 16),
                      _slider('Warmth', clip.warmth, -12, 12,
                          (v) => clip.warmth = v),
                      _slider('Presence', clip.presence, -12, 12,
                          (v) => clip.presence = v),
                    ],
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(error!,
                              style: const TextStyle(color: apricot))),
                    FilledButton(
                        onPressed: _apply, child: const Text('Apply changes')),
                  ]))));
}
