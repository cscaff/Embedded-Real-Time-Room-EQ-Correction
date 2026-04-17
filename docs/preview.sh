#!/usr/bin/env bash
# Preview docs/design.md with rendered Mermaid diagrams in the browser.
#
# Usage:  ./docs/preview.sh                 # serves design.md
#         ./docs/preview.sh other.md        # serves other.md

set -eu

PORT="${PORT:-8765}"
FILE="${1:-design.md}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$DIR"

if [ ! -f "$FILE" ]; then
  echo "error: $DIR/$FILE not found" >&2
  exit 1
fi

python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' INT TERM EXIT

# Wait briefly for the server to bind the port.
for _ in 1 2 3 4 5; do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.2
done

URL="http://127.0.0.1:$PORT/viewer.html?file=$(printf '%s' "$FILE" | sed 's/ /%20/g')"
echo "Preview: $URL"
echo "Ctrl+C to stop."

if command -v open >/dev/null; then
  open "$URL"
elif command -v xdg-open >/dev/null; then
  xdg-open "$URL"
fi

wait "$PID"
