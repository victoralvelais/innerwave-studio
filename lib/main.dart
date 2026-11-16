import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'clip_editor.dart';
import 'audio_codecs.dart';
import 'export_sheet.dart';
import 'model.dart';
import 'studio.dart';
import 'studio_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InnerwaveApp());
}

class InnerwaveApp extends StatelessWidget {
  const InnerwaveApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'Innerwave Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: ink,
        colorScheme: const ColorScheme.dark(
            primary: mint,
            onPrimary: Color(0xff102820),
            surface: panel,
            onSurface: Color(0xfff1f5f7),
            secondary: violet,
            outline: line),
        appBarTheme: const AppBarTheme(
            backgroundColor: ink, surfaceTintColor: Colors.transparent),
        dividerTheme: const DividerThemeData(color: line),
        bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: panel, showDragHandle: true),
        inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: ink,
            border: OutlineInputBorder(
                borderSide: const BorderSide(color: line),
                borderRadius: BorderRadius.circular(10))),
        outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: line),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)))),
        filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11)))),
      ),
      home: const StudioPage());
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> with WidgetsBindingObserver {
  final engine = Studio();
  ExportSettings exportSettings = const ExportSettings(ExportFormat.wav);
  Timer? timer;
  StreamSubscription<dynamic>? interruptions, unplug;
  String? selected, failure, busy;
  bool suspendAfterWork = false;
  Clip? get clip => engine.mix.clips.where((c) => c.id == selected).firstOrNull;
  bool get editable => busy == null && !engine.recording;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      await engine.init();
      selected = engine.mix.clips.firstOrNull?.id;
      engine.onTransportChanged = () {
        if (mounted) setState(() {});
      };
      interruptions = engine.session.interruptionEventStream.listen((event) {
        if (event.begin) _suspend();
      });
      unplug =
          engine.session.becomingNoisyEventStream.listen((_) => _suspend());
      timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        if (engine.playbackError != null) {
          _message(engine.playbackError!);
          engine.playbackError = null;
          _suspend();
        }
        if (engine.playing || engine.recording) setState(() {});
      });
      failure = null;
    } catch (e) {
      failure = _describe(e);
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && busy == null) _suspend();
  }

  void _suspend() {
    if (!mounted || !engine.initialized) return;
    if (busy != null) {
      suspendAfterWork = true;
    } else if (engine.recording) {
      _stopTake();
    } else if (engine.playing) {
      _run('Pausing', engine.pause);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    engine.onTransportChanged = null;
    interruptions?.cancel();
    unplug?.cancel();
    unawaited(engine.dispose());
    super.dispose();
  }

  String _describe(Object e) => e is FormatException ? e.message : e.toString();
  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  Future<void> _run(String status, Future<void> Function() work) async {
    if (busy != null) return;
    setState(() => busy = status);
    try {
      await work();
    } catch (e) {
      _message(_describe(e));
    } finally {
      if (mounted) {
        setState(() => busy = null);
        if (suspendAfterWork ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.paused) {
          suspendAfterWork = false;
          _suspend();
        }
      }
    }
  }

  Future<String?> _name(String heading, String initial) async {
    var value = initial;
    return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(heading),
                content: TextFormField(
                    initialValue: initial,
                    autofocus: true,
                    maxLength: 80,
                    decoration:
                        const InputDecoration(labelText: 'Session name'),
                    onChanged: (s) => value = s,
                    onFieldSubmitted: (s) {
                      if (s.trim().isNotEmpty) Navigator.pop(ctx, s.trim());
                    }),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        if (value.trim().isNotEmpty)
                          Navigator.pop(ctx, value.trim());
                      },
                      child: const Text('Save'))
                ]));
  }

  void _library() => _run('Opening sessions', () async {
        await engine.pause();
        final list = await engine.library();
        if (!mounted) return;
        final choice = await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
                    child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                        children: [
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Your sessions',
                              style: TextStyle(
                                  fontSize: 23, fontWeight: FontWeight.w600))),
                      for (final m in list)
                        ListTile(
                            leading: const Icon(Icons.album_outlined),
                            title: Text(m.name),
                            subtitle: Text(
                                '${m.clips.length} layers · ${timeOf(m.end)}'),
                            trailing: m.id == engine.mix.id
                                ? const Icon(Icons.check, color: mint)
                                : null,
                            onTap: () => Navigator.pop(ctx, m.id)),
                      const Divider(),
                      ListTile(
                          leading: const Icon(Icons.add, color: mint),
                          title: const Text('New empty session'),
                          onTap: () => Navigator.pop(ctx, '+')),
                    ])));
        if (choice == '+' && mounted) {
          final name = await _name('New session', 'Untitled session');
          if (name == null) return;
          await engine.create(name);
        } else if (choice != null) {
          await engine.open(choice);
        }
        selected = engine.mix.clips.firstOrNull?.id;
      });

  void _rename() => _run('Renaming session', () async {
        if (!mounted) return;
        final name = await _name('Rename session', engine.mix.name);
        if (name == null) return;
        engine.mix.name = name;
        await engine.save();
      });

  void _addLayer() => _run('Adding a layer', () async {
        await engine.pause();
        if (!mounted) return;
        final type = await showModalBottomSheet<LayerType>(
            context: context,
            builder: (ctx) => SafeArea(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                          child: Text('Import a layer',
                              style: TextStyle(fontSize: 22))),
                      Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                          child: Text(
                              'Place a file at ${timeOf(engine.cursor, fraction: true)}.',
                              style: const TextStyle(color: softText))),
                      for (final t in LayerType.values)
                        ListTile(
                            leading: Icon(glyph(t), color: tone(t)),
                            title: Text(t == LayerType.voice
                                ? 'Prerecorded affirmation'
                                : t.label),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => Navigator.pop(ctx, t)),
                      const SizedBox(height: 12),
                    ])));
        if (type == null) return;
        if (await engine.importClip(type)) selected = engine.mix.clips.last.id;
      });

  void _edit(Clip selectedClip) => _run('Editing clip', () async {
        if (!mounted) return;
        final changed = await showModalBottomSheet<Clip>(
            context: context,
            isScrollControlled: true,
            builder: (_) => ClipEditor(
                original: selectedClip, onAudition: engine.audition));
        if (changed == null) {
          engine.audition(null);
          return;
        }
        engine.mix
                .clips[engine.mix.clips.indexWhere((c) => c.id == changed.id)] =
            changed;
        engine.cursor = engine.cursor.clamp(0, engine.mix.end);
        await engine.save();
      });

  void _clipAction(String action, Clip c) => _run('Updating clip', () async {
        if (action == 'mute') {
          c.muted = !c.muted;
        } else if (action == 'copy') {
          final copy = Clip.fromJson({
            ...c.toJson(),
            'id': makeId(),
            'start': c.end,
            'name': '${c.name} (copy)'
          });
          engine.mix.clips.add(copy);
          selected = copy.id;
        } else {
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                      title: const Text('Remove this layer?'),
                      content: Text(c.name),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Keep')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Remove'))
                      ]));
          if (confirmed != true) return;
          engine.mix.removeLayer(c);
          selected = engine.mix.clips.firstOrNull?.id;
        }
        engine.cursor = engine.cursor.clamp(0, engine.mix.end);
        await engine.save();
      });

  void _record() => _run('Preparing microphone', engine.record);
  void _stopTake() => _run('Saving voice take', () async {
        await engine.finishTake();
        selected = engine.mix.clips.last.id;
        _message(
            'Voice take added at ${timeOf(engine.cursor, fraction: true)}.');
      });

  void _export() => _run('Preparing export', () async {
        await engine.pause();
        if (!mounted) return;
        final settings = await showModalBottomSheet<ExportSettings>(
            context: context,
            isScrollControlled: true,
            builder: (_) =>
                ExportSheet(initial: exportSettings, frames: engine.mix.end));
        if (settings == null || !mounted) return;
        setState(() {
          exportSettings = settings;
          busy = 'Rendering ${settings.format.label}';
        });
        final output = await engine.exportMix(settings);
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(ShareParams(
            files: [XFile(output.path, mimeType: settings.format.mimeType)],
            title: 'Export stereo ${settings.format.label}',
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size));
      });

  Widget _inspector(Clip c) => Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(13)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: tone(c.type).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(glyph(c.type), size: 19, color: tone(c.type))),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(c.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${c.type.label}  ·  ${c.gain.toStringAsFixed(1)} dB',
                    style: const TextStyle(fontSize: 12, color: softText)),
              ])),
          IconButton(
              tooltip: c.muted ? 'Unmute clip' : 'Mute clip',
              onPressed: editable ? () => _clipAction('mute', c) : null,
              icon: Icon(
                  c.muted
                      ? Icons.volume_off_outlined
                      : Icons.volume_up_outlined,
                  size: 20)),
          PopupMenuButton<String>(
              enabled: editable,
              tooltip: 'More clip options',
              onSelected: (s) => _clipAction(s, c),
              itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'copy', child: Text('Duplicate after clip')),
                    PopupMenuItem(value: 'remove', child: Text('Remove layer'))
                  ]),
        ]),
        const Padding(
            padding: EdgeInsets.only(right: 10), child: Divider(height: 21)),
        Row(children: [
          Expanded(
              child: Text('Start  ${timeOf(c.start, fraction: true)}',
                  style: const TextStyle(fontSize: 12, color: softText))),
          Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                  onPressed: editable ? () => _edit(c) : null,
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('Edit clip'))),
        ]),
      ]));

  Widget _transport() {
    final rec = engine.recording, p = engine.playing;
    return Container(
        decoration: const BoxDecoration(
            color: panel, border: Border(top: BorderSide(color: line))),
        child: SafeArea(
            top: false,
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900),
                        child: Row(children: [
                          Expanded(
                              child: Semantics(
                                  label: 'Playhead',
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            rec
                                                ? 'RECORDING'
                                                : p
                                                    ? 'PLAYING'
                                                    : 'PLAYHEAD',
                                            style: TextStyle(
                                                color: rec ? apricot : softText,
                                                letterSpacing: 1.2,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w600)),
                                        FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                                timeOf(engine.liveFrame,
                                                    fraction: true),
                                                style: const TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 20))),
                                      ]))),
                          IconButton(
                              tooltip: 'Go to start',
                              onPressed: editable
                                  ? () => _run('Seeking', () => engine.seek(0))
                                  : null,
                              icon: const Icon(Icons.skip_previous_rounded)),
                          IconButton.filled(
                              tooltip: p ? 'Pause mix' : 'Play mix',
                              onPressed: editable && engine.mix.end > 0
                                  ? () => _run(
                                      p ? 'Pausing' : 'Preparing playback',
                                      p ? engine.pause : engine.play)
                                  : null,
                              icon: Icon(p
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded),
                              style: IconButton.styleFrom(
                                  fixedSize: const Size(48, 44),
                                  backgroundColor: mint,
                                  foregroundColor: ink)),
                          const SizedBox(width: 7),
                          OutlinedButton.icon(
                              onPressed: busy == null
                                  ? (rec ? _stopTake : _record)
                                  : null,
                              icon: Icon(
                                  rec
                                      ? Icons.stop_rounded
                                      : Icons.fiber_manual_record,
                                  color: apricot,
                                  size: 15),
                              label: Text(rec ? 'Stop' : 'Record')),
                        ]))))));
  }

  @override
  Widget build(BuildContext context) {
    final ready = engine.initialized;
    return Scaffold(
        appBar: AppBar(
            titleSpacing: 17,
            title: const Row(children: [
              Icon(Icons.graphic_eq_rounded, color: mint, size: 24),
              SizedBox(width: 7),
              Text('Innerwave',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.6,
                      fontSize: 21))
            ]),
            actions: [
              IconButton(
                  tooltip: 'Your sessions',
                  onPressed: ready && editable ? _library : null,
                  icon: const Icon(Icons.folder_open_rounded)),
              Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TextButton.icon(
                      onPressed: ready && editable && engine.mix.end > 0
                          ? _export
                          : null,
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('Export'))),
            ]),
        bottomNavigationBar: ready ? _transport() : null,
        body: !ready
            ? Center(
                child: failure == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(failure!),
                          TextButton(
                              onPressed: () {
                                setState(() => failure = null);
                                _init();
                              },
                              child: const Text('Try again')),
                        ])))
            : SafeArea(
                top: false,
                bottom: false,
                child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 940),
                        child: ListView(
                            padding: const EdgeInsets.fromLTRB(15, 5, 15, 20),
                            children: [
                              SessionHeader(
                                  mix: engine.mix,
                                  onRename: editable ? _rename : null),
                              const SizedBox(height: 17),
                              Row(children: [
                                const Expanded(
                                    child: Text('Arrangement',
                                        style: TextStyle(
                                            fontSize: 20,
                                            letterSpacing: -.5,
                                            fontWeight: FontWeight.w600))),
                                OutlinedButton.icon(
                                    onPressed: editable ? _addLayer : null,
                                    icon: const Icon(Icons.add, size: 16),
                                    label: const Text('Add layer'))
                              ]),
                              const SizedBox(height: 8),
                              Arrangement(
                                  mix: engine.mix,
                                  cursor: engine.liveFrame,
                                  selected: selected,
                                  enabled: editable,
                                  onSelect: (c) =>
                                      setState(() => selected = c.id),
                                  onRecord: _record,
                                  onSeek: (n) =>
                                      _run('Seeking', () => engine.seek(n)),
                                  onDragPreview: (c, n) {
                                    if (engine.playing)
                                      engine.audition(n == null
                                          ? null
                                          : Clip.fromJson(
                                              {...c.toJson(), 'start': n}));
                                  },
                                  onMove: (c, n) =>
                                      _run('Moving clip', () async {
                                        c.start = n;
                                        engine.cursor = engine.cursor
                                            .clamp(0, engine.mix.end);
                                        await engine.save();
                                      })),
                              if (engine.mix.removed.isNotEmpty)
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                        onPressed: editable
                                            ? () => _run('Restoring layer',
                                                    () async {
                                                  selected = engine.mix
                                                      .restoreLayer()
                                                      .id;
                                                  await engine.save();
                                                })
                                            : null,
                                        icon: const Icon(Icons.undo_rounded,
                                            size: 17),
                                        label:
                                            const Text('Undo layer removal'))),
                              if (clip case final c?) ...[
                                const SizedBox(height: 20),
                                const Text('Selected clip',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 10),
                                _inspector(c)
                              ],
                              if (busy != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Row(children: [
                                      const SizedBox.square(
                                          dimension: 13,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 1.6)),
                                      const SizedBox(width: 8),
                                      Text('$busy…',
                                          style: const TextStyle(
                                              color: softText, fontSize: 12))
                                    ])),
                            ])))));
  }
}
