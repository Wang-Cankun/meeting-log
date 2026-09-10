#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
swiftc \
  "$repo_dir/Sources/MeetingLog/Models/MeetingModels.swift" \
  "$repo_dir/Sources/MeetingLog/Capture/LevelUpdateGate.swift" \
  "$repo_dir/Sources/MeetingLog/Storage/ArchiveStore.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/MarkdownRenderer.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/MediaProcessor.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/AudioImport.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/ProviderClient.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/MeetingProcessor.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/Prompts.swift" \
  "$repo_dir/Checks/main.swift" \
  -module-cache-path "$repo_dir/.build/check-module-cache" \
  -o "$check_dir/check"
"$check_dir/check" "$@"
