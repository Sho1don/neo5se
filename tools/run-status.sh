#!/bin/sh
# Show the current state of the neo5se XNU build on GitHub Actions.
#   tools/run-status.sh            # status of the newest xnu.yml run
#   tools/run-status.sh <run-id>   # status of a specific run
#   tools/run-status.sh -w         # keep polling until the run completes
set -u
REPO=Sho1don/neo5se

# Notify with a quiet two-tone ding (for headphones, ~5% amplitude).
# `beep`        - short ding: a status transition happened.
# `beep final`  - five-second repeated alert: the build is done, cut the video.
# BEEP=0 disables. Falls back to the terminal bell if no audio player exists.
WAVDIR=/tmp/oc-ding
gen_wavs() {
	[ -f "$WAVDIR/short.wav" ] && [ -f "$WAVDIR/final.wav" ] && return 0
	mkdir -p "$WAVDIR"
	python3 - "$WAVDIR" <<'PY'
import math, struct, sys, wave
rate = 44100
def write(name, sec, tones, amp, pulses=1, gap=0.0):
    frames = bytearray()
    n = int(rate * sec)
    for i in range(n):
        t = i / rate
        period = sec if pulses == 1 else (sec / pulses)
        tt = t % period if pulses > 1 else t
        if pulses > 1 and tt > sec / ((pulses - 1) * pulses) * (pulses - 1):
            pass
        freq = tones[0] if tt < period / 2 else tones[1]
        fade = min(1.0, tt / 0.01, max(0.0, (period - tt) / 0.05))
        s = amp * fade * math.sin(2 * math.pi * freq * i / rate)
        frames += struct.pack('<h', int(s * 32767))
    with wave.open(f'{sys.argv[1]}/{name}.wav', 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(bytes(frames))
# short: single quiet ding, 0.45 s
write('short', 0.45, (880, 1320), 0.05)
# final: louder ding repeated ~8 times over 5 s, unmistakable through music
write('final', 5.0, (1046, 1568), 0.14, pulses=8, gap=0.0)
PY
}
play_wav() {
	gen_wavs
	local wav=$WAVDIR/$1.wav
	if command -v pw-play >/dev/null 2>&1; then pw-play "$wav" 2>/dev/null
	elif command -v paplay >/dev/null 2>&1; then paplay "$wav" 2>/dev/null
	else return 1
	fi
}
beep() {
	[ "${BEEP:-1}" = 1 ] || return 0
	case ${1:-short} in
		final) play_wav final || printf '\a' ;;
		*)     play_wav short || printf '\a' ;;
	esac
}

RUN=${1:--w}
if [ "$RUN" = -w ]; then
	RUN=$(gh run list -R "$REPO" --workflow=xnu.yml --limit 1 --json databaseId --jq '.[0].databaseId')
	WATCH=1
else
	WATCH=0
fi

status() {
	gh run view "$RUN" -R "$REPO" --json status,conclusion,startedAt \
		--jq '"\(.status) \(.conclusion // "-") started=\(.startedAt)"' 2>/dev/null
}

ST=$(status)
case $ST in
	"completed success"*)      echo "BUILD OK:    run $RUN finished, all jobs succeeded" ;;
	"completed failure"*)      echo "BUILD FAIL:  run $RUN finished with errors (I will pull the log)" ;;
	"completed cancelled"*)    echo "BUILD CANCEL run $RUN was cancelled" ;;
	"in_progress"*)            echo "BUILDING:    run $RUN is compiling on macOS right now" ;;
	"queued"*)                 echo "QUEUED:      run $RUN waits for a free macOS runner (can take a while)" ;;
	*)                         echo "run $RUN: ${ST:-gh error / not authenticated?}" ;;
esac

if [ "$WATCH" = 1 ]; then
	printf 'polling every 30s (Ctrl-C to stop, BEEP=0 to mute)...\n'
	PREV=$ST
	beep   # confirm audio path at start so volume can be checked beforehand
	while :; do
		case $ST in "completed"*) break ;; esac
		sleep 30
		ST=$(status)
		if [ "$ST" != "$PREV" ]; then
			beep
			PREV=$ST
		fi
		printf '\r\033[2K%s' "$ST"
	done
	echo
	beep final
	status | case $(cat) in
		"completed success"*) echo "BUILD OK:    run $RUN finished successfully -- next: payload + fastboot boot" ;;
		"completed failure"*) echo "BUILD FAIL:  run $RUN failed -- next: pull the log, fix patches" ;;
		*) echo "$ST" ;;
	esac
fi
