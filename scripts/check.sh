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
  "$repo_dir/Sources/MeetingLog/Processing/TranscriptEvidence.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/TranscriptPolisher.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/Prompts.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/TranscriptionBatch.swift" \
  "$repo_dir/Sources/MeetingLog/Processing/SummaryRegenerator.swift" \
  "$repo_dir/Checks/SummaryChecks.swift" \
  "$repo_dir/Checks/ConcurrencyChecks.swift" \
  "$repo_dir/Checks/main.swift" \
  -module-cache-path "$repo_dir/.build/check-module-cache" \
  -o "$check_dir/check"
"$check_dir/check" "$@"

# Compile the queue regression in the same file as AppModel for private-state access.
cat "$repo_dir/Sources/MeetingLog/AppModel.swift" "$repo_dir/Checks/AppModelChecks.swift" > "$check_dir/AppModel.swift"
cat > "$check_dir/RetryMain.swift" <<'SWIFT'
import Foundation
@main struct RetryChecks {
    @MainActor static func main() throws { try AppModel.checkRetryWhileBusy() }
}
SWIFT
sources=("$repo_dir"/Sources/MeetingLog/**/*.swift)
sources=("${(@)sources:#*/MeetingLogApp.swift}")
sources=("${(@)sources:#*/AppModel.swift}")
swiftc -parse-as-library -swift-version 6 "${sources[@]}" "$check_dir/AppModel.swift" "$check_dir/RetryMain.swift" \
    -module-cache-path "$repo_dir/.build/check-module-cache" -o "$check_dir/retry-check"
"$check_dir/retry-check"
