import 'dart:math' as math;
import 'dart:ui' as ui show Clip;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'model.dart';

const ink = Color(0xff0c1118);
const panel = Color(0xff131b25);
const line = Color(0xff2a3440);
const softText = Color(0xffa3afba);
const mint = Color(0xff85e7cb);
const violet = Color(0xffb5a3f1);
const apricot = Color(0xffefa986);
const minClipGain = -60.0;
const maxClipGain = 6.0;

String gainLabel(double gain) => gain <= silentGainDb
    ? 'Silence'
    : '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(1)} dB';

Color tone(LayerType type) => switch (type) {
      LayerType.beat => mint,
      LayerType.texture => violet,
      LayerType.voice => apricot,
    };

IconData glyph(LayerType type) => switch (type) {
      LayerType.beat => Icons.graphic_eq_rounded,
      LayerType.texture => Icons.water_rounded,
      LayerType.voice => Icons.mic_none_rounded,
    };

String timeOf(int frames, {bool fraction = false}) {
  final ticks = (frames * 100 ~/ sampleRate).abs();
  final seconds = ticks ~/ 100;
  final base =
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  return fraction ? '$base.${(ticks % 100).toString().padLeft(2, '0')}' : base;
}

class OrbitArt extends CustomPainter {
  @override
  void paint(Canvas c, Size size) {
    final center = Offset(size.width * .78, size.height * .53);
    final scale = math.min(size.width * .30, size.height * .73);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85;
    final glow = Rect.fromCircle(center: center, radius: scale * 1.65);
    c.drawRect(
        glow,
        Paint()
          ..shader = const RadialGradient(
                  colors: [Color(0x333dae91), Color(0x00244b42)])
              .createShader(glow));
    c.save();
    c.translate(center.dx, center.dy);
    c.rotate(-.37);
    // Two sets of nested contours fan out around a common axis.
    for (int j = 0; j < 40; j++) {
      final q = j / 39;
      paint.color =
          Color.lerp(const Color(0xff64d1ba), const Color(0xff8d9be3), q)!
              .withValues(alpha: .83 - .46 * q);
      final path = Path();
      for (int i = 0; i <= 160; i++) {
        final a = i / 160 * math.pi * 2;
        final r = scale *
            (.30 + .70 * q) *
            (1 + .17 * math.sin(3 * a + q * 5) + .10 * math.cos(2 * a - q * 4));
        final x =
            r * math.cos(a) * (1.13 + .24 * q) + scale * .30 * math.sin(6 * q);
        final y =
            r * math.sin(a) * (.60 + .20 * q) + scale * .16 * math.cos(5 * q);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      c.drawPath(path..close(), paint);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(OrbitArt oldDelegate) => false;
}

class SessionHeader extends StatelessWidget {
  const SessionHeader({super.key, required this.mix, required this.onRename});
  final Mix mix;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: DecoratedBox(
          decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [
                Color(0xff1b302f),
                Color(0xff172b32),
                Color(0xff1b2432)
              ]),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xff314441))),
          child: SizedBox(
              height: 145,
              width: double.infinity,
              child: Stack(children: [
                Positioned.fill(child: CustomPaint(painter: OrbitArt())),
                Positioned.fill(
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                  const Color(0xff1b302f),
                  const Color(0xff1b302f).withValues(alpha: .95),
                  const Color(0x001b302f)
                ], stops: const [
                  0,
                  .37,
                  .72
                ])))),
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 17, 12, 14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Row(children: [
                            Icon(Icons.album_outlined, size: 15, color: mint),
                            SizedBox(width: 7),
                            Text('CURRENT SESSION',
                                style: TextStyle(
                                    color: mint,
                                    fontSize: 10,
                                    letterSpacing: 1.7,
                                    fontWeight: FontWeight.w700))
                          ]),
                          const SizedBox(height: 8),
                          FractionallySizedBox(
                              widthFactor: .78,
                              child: InkWell(
                                  onTap: onRename,
                                  child: Text(mix.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 29,
                                          height: 1.04,
                                          letterSpacing: -1.0,
                                          fontWeight: FontWeight.w600)))),
                          const SizedBox(height: 10),
                          Text(
                              '${mix.clips.length} ${mix.clips.length == 1 ? 'layer' : 'layers'}   ·   ${timeOf(mix.end)}   ·   Stereo',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xffc3d2d1))),
                        ])),
              ]))));
}

