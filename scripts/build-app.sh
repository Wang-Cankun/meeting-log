#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
swift build --package-path "$repo_dir" -c release "$@"
bin_dir=$(swift build --package-path "$repo_dir" -c release --show-bin-path "$@")

app_dir="$repo_dir/.build/MeetingLog.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/MeetingLog" "$app_dir/Contents/MacOS/MeetingLog"
cp "$repo_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/MeetingLogIcon.icns"
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.wangcankun.meeting-log"' \
  "$app_dir"
printf 'Built %s (ad-hoc signed; no Apple account or signing secrets required)\n' "$app_dir"
