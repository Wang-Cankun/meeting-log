#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
swift build --package-path "$repo_dir" -c release

app_dir="$repo_dir/.build/MeetingLog.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/.build/release/MeetingLog" "$app_dir/Contents/MacOS/MeetingLog"
cp "$repo_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.wangcankun.meeting-log"' \
  "$app_dir"
printf 'Built %s\n' "$app_dir"