class Arrangement extends StatefulWidget {
  const Arrangement(
      {super.key,
      required this.mix,
      required this.cursor,
      required this.selected,
      required this.onSelect,
      required this.onSeek,
      required this.onMove,
      required this.onGainChanged,
      required this.onGainEnd,
      this.onLoopRange,
      this.loopStart,
      this.loopEnd,
      this.onDragPreview,
      required this.onRecord,
      required this.enabled});
  final Mix mix;
  final int cursor;
  final String? selected;
  final void Function(Clip) onSelect;
  final void Function(int) onSeek;
  final void Function(Clip, int) onMove;
  final void Function(Clip, double) onGainChanged;
  final VoidCallback onGainEnd;
  final ValueChanged<String>? onLoopRange;
  final int? loopStart, loopEnd;
  final void Function(Clip, int?)? onDragPreview;
  final VoidCallback onRecord;
  final bool enabled;

  @override
  State<Arrangement> createState() => _ArrangementState();
}

class _ArrangementState extends State<Arrangement> {
  int zoom = 0;
  int origin = 0;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, bounds) {
        final w = widget, mix = w.mix, cursor = w.cursor, enabled = w.enabled;
        final gutter = bounds.maxWidth > 650
            ? 130.0
            : bounds.maxWidth < 350
                ? 66.0
                : 80.0;
        final width = math.max(1.0, bounds.maxWidth - gutter - 2);
        final seconds = math.max(math.max(mix.end, cursor) / sampleRate, 12.0);
        final magnitude = math
            .pow(10, (math.log(seconds / 4) / math.ln10).floor())
            .toDouble();
        final step =
            [1, 2, 3, 5, 10].firstWhere((n) => n * magnitude >= seconds / 4) *
                magnitude;
        final extent = frameAt(step * 4);
        int window(int level) =>
            math.max(sampleRate ~/ 4, (extent / (1 << level)).round());
        final span = window(zoom);
        final maxOrigin = extent - span;
        final first = origin.clamp(0, maxOrigin);
        final cursorX = width * (cursor - first) / span;
        final showVoice = !mix.clips.any((c) => c.type == LayerType.voice);
        int frame(double x) =>
            (first + x / width * span).round().clamp(0, extent);
        void zoomTo(int level) {
          final nextSpan = window(level);
          final relative = cursor >= first && cursor <= first + span
              ? (cursor - first) / span
              : .5;
          setState(() {
            zoom = level;
            origin = (cursor - relative * nextSpan)
                .round()
                .clamp(0, extent - nextSpan);
          });
        }

        final intervals = width < 370 ? 2 : 4;
        final loopStart = w.loopStart, loopEnd = w.loopEnd;
        final timeline = ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
                decoration: BoxDecoration(
                    border: Border.all(color: line),
                    borderRadius: BorderRadius.circular(12),
                    color: panel),
                child: Stack(children: [
                  Positioned.fill(
                      left: gutter,
                      child: CustomPaint(painter: _GridPainter())),
                  if (loopStart != null &&
                      loopEnd != null &&
                      loopStart < first + span &&
                      loopEnd > first)
                    Positioned(
                        left: gutter +
                            ((loopStart - first) / span).clamp(0, 1) * width,
                        right:
                            (1 - (loopEnd - first) / span).clamp(0, 1) * width,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                            child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: mint.withValues(alpha: .035),
                                    border: Border(
                                        top: BorderSide(
                                            color: mint.withValues(alpha: .65),
                                            width: 2)))))),
                  if (cursorX >= 0 && cursorX <= width)
                    Positioned(
                        top: 26,
                        bottom: 0,
                        left: gutter + cursorX,
                        child: const _PlayheadLine()),
                  Column(children: [
                    Row(children: [
                      SizedBox(
                          width: gutter,
                          child: const Padding(
                              padding: EdgeInsets.only(left: 10),
                              child: Text('LAYER',
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: softText,
                                      letterSpacing: 1.1)))),
                      Expanded(
                          child: Semantics(
                              label: 'Seek on timeline ruler',
                              child: GestureDetector(
                                  key: const ValueKey('timeline-ruler'),
                                  dragStartBehavior: DragStartBehavior.down,
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: enabled
                                      ? (d) =>
                                          w.onSeek(frame(d.localPosition.dx))
                                      : null,
                                  onHorizontalDragUpdate: zoom == 0
                                      ? null
                                      : (d) => setState(() => origin =
                                          (origin.clamp(0, maxOrigin) -
                                                  d.delta.dx / width * span)
                                              .round()
                                              .clamp(0, maxOrigin)),
                                  child: SizedBox(
                                      height: 34,
                                      child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children:
                                              List.generate(intervals + 1, (i) => Text(timeOf(first + span * i ~/ intervals, fraction: zoom > 0), style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: softText)))))))),
                    ]),
                    for (final clip in mix.clips)
                      _Track(
                          key: ValueKey(clip.id),
                          clip: clip,
                          gutter: gutter,
                          width: width,
                          span: span,
                          extent: extent,
                          origin: first,
                          cursorX: cursorX,
                          active: clip.id == w.selected,
                          enabled: enabled,
                          onSelect: () => w.onSelect(clip),
                          onMove: (n) => w.onMove(clip, n),
                          onGainChanged: (value) =>
                              w.onGainChanged(clip, value),
                          onGainEnd: w.onGainEnd,
                          onDragPreview: (n) => w.onDragPreview?.call(clip, n),
                          onSeek: (x) => w.onSeek(frame(x))),
                    if (showVoice)
                      Container(
                          height: 56,
                          decoration: const BoxDecoration(
                              border: Border(top: BorderSide(color: line))),
                          child: Row(children: [
                            SizedBox(
                                width: gutter,
                                child: const Padding(
                                    padding: EdgeInsets.only(left: 9),
                                    child: Row(children: [
                                      Icon(Icons.mic_none_rounded,
                                          size: 15, color: apricot),
                                      SizedBox(width: 3),
                                      Flexible(
                                          child: Text('Voice',
                                              style: TextStyle(fontSize: 11)))
                                    ]))),
                            TextButton.icon(
                                onPressed: enabled ? w.onRecord : null,
                                icon: const Icon(Icons.add, size: 15),
                                label: const Text('Record a take',
                                    style: TextStyle(fontSize: 12))),
                          ])),
                  ]),
                ])));
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          key: const ValueKey('zoom-out'),
                          tooltip: 'Zoom out',
                          onPressed: zoom > 0 ? () => zoomTo(zoom - 1) : null,
                          icon: const Icon(Icons.zoom_out_rounded)),
                      Text('${(extent / span).round()}×',
                          style:
                              const TextStyle(color: softText, fontSize: 12)),
                      IconButton(
                          key: const ValueKey('zoom-in'),
                          tooltip: 'Zoom in',
                          onPressed: zoom < 25 && window(zoom + 1) < span
                              ? () => zoomTo(zoom + 1)
                              : null,
                          icon: const Icon(Icons.zoom_in_rounded)),
                      TextButton(
                          key: const ValueKey('zoom-fit'),
                          onPressed: zoom > 0 ? () => zoomTo(0) : null,
                          child: const Text('Fit')),
                    ]),
                    PopupMenuButton<String>(
                        key: const ValueKey('loop-range'),
                        tooltip: 'Loop range',
                        enabled:
                            enabled && w.onLoopRange != null && mix.end > 0,
                        onSelected: w.onLoopRange,
                        child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('A/B'),
                                  Icon(Icons.arrow_drop_down, size: 18)
                                ])),
                        itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'a', child: Text('Set A at playhead')),
                              PopupMenuItem(
                                  value: 'b', child: Text('Set B at playhead')),
                              PopupMenuItem(
                                  value: 'all',
                                  child: Text('Use whole timeline')),
                            ]),
                  ]),
              if (loopStart != null && loopEnd != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                        'Loop range   A ${timeOf(loopStart, fraction: true)}   B ${timeOf(loopEnd, fraction: true)}',
                        style: const TextStyle(fontSize: 12, color: mint))),
              timeline,
              if (maxOrigin > 0)
                Row(children: [
                  const Icon(Icons.swap_horiz_rounded,
                      size: 18, color: softText),
                  Expanded(
                      child: Semantics(
                          label: 'Pan timeline',
                          child: Slider(
                            key: const ValueKey('timeline-pan'),
                            min: 0,
                            max: maxOrigin.toDouble(),
                            value: first.toDouble(),
                            semanticFormatterCallback: (n) =>
                                timeOf(n.round(), fraction: true),
                            onChanged: (n) =>
                                setState(() => origin = n.round()),
                          ))),
                ]),
            ]);
      });
}

