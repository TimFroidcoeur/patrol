#!/usr/bin/env bash
set -euo pipefail

# run emulator
emulator @MyAVD -no-snapshot-save -no-window -noaudio -no-boot-anim &

timeout=300
start_time=$(date +%s)

while true
do
  # Check value of sys.boot_completed using adb shell
  boot_completed=$(adb shell getprop sys.boot_completed)

  # Check if the value is 1 (boot completed)
  if [[ $boot_completed -eq 1 ]]; then
    echo "Boot completed"
    break
  fi

  current_time=$(date +%s)
  if [[ $((current_time - start_time)) -gt $timeout ]]; then
    echo "Timeout reached"
    break
  fi

  sleep 5
done

# if we screenrecord too quickly, we get: "Unable to open '/sdcard/patrol.mp4': Operation not permitted"
sleep 30
record() {
    adb shell mkdir -p /sdcard/screenrecords
    i=0
    while [ ! -f "$HOME/adb_screenrecord.lock" ]; do
        adb shell screenrecord "/sdcard/screenrecords/patrol_$i.mp4" &
        pid="$!"
        echo "$pid" > "$HOME/adb_screenrecord.pid"
        lsof -p "$pid" +r 1 &>/dev/null # wait until screenrecord times out
        i=$((i + 1))
    done
}

adb install ~/test-butler-2.2.1.apk
adb shell am startservice com.linkedin.android.testbutler/com.linkedin.android.testbutler.ButlerService
while ! adb shell ps | grep butler > /dev/null; do
    sleep 1
    echo "Waiting for test butler to start..."
done
echo "Started Test Butler"

# record in background
record &
recordpid="$!"

# print and write logs to a file
flutter logs | tee ./flutter-logs &
flutterlogspid="$!"

EXIT_CODE=0

# run tests 3 times and save tests' summary
patrol test \
    -t integration_test/example_test.dart \
    | tee ./tests-summary || EXIT_CODE=$?

# write lockfile to prevent next loop iteration
touch "$HOME/adb_screenrecord.lock"

# kill processes
kill $recordpid
kill $flutterlogspid
adb shell pkill -SIGINT screenrecord

# pull screen recordings and merge them
adb pull /sdcard/screenrecords .
cd screenrecords
ls | grep mp4 | sort -V | xargs -I {} echo "file {}" | sponge videos.txt
ffmpeg -f concat -safe 0 -i videos.txt -c copy screenrecord.mp4

# goodbye emulator :(
adb -s emulator-5554 emu kill
exit $EXIT_CODE
