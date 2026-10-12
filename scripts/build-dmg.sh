#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
"$repo_dir/scripts/build-app.sh" "$@"

stage_dir=$(mktemp -d)
mount_dir=$(mktemp -d)
mounted=false
cleanup() {
  if $mounted; then
    hdiutil detach "$mount_dir" -quiet || return
  fi
  rm -rf "$stage_dir" "$mount_dir"
}
trap cleanup EXIT

ditto "$repo_dir/.build/MeetingLog.app" "$stage_dir/MeetingLog.app"
ln -s /Applications "$stage_dir/Applications"
dmg_path="$repo_dir/.build/MeetingLog-macOS-arm64.dmg"
hdiutil create -volname MeetingLog -srcfolder "$stage_dir" -fs HFS+ -format UDZO -ov "$dmg_path"
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=true
test -x "$mount_dir/MeetingLog.app/Contents/MacOS/MeetingLog"
test "$(readlink "$mount_dir/Applications")" = /Applications
codesign --verify --deep --strict "$mount_dir/MeetingLog.app"
hdiutil detach "$mount_dir" -quiet
mounted=false
printf 'Built %s\n' "$dmg_path"
