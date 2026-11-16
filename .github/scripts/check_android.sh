#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?Android SDK required}" "${RUNNER_TEMP:?}" "${APK_PATH:?Release APK required}"
test -s "$APK_PATH"
sdkmanager_path=$(find "$ANDROID_HOME/cmdline-tools" -type f -path '*/bin/sdkmanager' | sort -V | tail -n 1)
test -x "$sdkmanager_path"
export PATH="$(dirname "$sdkmanager_path"):$ANDROID_HOME/platform-tools:$PATH"
export ANDROID_USER_HOME="$RUNNER_TEMP/innerwave-android"
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
mkdir -p "$ANDROID_AVD_HOME"
sudo chmod a+rw /dev/kvm

image='system-images;android-35;default;x86_64'
sdkmanager "$image" emulator > "$RUNNER_TEMP/sdk-install.log"
avd="$ANDROID_AVD_HOME/studio.avd"
avdmanager create avd -n studio --package "$image" --device pixel_5 --path "$avd" --force
test -s "$avd/config.ini"
sed -i '/^disk\.dataPartition\.size=/d' "$avd/config.ini"
printf 'disk.dataPartition.size=2048M\n' >> "$avd/config.ini"
# Some command-line tool versions store the pointer in a different preferences
# directory than the emulator. Bind this private AVD to its explicit path.
printf 'avd.ini.encoding=UTF-8\npath=%s\ntarget=android-35\n' "$avd" > "$ANDROID_AVD_HOME/studio.ini"
serial=emulator-5554
log="$RUNNER_TEMP/innerwave-emulator.log"
"$ANDROID_HOME/emulator/emulator" -avd studio -port 5554 -no-window -no-snapshot -no-boot-anim \
    -no-audio -gpu swiftshader -cores 2 -memory 2048 > "$log" 2>&1 &
trap 'status=$?; if (( status )); then tail -n 60 "$log"; fi; adb -s "$serial" emu kill >/dev/null 2>&1 || true' EXIT
timeout 120 adb -s "$serial" wait-for-device
timeout 300 bash -c 'until [[ $(adb -s emulator-5554 shell getprop sys.boot_completed | tr -d "\r") == 1 ]]; do sleep 2; done'

# Launch the release artifact before swapping to the debug-key integration build.
package=studio.innerwave.innerwave_studio
adb -s "$serial" install -g "$APK_PATH"
adb -s "$serial" shell am start -W -n "$package/.MainActivity"
timeout 90 bash -c 'until adb -s emulator-5554 shell uiautomator dump /sdcard/studio-ui.xml >/dev/null 2>&1 && adb -s emulator-5554 shell cat /sdcard/studio-ui.xml | grep -q "Night Current"; do sleep 2; done'
adb -s "$serial" uninstall "$package"
flutter build apk --debug --target-platform android-x64
adb -s "$serial" install -g build/app/outputs/flutter-apk/app-debug.apk
flutter test "--dart-define=TEST_LIVE_SOURCES=${TEST_LIVE_SOURCES:-false}" integration_test/overdub_test.dart -d "$serial"
