# Innerwave Studio

A Flutter stereo audio editor for iPhone and Android. Arrange binaural audio, ASMR textures and your own spoken affirmations on a local timeline. Sessions and decoded audio stay in the app's documents folder. Export opens the device's share sheet.

## Make a first mix

1. Open **Night Current** and press **Play**. The original 24-second starter has a 180 Hz tone on the left, 186 Hz on the right, and a synthesized rain layer entering at two seconds. Use stereo headphones to hear the separate channels.
2. Tap the time ruler to set the playhead. Choose **Add layer** and select **Binaural beat**, **ASMR texture** or **Prerecorded affirmation** to place an audio file there. You can import WAV, MP3, M4A/AAC, AIFF, FLAC and Ogg audio, including Vorbis and Opus.
3. Tap **Record**, grant microphone access, and speak while the backing mix plays from the playhead. **Stop** adds the take at its starting position. Recording can continue beyond the backing mix. Headphones keep the backing out of the microphone. Wired headphones make alignment easier when monitoring a take.
4. Drag a clip sideways to move it. Select it and choose **Edit clip** for exact start time, source in/out points and level. Voice clips also have **Warmth** and **Presence** controls. While playback is running, drag a clip or audition the controls in the inspector. Apply keeps your changes. Dismissing the inspector restores the previous settings.
5. Drag a track's volume slider while listening. Its speaker button controls mute independently. Use **Loop** to repeat the timeline with every unmuted layer audible. To repeat a shorter passage, place the playhead at each boundary and choose the A and B points in the loop menu. Use the zoom buttons and pan the ruler to edit small timing differences. Loop and zoom only affect the editor. Export includes the full arrangement once.
6. A clip's menu can duplicate or remove it. Undo layer removal restores it, including after reopening the session. Tap the session name to rename it. The folder button opens previous sessions or creates an empty one. Edits save on the device as you apply them.
7. Choose **Export** and select **WAV**, **MP3**, **AAC** or **Ogg Vorbis**. Choose WAV for a lossless master. The compressed formats offer 192, 256 and 320 kbps targets, with 320 kbps preselected. AAC-LC uses an M4A container. Use the share sheet to save the finished file.

## Tune a beat or arrange different material per ear

