import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innerwave_studio/model.dart';
import 'package:innerwave_studio/studio.dart';
import 'package:innerwave_studio/tone_editor.dart';

class _Studio extends Fake implements Studio {
  @override
  final mix = Mix('s', 'Test', []);
  @override
  int cursor = 0;
  @override
  bool tonePreviewing = false;
  BeatTone? heard;
  double? level;
  Duration? limit;
  final slots = List<({String name, BeatTone tone})?>.filled(5, null);

  @override
  Future<void> setIndependent(LayerType layer, bool value) async {
    if (value) {
      mix.independentLayers.add(layer);
    } else {
      mix.independentLayers.remove(layer);
    }
  }

  @override
  Future<void> startTonePreview(BeatTone tone, double gainDb,
      {Duration? timer}) async {
    tonePreviewing = true;
    heard = tone;
    level = gainDb;
    limit = timer;
  }

  @override
  Future<void> updateTonePreview(BeatTone tone, double gainDb) async {
    heard = tone;
    level = gainDb;
  }

  @override
  Future<void> stopTonePreview() async {
    tonePreviewing = false;
  }

  @override
  Future<List<({String name, BeatTone tone})?>> loadTonePresets() async =>
      slots;
  @override
  Future<void> saveTonePreset(int index, String name, BeatTone tone) async {
    slots[index] = (name: name, tone: tone);
  }
}

Future<void> openPage(
    WidgetTester t, _Studio engine, void Function(ToneDraft?) receive,
    {Clip? existing}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(360, 760);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  child: const Text('Open generator'),
                  onPressed: () async {
                    receive(await Navigator.push<ToneDraft>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ToneEditor(
                                studio: engine, existing: existing))));
                  })))));
  await t.tap(find.text('Open generator'));
  await t.pumpAndSettle();
}

Future<void> enterFrequency(WidgetTester t, String title, String value) async {
  final control = find.byKey(ValueKey('exact-$title'));
  await t.ensureVisible(control);
  await t.tap(control);
  await t.pumpAndSettle();
  await t.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      value);
  await t.tap(find.text('Apply'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'linked frequencies allow exact entry, fine steps and named preset recall',
      (t) async {
    final engine = _Studio();
    ToneDraft? result;
    await openPage(t, engine, (d) => result = d);
    expect(find.text('Theta · 4 to below 8 Hz'), findsOneWidget);
    await enterFrequency(t, 'Beat frequency', '10');
    expect(find.text('Alpha · 8–13 Hz   /   Mu · 7–11 Hz'), findsOneWidget);
    await enterFrequency(t, 'Beat frequency', '12.34');
    final plus = find.byTooltip('Increase Beat frequency by 0.01 Hz');
    await t.ensureVisible(plus);
    await t.tap(plus);
    await t.pump();
    await t.tap(find.byTooltip('Tone presets'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Save to slot 5'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), 'Evening');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(engine.slots.last!.tone.beat, 12.35);
    final gamma = find.text('Gamma');
    await t.ensureVisible(gamma);
    await t.tap(gamma);
    await t.pump();
    await enterFrequency(t, 'Center frequency', '20');
    // 40 Hz spacing keeps the lower ear at or above 1 Hz.
    expect(find.text('21.00 Hz'), findsOneWidget);
    await t.tap(find.byTooltip('Tone presets'));
    await t.pumpAndSettle();
    await t.tap(find.text('Evening'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add to timeline'));
    await t.pumpAndSettle();
    expect(result!.tone.beat, 12.35);
    expect(result!.tone.base, 250);
    expect(result!.frames, frameAt(60));
    expect(t.takeException(), isNull);
  });

  testWidgets('independent ears can cross and change during a timed audition',
      (t) async {
    final engine = _Studio();
    ToneDraft? result;
    await openPage(t, engine, (d) => result = d);
    await t.tap(find.text('Independent ear frequencies'));
    await t.pumpAndSettle();
    expect(engine.mix.independent(LayerType.beat), isTrue);
    expect(engine.mix.independent(LayerType.voice), isFalse);
    await enterFrequency(t, 'Left ear', '252');
    expect(find.textContaining('No beat · Both ears'), findsOneWidget);
    await enterFrequency(t, 'Left ear', '333.33');
    await enterFrequency(t, 'Right ear', '222.22');
    expect(find.text('Outside the 1–50 Hz beat range'), findsOneWidget);
    final timer = find.byType(DropdownButton<int>);
    await t.scrollUntilVisible(timer, 230,
        scrollable: find.byType(Scrollable).first);
    await t.tap(timer);
    await t.pumpAndSettle();
    await t.tap(find.text('15 min').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('tone-preview')));
    await t.pumpAndSettle();
    expect(engine.limit, const Duration(minutes: 15));
    expect(engine.heard!.left, 333.33);
    expect(engine.heard!.right, 222.22);
    final input = find.widgetWithText(TextField, 'Timeline duration');
    await t.ensureVisible(input);
    await t.enterText(input, '12.5');
    final plus = find.byTooltip('Increase Right ear by 0.01 Hz');
    await t.ensureVisible(plus);
    await t.tap(plus);
    await t.pump();
    expect(engine.heard!.right, 222.23);
    await t.tap(find.text('Pause'));
    await t.pumpAndSettle();
    expect(engine.tonePreviewing, isFalse);
    await t.tap(find.text('Add to timeline'));
    await t.pumpAndSettle();
    expect(result!.frames, frameAt(12.5));
    expect(t.takeException(), isNull);
  });

  for (final changed in [false, true]) {
    testWidgets(
        'linear volume ${changed ? 'auditions half amplitude and saves true silence' : 'preserves an existing timeline boost'}',
        (t) async {
      final engine = _Studio();
      final clip = Clip(
          id: 'test',
          source: 'oscillator',
          name: 'Tone',
          type: LayerType.beat,
          frames: sampleRate,
          length: sampleRate,
          peaks: [.2],
          gain: 6,
          tone: const BeatTone());
      ToneDraft? result;
      await openPage(t, engine, (d) => result = d, existing: clip);
      final fader = find.byKey(const ValueKey('tone-volume'));
      await t.scrollUntilVisible(fader, 200,
          scrollable: find.byType(Scrollable).first);
      final initial = t.widget<Slider>(fader);
      expect(initial.min, 0);
      expect(initial.max, 100);
      expect(initial.value, 100);
      expect(find.textContaining('+6.0 dB timeline boost'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tone-preview')));
      await t.pumpAndSettle();
      expect(engine.level, 6);
      if (changed) {
        initial.onChanged!(50);
        await t.pump();
        expect(engine.level, closeTo(-6.0206, .0001));
        expect(t.widget<Slider>(fader).value, closeTo(50, .0001));
        t.widget<Slider>(fader).onChanged!(0);
        await t.pump();
        expect(engine.level, silentGainDb);
        expect(find.textContaining('0%   ·   Silence'), findsOneWidget);
      }
      await t.tap(find.text('Pause'));
      await t.pumpAndSettle();
      await t.tap(find.text('Apply changes'));
      await t.pumpAndSettle();
      expect(result!.gain, changed ? silentGainDb : 6.0);
      expect(t.takeException(), isNull);
    });
  }
}
