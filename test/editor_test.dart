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
                onRecord: () {}))));
    final clipName = find.text('Affirmation');
    await t.tap(clipName);
    expect(selected, 1);
    await t.drag(clipName, const Offset(60, 0));
    expect(move, greaterThan(0));
    await t.tapAt(const Offset(200, 15));
    expect(seek, greaterThan(0));
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
