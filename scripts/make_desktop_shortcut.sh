#!/usr/bin/env bash
# Creates a Desktop shortcut (Finder alias) so you can launch TokenCounter by
# double-clicking an icon on your Desktop — no Spotlight/Terminal needed.
set -euo pipefail

APP="/Applications/TokenCounter.app"
if [[ ! -d "$APP" ]]; then
    # Fall back to the freshly built app in this repo's dist/ folder.
    APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist/TokenCounter.app"
fi

if [[ ! -d "$APP" ]]; then
    echo "TokenCounter.app을 찾지 못했습니다." >&2
    echo "먼저 ./scripts/build_app.sh 로 앱을 만들고 /Applications 로 옮긴 뒤 다시 실행하세요." >&2
    exit 1
fi

osascript -e "tell application \"Finder\" to make alias file to POSIX file \"$APP\" at (path to desktop folder as alias)" >/dev/null

echo "바탕화면에 'TokenCounter' 바로가기를 만들었습니다. 더블클릭으로 실행하세요."
echo "Created a 'TokenCounter' shortcut on your Desktop. Double-click it to launch."
