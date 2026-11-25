#!/usr/bin/env bash
# Opens test windows (TextEdit, Notes, Finder) and glasses all three from one spike process.
# Usage: scripts/glass-test.sh [--mode keyed|uniform] [--transparency T] [--tint T] [--blur PX] [--measure SECONDS]
# Stop: pkill -x GlassCaptureSpike
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/GlassCaptureSpike.app"
LOG="$HOME/Library/Logs/g-l-a-s-s/spike.log"
MODE="keyed"
MEASURE=0
LOOK=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --measure) MEASURE="$2"; shift 2 ;;
        --transparency|--tint|--blur) LOOK+=("$1" "$2"); shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -d "$APP" ]] || { echo "missing $APP (scripts/bundle-spike.sh builds it, but rebuilding resets the grant)" >&2; exit 1; }

# Launched via `open` so TCC checks the app's grant, not the terminal's.
open -n "$APP" --args --check
sleep 2
if ! tail -4 "$LOG" | grep -q "Screen Recording: granted"; then
    echo "Screen Recording NOT granted for GlassCaptureSpike." >&2
    echo "System Settings > Privacy & Security > Screen Recording: switch on GlassCaptureSpike, then rerun." >&2
    exit 1
fi

SAMPLE="${TMPDIR:-/tmp}/glass-sample.txt"
cat > "$SAMPLE" <<'EOF'
g-l-a-s-s test window

This TextEdit window should turn to glass. The text should stay readable
and flip between light and dark as the backdrop behind it changes.

Drag a bright window (or a photo) behind this one, then a dark one, and
watch the text colour ease across. Try scrolling and resizing too.

The quick brown fox jumps over the lazy dog. 0123456789
EOF

open -a TextEdit "$SAMPLE"
open -a Notes
open "$HOME"
sleep 3

pkill -x GlassCaptureSpike 2>/dev/null || true
open -n "$APP" --args --window TextEdit --window Notes --window Finder --mode "$MODE" ${LOOK[@]+"${LOOK[@]}"}
sleep 3
echo "--- overlays (log: $LOG)"
grep -E "glassing|no on-screen|failed|can't see|backdrop capture|window\(s\)|nothing to glass" "$LOG" | tail -6
pgrep -x GlassCaptureSpike >/dev/null || { echo "no overlay running; see $LOG" >&2; exit 1; }
echo "running pids: $(pgrep -x GlassCaptureSpike | tr '\n' ' ')"
echo "stop with: pkill -x GlassCaptureSpike"

if [[ "$MEASURE" -gt 0 ]]; then
    echo "--- sampling CPU/RSS for ${MEASURE}s"
    start_line=$(wc -l < "$LOG")
    for ((i = 0; i < MEASURE; i++)); do
        ps -o pid=,%cpu=,rss= -p "$(pgrep -x GlassCaptureSpike | paste -sd, -)" 2>/dev/null || true
        ps -o %cpu= -p "$(pgrep -x WindowServer)" | sed 's/^/WindowServer /'
        sleep 1
    done | awk '
        $1 == "WindowServer" { ws += $2; wn++; next }
        { cpu[$1] += $2; rss[$1] = $3; n[$1]++ }
        END {
            for (p in cpu) printf "pid %s: avg CPU %.1f%%, RSS %.0f MB\n", p, cpu[p] / n[p], rss[p] / 1024
            if (wn) printf "WindowServer: avg CPU %.1f%%\n", ws / wn
        }'
    echo "--- rates logged during the window"
    tail -n +"$((start_line + 1))" "$LOG" | grep "per s:" || echo "(none logged yet)"
fi
