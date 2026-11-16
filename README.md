# Innerwave Studio

A Flutter stereo audio editor for iPhone and Android. Arrange binaural audio, ASMR textures and your own spoken affirmations on a local timeline. Sessions and decoded audio stay in the app's documents folder. Export opens the device's share sheet.

## Make a first mix

1. Open **Night Current** and press **Play**. The original 24-second starter has a 180 Hz tone on the left, 186 Hz on the right, and a synthesized rain layer entering at two seconds. Use stereo headphones to hear the separate channels.
2. Tap the time ruler to set the playhead. Choose **Add layer** and select **Binaural beat**, **ASMR texture** or **Prerecorded affirmation** to place an audio file there. You can import WAV, MP3, M4A/AAC, AIFF, FLAC and Ogg audio, including Vorbis and Opus.
3. Tap **Record**, grant microphone access, and speak while the backing mix plays from the playhead. **Stop** adds the take at its starting position. Recording can continue beyond the backing mix. Headphones keep the backing out of the microphone. Wired headphones make alignment easier when monitoring a take.
4. Drag a clip sideways to move it. Select it and choose **Edit clip** for exact start time, source in/out points and level. Voice clips also have **Warmth** and **Presence** controls. While playback is running, drag a clip or audition the controls in the inspector. Apply keeps your changes. Dismissing the inspector restores the previous settings.
5. Use the selected clip's speaker button to mute it. Its menu can duplicate the clip after itself or remove it. Undo layer removal restores its audio, timing, position and voice settings, including after reopening the session. Tap the session name to rename it. The folder button opens previous sessions or creates an empty one. Edits save on the device as you apply them.
6. Choose **Export** and select **WAV**, **MP3**, **AAC** or **Ogg Vorbis**. WAV preserves the 16-bit PCM mix. The compressed formats offer 192, 256 and 320 kbps targets, with 320 kbps preselected. AAC-LC uses an M4A container. Preview and export use the same 44.1 kHz stereo mixing code. Tap the export button in the sheet, then choose Files or another destination. Playback reads a short buffer of active source audio at the playhead. Export renders the full arrangement into a shareable file.

## Run

Use Flutter 3.47.9, an Android SDK for Android, or a Mac with Xcode for iPhone. From this directory run the following commands with a connected device or simulator.

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run -d DEVICE_ID
```

Use a physical phone and headphones for microphone, hardware latency and listening checks. In Xcode select your development team for a signed physical iPhone build.

## Versioned mobile releases

Each push to `main` and each new manual workflow dispatch on `main` gets its own version, including dispatches of the same commit. The `version` in `pubspec.yaml` supplies the minimum semantic version and build number. If that version is already taken, CI advances the patch above the highest reserved or published version. Change the pubspec version to start a new minor or major series. The draft records the GitHub run ID, source commit and mobile build number. GitHub’s **Re-run jobs** uses the original run ID and reuses that run’s version and build number.

The Android emulator and iPhone simulator run the audio integration checks. CI inspects the embedded Android and iPhone versions, checks the APK signing certificate and confirms the iPhone device architecture. Once both jobs pass, the GitHub Release tagged `vX.Y.Z` publishes these three files together.

- `Innerwave-Studio-vX.Y.Z.apk` — Android release signed with Innerwave’s dedicated prototype key.
- `Innerwave-Studio-vX.Y.Z.ipa` — **unsigned** iPhone app for compatible signing or sideloading.
- `SHA256SUMS.txt` — SHA-256 digests for both packages.

Android can update an existing install in place when the app ID and signing certificate match. Earlier debug-key prototypes can require an uninstall before installing the first dedicated-key build. Uninstalling removes the phone’s local sessions, so export any mixes you want to keep first. Local release builds fall back to debug signing unless both signing environment variables in `android/app/build.gradle.kts` are supplied.

GitHub Actions uses the repository secrets `INNERWAVE_ANDROID_KEYSTORE` (base64 PKCS12 with alias `innerwave`) and `INNERWAVE_ANDROID_KEY_PASSWORD`. Keep a backup of the signing key. Published assets are verified on a retry and retain their original bytes. An interrupted upload resumes in its draft. Only complete, verified pairs appear as published releases.

From the project root, run `python -B tools/sync_releases.py` to backfill published pairs under `release/vX.Y.Z/`. The workspace receiver can run the same sync on a schedule.

## Verification and handoff

```sh
flutter analyze --no-pub
flutter test --no-pub
python -B -m unittest discover -s .github/scripts -p 'test_*.py'
python -B -m unittest discover -s tools -p 'test_*.py'
```

- `lib/model.dart` defines the session manifest. Start, trim and length use stereo sample frames. Manifest writes use a temporary sibling and rename on completion.
- `lib/studio.dart` owns the session library, recording, render cache, imports and playback. Under the documents directory, `innerwave/sessions` holds editable manifests and `innerwave/audio` holds source files. Device-level backup behavior depends on platform settings.
- `lib/preview.dart` streams small stereo blocks from a mixer isolate to Android AudioTrack or iOS AVAudioPlayerNode. The device playback counter drives the playhead. Moving or trimming clips updates the arrangement, and seeking can start anywhere without rendering earlier audio.
- `lib/audio_codecs.dart` loads the pinned FFmpegKit audio plugin bundled with each phone build. Imports decode the first audio stream to interleaved stereo PCM. Compressed exports encode the completed WAV with LAME MP3, AAC-LC or libvorbis and appear at the final path after encoding succeeds. All processing runs on-device. Flutter resolves the Dart package from the lockfile. Gradle and Xcode fetch the native audio libraries when building the app. [Audio plugin, included codecs and license](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio/versions/2.5.8)
- `lib/audio.dart` generates the original demo and renders the arrangement in bounded blocks on a background isolate. It preserves stereo, applies trim and level, and applies low/high tone shaping to voice clips. A channel-linked soft knee handles peaks above 0.90 full scale. An hour of stereo PCM at the project rate takes about 635 MB before temporary renders and exports.
- `lib/main.dart`, `lib/studio_view.dart` and `lib/clip_editor.dart` implement the phone editor. The waveform display derives from peak measurements of each source.
- Tests cover stereo carrier separation, frame placement, overlapping clips across render blocks, mute and gain, voice filtering, timeline gestures, trim validation, export selection and export file handling. Check actual playback/record alignment on each target phone and headphone route before tuning latency compensation.

## Later milestone — optional arrangement suggestions

After the manual editor has been tried on real phones, review controlled research on sound selection, pacing, pauses and spoken cues for self-directed hypnotic listening. Track which outcomes each study measures. Listeners' reported relaxation or absorption and measured EEG coherence answer different questions. Current research does not establish that a particular stereo mix reliably synchronizes the hemispheres. [Systematic review of binaural-beat entrainment](https://doi.org/10.1371/journal.pone.0286023)

Design an opt-in arranger that proposes placements for the listener's own clips and explains its timing choices. Let the listener audition, edit, reject and undo a proposal. Compare proposed and manually arranged mixes with the same source audio and similar levels in counterbalanced sessions. Evaluate voice clarity, comfort, reported absorption and how much timing the listener changes. Use those findings to decide which suggestions to retain.
