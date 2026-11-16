import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/clip_editor.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio_view.dart';

void main() {
  Clip voice() => Clip(
      id: 'v',
      source: 'v.pcm',
      name: 'Affirmation',
      type: LayerType.voice,
      frames: sampleRate * 5,
      length: sampleRate * 5,
      peaks: [.2, .7, .4]);

  testWidgets('phone timeline selects, scrubs and repositions a clip',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 760);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final clip = voice();
    final mix = Mix('id', 'Mix', [clip]);
    int selected = 0, seek = -1, move = -1;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Arrangement(
                mix: mix,
                cursor: 0,
                selected: null,
                enabled: true,
                onSelect: (_) => selected++,
                onSeek: (f) => seek = f,
                onMove: (_, f) => move = f,
                onGainChanged: (clip, gain) {},
                onGainEnd: () {},
                onRecord: () {}))));
    final clipName = find.text('Affirmation');
    await t.tap(clipName);
    expect(selected, 1);
    await t.drag(clipName, const Offset(60, 0));
    expect(move, greaterThan(0));
    await t.tap(find.byKey(const ValueKey('timeline-ruler')));
    expect(seek, greaterThan(0));
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'phone volume faders independently adjust real clip gains during the gesture',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 650);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final a = voice()..muted = true;
    final b = Clip.fromJson(
        {...a.toJson(), 'id': 'b', 'name': 'Rain', 'muted': false});
    final mix = Mix('session', 'Layers', [a, b]);
    var commits = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (_, set) => Arrangement(
                      mix: mix,
                      cursor: 0,
                      selected: a.id,
                      enabled: true,
                      onSelect: (_) {},
                      onRecord: () {},
                      onSeek: (_) {},
                      onMove: (clip, frame) {},
                      onGainChanged: (clip, value) =>
                          set(() => clip.gain = value),
                      onGainEnd: () => commits++,
                    )))));
    final aSlider = find.byKey(const ValueKey('volume-v')),
        bSlider = find.byKey(const ValueKey('volume-b'));
    expect(find.text('Volume'), findsNWidgets(2));
    expect(
        t
            .getSemantics(find.bySemanticsLabel('Affirmation volume'))
            .getSemanticsData()
            .value,
        '-3.0 decibels');
    final original = a.gain;
    final gesture = await t.startGesture(t.getCenter(aSlider));
    await gesture.moveBy(const Offset(-22, 0));
    await t.pump();
    expect(a.gain, lessThan(original));
    expect(b.gain, original);
    expect(a.muted, isTrue);
    expect(commits, 0);
    await gesture.up();
    await t.pump();
    expect(commits, 1);
    final savedA = a.gain;
    await t.tap(bSlider);
    await t.pump();
    expect(commits, 2);
    expect(b.gain, lessThan(original));
    expect(a.gain, savedA);
    expect(t.widget<Slider>(bSlider).value, b.gain);
    expect(find.text(gainLabel(b.gain)), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'zoom anchors on the playhead, pans, seeks and moves in timeline frames',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 760);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final clip = voice()..start = frameAt(4);
    final mix = Mix('id', 'Mix', [clip]);
    final cursor = frameAt(6);
    int seek = -1, moved = -1;
    String? marker;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Arrangement(
      mix: mix,
      cursor: cursor,
      selected: clip.id,
      enabled: true,
      onSelect: (_) {},
      onRecord: () {},
      onSeek: (f) => seek = f,
      onMove: (_, f) => moved = f,
      onGainChanged: (clip, gain) {},
      onGainEnd: () {},
      onLoopRange: (op) => marker = op,
      loopStart: frameAt(3),
      loopEnd: frameAt(9),
    ))));
    final ruler = find.byKey(const ValueKey('timeline-ruler'));
    final rect = t.getRect(ruler);
    // Full arrangement fits 12 seconds; the cursor is at the center.
    await t.tap(ruler);
    expect(seek, closeTo(cursor, 2));
    await t.tap(find.byKey(const ValueKey('zoom-in')));
    await t.pumpAndSettle();
    await t.tap(ruler);
    expect(seek, closeTo(cursor, 2));
    final prev = seek;
    await t.tapAt(Offset(rect.left + rect.width * .75, rect.center.dy));
    expect(seek - prev, closeTo(frameAt(1.5), 2));
    final pan = find.byKey(const ValueKey('timeline-pan'));
    final slider = t.widget<Slider>(pan);
    slider.onChanged!(0);
    await t.pump();
    await t.tap(ruler);
    expect(seek, closeTo(frameAt(3), 2));
    final clipLabel = find.text(clip.name);
    await t.drag(clipLabel, Offset(rect.width / 6, 0));
    expect(moved, closeTo(frameAt(5), frameAt(.05)));
    await t.drag(ruler, const Offset(-40, 0));
    await t.pump();
    expect(t.widget<Slider>(pan).value, greaterThan(0));
    await t.tap(find.byKey(const ValueKey('zoom-fit')));
    await t.pumpAndSettle();
    expect(pan, findsNothing);
    await t.tap(ruler);
    expect(seek, closeTo(cursor, 2));
    await t.tap(find.byTooltip('Loop range'));
    await t.pumpAndSettle();
    await t.tap(find.text('Set B at playhead'));
    await t.pumpAndSettle();
    expect(marker, 'b');
    expect(find.textContaining('A 00:03.00'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('voice inspector validates source trim and applies timing and EQ',
      (t) async {
    final original = voice();
    Clip? result;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async {
                      result = await showModalBottomSheet<Clip>(
                          context: ctx,
                          isScrollControlled: true,
                          builder: (_) => ClipEditor(original: original));
                    },
                    child: const Text('Edit'))))));
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    final fields = find.byType(TextField);
    await t.enterText(fields.at(1), '2.5');
    await t.enterText(fields.at(2), '1');
    await t.enterText(fields.at(3), '7');
    await t.ensureVisible(find.text('Apply changes'));
    await t.tap(find.text('Apply changes'));
    await t.pump();
    expect(find.textContaining('Source out must follow'), findsOneWidget);
    await t.enterText(fields.at(3), '4');
    final sliders = find.byType(Slider);
    expect(sliders, findsNWidgets(3));
    await t.ensureVisible(sliders.at(1));
    final slider = t.widget<Slider>(sliders.at(1));
    slider.onChanged!(6);
    await t.pump();
    await t.ensureVisible(find.text('Apply changes'));
    await t.tap(find.text('Apply changes'));
    await t.pumpAndSettle();
    expect(result!.start, frameAt(2.5));
    expect(result!.trim, frameAt(1));
    expect(result!.length, frameAt(3));
    expect(result!.warmth, 6);
    expect(original.warmth, 0);
  });
}
