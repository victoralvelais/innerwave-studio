# Innerwave Studio

A Flutter stereo audio editor for iPhone and Android. Arrange binaural audio, ASMR textures and your own spoken affirmations on a local timeline. Sessions and decoded audio stay in the app's documents folder. Export opens the device's share sheet.

## Make a first mix

1. Open **Night Current** and press **Play**. The original 24-second starter has a 180 Hz tone on the left, 186 Hz on the right, and a synthesized rain layer entering at two seconds. Use stereo headphones to hear the separate channels.
2. Tap the time ruler to set the playhead. Choose **Add layer** and select **Binaural beat**, **ASMR texture** or **Prerecorded affirmation** to place an audio file there. WAV, MP3 and M4A/AAC are common choices. Additional formats depend on the device's decoder.
3. Tap **Record**, grant microphone access, and speak while the backing mix plays from the playhead. **Stop** adds the take at its starting position. Recording can continue beyond the backing mix. Headphones keep the backing out of the microphone. Wired headphones make alignment easier when monitoring a take.
4. Drag a clip sideways to move it. Select it and choose **Edit clip** for exact start time, source in/out points and level. Voice clips also have **Warmth** and **Presence** controls. Apply a change and replay a short phrase to match your voice preference by ear.
5. Use the selected clip's speaker button to mute it. Its menu can duplicate the clip after itself or remove it. Tap the session name to rename it. The folder button opens previous sessions or creates an empty one. Edits save on the device as you apply them.
6. Choose **Export WAV** to send the mix to Files or another app. The file uses the same 44.1 kHz, 16-bit stereo render as playback. Long edits can take time to render on first play. Subsequent playback reuses the render until the mix changes.

## Run

Use Flutter 3.47.9, an Android SDK for Android, or a Mac with Xcode for iPhone. From this directory run the following commands with a connected device or simulator.

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run -d DEVICE_ID
```

Use a physical phone and headphones for microphone, hardware latency and listening checks. In Xcode select your development team for a signed physical iPhone build. The GitHub Actions workflow builds a debug APK and an unsigned iPhone archive. The iPhone archive needs compatible signing or a compatible sideload environment.

## Verification and handoff

```sh
flutter analyze --no-pub
flutter test --no-pub
```

- `lib/model.dart` defines the session manifest. Start, trim and length use stereo sample frames. Manifest writes use a temporary sibling and rename on completion.
- `lib/studio.dart` owns the session library, recording, render cache, imports and playback. Native channel `innerwave/audio` decodes imported or recorded audio using AVFoundation on iOS and MediaCodec on Android, writing interleaved stereo PCM on disk. Under the documents directory, `innerwave/sessions` holds editable manifests and `innerwave/audio` holds source files. Device-level backup behavior depends on platform settings.
- `lib/audio.dart` generates the original demo and renders the arrangement in bounded blocks on a background isolate. It preserves stereo, applies trim and level, and applies low/high tone shaping to voice clips. A channel-linked soft knee handles peaks above 0.90 full scale. An hour of stereo PCM at the project rate takes about 635 MB before temporary renders and exports.
- `lib/main.dart`, `lib/studio_view.dart` and `lib/clip_editor.dart` implement the phone editor. The waveform display derives from peak measurements of each source.
- Tests cover stereo carrier separation, frame placement, overlapping clips across render blocks, mute and gain, voice filtering, timeline gestures and trim validation. Check actual playback/record alignment on each target phone and headphone route before tuning latency compensation.

## Later milestone — optional arrangement suggestions

After the manual editor has been tried on real phones, review controlled research on sound selection, pacing, pauses and spoken cues for self-directed hypnotic listening. Track which outcomes each study measures. Listeners' reported relaxation or absorption and measured EEG coherence answer different questions. Current research does not establish that a particular stereo mix reliably synchronizes the hemispheres. [Systematic review of binaural-beat entrainment](https://doi.org/10.1371/journal.pone.0286023)

Design an opt-in arranger that proposes placements for the listener's own clips and explains its timing choices. Let the listener audition, edit, reject and undo a proposal. Compare proposed and manually arranged mixes with the same source audio and similar levels in counterbalanced sessions. Evaluate voice clarity, comfort, reported absorption and how much timing the listener changes. Use those findings to decide which suggestions to retain.