Choose **Add layer → Tone generator**, or select a generated beat and tap **Tune frequencies**. In linked mode a 250 Hz center and 4 Hz difference generate 248 Hz in the left ear and 252 Hz in the right. The beat range is 1–50 Hz and the center range is 20–1500 Hz. Drag a slider, tap a frequency for exact entry, or use the 0.01 Hz steps. Each ear has a separate waveform. Audition the sound, set its duration and add it at the playhead. Five named presets store tunings. The audition timer offers 15 minutes through 8 hours and fades the tone during the final minute of foreground playback. [Reference generator controls](https://www.tmsoft.com/blog/using-binaural-beats-app/)

The **Independent ear controls** checkboxes are saved per session.

- **Beats** enables separate frequencies from 1–1525 Hz for each ear on generated tones. A premixed beat file can be routed as audio. Its embedded frequencies stay as recorded.
- **ASMR** lets you select a soundscape and choose **Left**, **Right** or **Both**. Put two different clips at the same time to play a different soundscape in each ear.
- **Voice** offers the same choices for prerecorded affirmations and microphone takes. Each voice keeps its own timing, level and tone controls.

**Both** preserves the original stereo image. Assigning a stereo clip to one ear averages its two channels and sends that signal only to the selected output. Turning a checkbox off restores shared playback and remembers the individual settings.

## Audio quality

New imports keep a byte-for-byte local copy of the original file. The editor decodes the selected audio stream at its native sample rate to 64-bit floating-point stereo. New imports start at unity gain. Preview uses floating-point stereo at the device output rate and reads short blocks on demand. A WAV master uses the highest imported sample rate in the arrangement, with a minimum of 44.1 kHz, and 64-bit floating-point samples for sessions containing a new import or generated tone. Master files retain headroom above full scale. Physical playback depends on the output route and headphones. Mono imports are duplicated into both channels. Multichannel material is downmixed for the stereo editor.

Compressed exports encode once from that master. MP3, AAC and Vorbis use lossy compression. Existing projects can still use their previously decoded 44.1 kHz, 16-bit sources. Reimport a higher-resolution original to recover detail absent from an older project. The WAV renderer supports files up to the RIFF 4 GB limit. At 96 kHz, an hour of stereo 64-bit PCM takes about 5.53 GB.

## Discover and import video audio

Open **Discover** at the playhead where you want the clip. Search Wikimedia Commons for a recording or video, choose a result and select its layer. The editor downloads the file, extracts its first audio track into local stereo PCM and keeps the title, source page, creator and available license information with the clip. Select the clip and tap **Source credit** to copy that information. The finished project plays offline.

Paste a YouTube watch, Shorts or share link, or a TikTok post or short share link. Discover looks for Commons videos whose source field credits that exact video ID. A matching file can be imported directly. When no copy is available, open the source or choose a saved video from **Photos / Gallery** or **Files**. You can also open a keyword search on either platform. YouTube Studio can save your uploads as MP4s. TikTok offers **Share → Save video** when the creator enables it. [YouTube upload downloads](https://support.google.com/youtube/answer/56100) · [TikTok video downloads](https://support.tiktok.com/en/using-tiktok/exploring-videos/video-downloads)

The file importer supports MP4, MOV, WebM and other supported containers with an audio track. The original file stays intact. Move, trim, layer or export the extracted audio like any other clip.

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

- `lib/model.dart` defines the session manifest. Start, trim and length use a 44.1 kHz reference clock so older edits retain their timing. Native frame counts preserve the exact end of the source at export. Manifest writes are serialized and replaced atomically.
- `lib/studio.dart` owns the session library, recording, render cache, imports and playback. Under the documents directory, `innerwave/sessions` holds editable manifests and `innerwave/audio` holds source files. Device-level backup behavior depends on platform settings.
- `lib/preview.dart` streams small stereo blocks from a mixer isolate to Android AudioTrack or iOS AVAudioPlayerNode. The device playback counter drives the playhead. Moving or trimming clips updates the arrangement, and seeking can start anywhere without rendering earlier audio.
- `lib/audio_codecs.dart` loads the pinned FFmpegKit audio plugin bundled with each phone build. Imports decode the first audio stream to interleaved stereo PCM. Compressed exports encode the completed WAV with LAME MP3, AAC-LC or libvorbis and appear at the final path after encoding succeeds. All processing runs on-device. Flutter resolves the Dart package from the lockfile. Gradle and Xcode fetch the native audio libraries when building the app. [Audio plugin, included codecs and license](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio/versions/2.5.8)
- `lib/audio.dart` synthesizes independent oscillators and renders the arrangement in bounded blocks on a background isolate. It preserves stereo, applies ear routing, trim and level, and applies low/high tone shaping to voice clips. Legacy 16-bit-only mixes keep their original output format and overload behavior.
- `lib/main.dart`, `lib/studio_view.dart` and `lib/clip_editor.dart` implement the phone editor. The waveform display derives from peak measurements of each source.
- Tests cover stereo carrier separation, frame placement, overlapping clips across render blocks, mute and gain, voice filtering, timeline gestures, trim validation, export selection and export file handling. Check actual playback/record alignment on each target phone and headphone route before tuning latency compensation.
- The mobile integration suite also checks landscape and portrait H.264/AAC MP4s, stereo conversion, clip timing, session persistence and silent-video rejection. To exercise live provider lookup and playback, run `flutter test integration_test/discovery_live_test.dart -d DEVICE_ID`. It downloads the credited Commons copies of [a YouTube bird recording](https://commons.wikimedia.org/wiki/File:2023-08-18_ZOO_LJUBLJANA_-_birds_5.webm) and [a TikTok animation](https://commons.wikimedia.org/wiki/File:Wikipe-tan_-_Wow!_Amazing!.webm).

## Later milestone — optional arrangement suggestions

After the manual editor has been tried on real phones, review controlled research on sound selection, pacing, pauses and spoken cues for self-directed hypnotic listening. Track which outcomes each study measures. Listeners' reported relaxation or absorption and measured EEG coherence answer different questions. Current research does not establish that a particular stereo mix reliably synchronizes the hemispheres. [Systematic review of binaural-beat entrainment](https://doi.org/10.1371/journal.pone.0286023)

Design an opt-in arranger that proposes placements for the listener's own clips and explains its timing choices. Let the listener audition, edit, reject and undo a proposal. Compare proposed and manually arranged mixes with the same source audio and similar levels in counterbalanced sessions. Evaluate voice clarity, comfort, reported absorption and how much timing the listener changes. Use those findings to decide which suggestions to retain.