class _PlayheadLine extends StatelessWidget {
  const _PlayheadLine();
  @override
  Widget build(BuildContext context) => const IgnorePointer(
      child: SizedBox(width: 1.5, child: ColoredBox(color: Color(0xffe5f7f1))));
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..strokeWidth = .7;
    for (int i = 0; i < 16; i++) {
      p.color = i % 4 == 0 ? line : const Color(0xff1d2731);
      final x = size.width * i / 16;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}

class _Track extends StatefulWidget {
  const _Track(
      {super.key,
      required this.clip,
      required this.gutter,
      required this.width,
      required this.span,
      required this.extent,
      required this.origin,
      required this.cursorX,
      required this.active,
      required this.enabled,
      required this.onSelect,
      required this.onMove,
      required this.onGainChanged,
      required this.onGainEnd,
      required this.onDragPreview,
      required this.onSeek});
  final Clip clip;
  final double gutter, width;
  final int span;
  final int extent, origin;
  final double cursorX;
  final bool active, enabled;
  final VoidCallback onSelect;
  final ValueChanged<int> onMove;
  final ValueChanged<double> onGainChanged;
  final VoidCallback onGainEnd;
  final ValueChanged<int?> onDragPreview;
  final ValueChanged<double> onSeek;
  @override
  State<_Track> createState() => _TrackState();
}

class _TrackState extends State<_Track> {
  double? delta;
  int get start =>
      (widget.clip.start + (delta ?? 0) * widget.span / widget.width)
          .round()
          .clamp(0, widget.extent - 1);
  @override
  Widget build(BuildContext context) {
    final w = widget, c = w.clip, color = tone(c.type);
    final first = math.max(start, w.origin);
    final last = math.min(start + c.length, w.origin + w.span);
    final left = ((first - w.origin) / w.span * w.width).clamp(0.0, w.width);
    final length = ((last - first) / w.span * w.width)
        .clamp(2.0, math.max(2.0, w.width))
        .toDouble();
    final waveform = Container(
        height: 65,
        decoration:
            const BoxDecoration(border: Border(top: BorderSide(color: line))),
        child: Row(children: [
          InkWell(
              onTap: w.onSelect,
              child: SizedBox(
                  width: w.gutter,
                  child: Padding(
                      padding: const EdgeInsets.only(left: 9),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                                c.muted
                                    ? Icons.volume_off_outlined
                                    : glyph(c.type),
                                size: 17,
                                color: color),
                            const SizedBox(height: 3),
                            Text(
                                switch (c.type) {
                                  LayerType.beat => 'Beats',
                                  LayerType.texture => 'ASMR',
                                  LayerType.voice => 'Voice',
                                },
                                style: const TextStyle(
                                    fontSize: 11, color: softText))
                          ])))),
          Expanded(
              child: Stack(children: [
            Positioned.fill(
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: w.enabled
                        ? (d) => w.onSeek(d.localPosition.dx)
                        : null)),
            if (last <= first && delta == null)
              Positioned.fill(
                  child: IgnorePointer(
                      child: Align(
                alignment: start >= w.origin + w.span
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: softText, fontSize: 11))),
              ))),
            if (last > first || delta != null)
              Positioned(
                  left: left,
                  top: 7,
                  bottom: 7,
                  width: length,
                  child: Semantics(
                      button: true,
                      label: 'Select ${c.name}',
                      child: GestureDetector(
                          dragStartBehavior: DragStartBehavior.down,
                          onTap: w.onSelect,
                          onHorizontalDragStart: w.enabled
                              ? (_) {
                                  w.onSelect();
                                  setState(() => delta = 0);
                                }
                              : null,
                          onHorizontalDragUpdate: w.enabled
                              ? (d) {
                                  setState(
                                      () => delta = (delta ?? 0) + d.delta.dx);
                                  w.onDragPreview(start);
                                }
                              : null,
                          onHorizontalDragCancel: () {
                            setState(() => delta = null);
                            w.onDragPreview(null);
                          },
                          onHorizontalDragEnd: w.enabled
                              ? (_) {
                                  final value = start;
                                  setState(() => delta = null);
                                  w.onMove(value);
                                }
                              : null,
                          child: Opacity(
                              opacity: c.muted ? .4 : 1,
                              child: Container(
                                  clipBehavior: ui.Clip.hardEdge,
                                  decoration: BoxDecoration(
                                      color: Color.alphaBlend(
                                          color.withValues(alpha: .15), panel),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: color.withValues(
                                              alpha: w.active ? .95 : .50))),
                                  child: Stack(children: [
                                    Positioned(
                                        left: 5,
                                        right: 4,
                                        top: 3,
                                        child: Text(c.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: color,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600))),
                                    Positioned(
                                        left: 3,
                                        right: 3,
                                        top: 18,
                                        bottom: 3,
                                        child: CustomPaint(
                                            painter: _Wave(
                                                c.peaks,
                                                (c.trim + first - start) /
                                                    c.frames,
                                                math.max(0, last - first) /
                                                    c.frames,
                                                color))),
                                  ])))))),
            if (last > first && w.cursorX >= left && w.cursorX <= left + length)
              Positioned(
                  top: 7,
                  bottom: 7,
                  left: w.cursorX,
                  child: const _PlayheadLine()),
          ])),
        ]));
    return Column(children: [
      waveform,
      ColoredBox(
        color: panel,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            const ExcludeSemantics(
                child: Text('Volume',
                    style: TextStyle(color: softText, fontSize: 12))),
            Expanded(
                child: MergeSemantics(
                    child: Semantics(
              label: '${c.name} volume',
              child: Slider(
                key: ValueKey('volume-${c.id}'),
                min: minClipGain,
                max: maxClipGain,
                divisions: ((maxClipGain - minClipGain) * 2).round(),
                value: c.gain.clamp(minClipGain, maxClipGain),
                label: gainLabel(c.gain),
                activeColor: color,
                semanticFormatterCallback: (value) =>
                    c.gain <= silentGainDb && value == minClipGain
                        ? 'Silence'
                        : '${value.toStringAsFixed(1)} decibels',
                onChanged: w.enabled ? w.onGainChanged : null,
                onChangeEnd: w.enabled ? (_) => w.onGainEnd() : null,
              ),
            ))),
            ExcludeSemantics(
                child: Text(gainLabel(c.gain),
                    style: TextStyle(
                        color: color, fontFamily: 'monospace', fontSize: 12))),
          ]),
        ),
      ),
    ]);
  }
}

class _Wave extends CustomPainter {
  _Wave(this.peaks, this.offset, this.fraction, this.color);
  final List<double> peaks;
  final double offset, fraction;
  final Color color;
  @override
  void paint(Canvas c, Size s) {
    if (peaks.isEmpty || s.width <= 0) return;
    final paint = Paint()
      ..color = color.withValues(alpha: .85)
      ..strokeWidth = 1.6;
    final top = peaks.fold(0.01, math.max);
    final mid = s.height / 2;
    for (double x = 1; x < s.width; x += 3) {
      final bin = ((offset + x / s.width * fraction) * peaks.length)
          .floor()
          .clamp(0, peaks.length - 1);
      final h = math.max(.7, peaks[bin] / top * mid);
      c.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_Wave old) =>
      old.peaks != peaks ||
      old.offset != offset ||
      old.fraction != fraction ||
      old.color != color;
}
