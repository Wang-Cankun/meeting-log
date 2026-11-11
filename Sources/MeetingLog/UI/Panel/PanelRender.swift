#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// Debug-only: renders the menu bar panel to PNG in fixed fixture states, without capture or archive access.
///
///     MeetingLog --render-panel <out-dir> [--state <name>] [--appearance light|dark|both]
///
/// Writes `panel-<n>-<state>-<appearance>.png`. Settings come from the argument domain and an empty archive
/// root, so the installed app's settings and archive are never read or written.
@MainActor
enum PanelRender {
    enum Scenario: String, CaseIterable {
        case readyCollapsed = "ready-collapsed"
        case readyExpanded = "ready-expanded"
        case attention = "mic-denied"
        case recording = "recording-no-input"
        case saving = "saving-mixing"
        case recent = "recent-processing-failed"
        case longPath = "long-save-path"
    }

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-panel"), flag + 1 < arguments.count else { return false }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let output = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
        let scenarios = value("--state").map { name in Scenario.allCases.filter { $0.rawValue == name } } ?? Scenario.allCases
        let appearances: [NSAppearance.Name] = switch value("--appearance") ?? "both" {
        case "light": [.aqua]
        case "dark": [.darkAqua]
        default: [.aqua, .darkAqua]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for scenario in scenarios {
                    for appearance in appearances { try await render(scenario, appearance: appearance, to: output) }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        return true
    }

    nonisolated private static let root = URL(filePath: "/nonexistent/meetinglog-render-archive", directoryHint: .isDirectory)

    nonisolated private static func project(_ name: String) -> ProjectFolder {
        ProjectFolder(name: name, url: root.appending(path: name, directoryHint: .isDirectory))
    }

    private static let projects = [
        "Spatial_core", "Spatial_core/projects/Xenium_workflow", "Team_update", "Lung_explorer",
        "Example_Lab/projects/Spatial_transcriptomics/projects/Tissue_atlas_consortium/projects/Pediatric_multimodal_spatial_atlas_pilot",
    ].map(project)

    private static func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
    }

    private static let meetings: [ArchivedMeeting] = [
        ("Automating Xenium Processing and Cell Type Annotation Pipeline", "Spatial_core/projects/Xenium_workflow", -6),
        ("团队周会与项目进展更新", "Team_update", -8),
        ("Pediatric Multi-Modal Spatial Atlas Data Handoff", "Lung_explorer", -8),
    ].map { title, projectName, offset in
        let date = day(offset, hour: 14, minute: 5)
        return ArchivedMeeting(title: title, projectName: projectName, dateText: "", date: date, createdAt: date,
                               url: root.appending(path: "\(projectName)/meetings/\(title)", directoryHint: .isDirectory))
    }

    private static func pending(_ state: PendingMeetingItem.State, startedAt: Date, project: String) -> PendingMeetingItem {
        let manifest = SessionManifest(id: UUID(), startedAt: startedAt, status: .captured, videoEnabled: false,
                                       microphoneID: nil, lastError: nil, projectName: project)
        return PendingMeetingItem(directory: root.appending(path: ".pending/\(UUID().uuidString)"), manifest: manifest, state: state)
    }

    private static func render(_ scenario: Scenario, appearance: NSAppearance.Name, to output: URL) async throws {
        NSApp.appearance = NSAppearance(named: appearance)
        let index = Scenario.allCases.firstIndex(of: scenario)! + 1
        let suffix = appearance == .darkAqua ? "dark" : "light"
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { $0.localizedName.localizedCaseInsensitiveContains("MacBook") }
        var settings: [String: Any] = [
            ArchiveStore.rootDefaultsKey: root.path,
            "providerAPIKey": "render",
            "microphoneEnabled": true,
            "selectedProjectName": "Spatial_core/projects/Xenium_workflow",
            "sourcesExpanded": scenario == .readyExpanded,
        ]
        if scenario == .longPath {
            settings["selectedProjectName"] = projects.last!.name
            if let builtIn { settings["microphoneID"] = builtIn.uniqueID }
        }
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)

        let model = AppModel(startsServices: false)
        model.microphonePermission = scenario == .attention ? .denied : .authorized
        model.audioLevels.debugSet(system: 0.58, microphone: 0.32)
        if scenario == .longPath {
            model.applications = [CaptureApplication(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams")]
            model.selectedSystemAudioBundleID = "com.microsoft.teams2"
            model.selectedSystemAudioName = "Microsoft Teams"
        }
        let recordingName = builtIn?.localizedName ?? "MacBook Pro Microphone"
        switch scenario {
        case .recording:
            model.videoEnabled = true
            model.selectedScreenSource = "Display 1"
            model.audioLevels.debugSet(system: 0.64, microphone: 0.01)
            model.debugSetPanelState(projects: projects, recentMeetings: meetings,
                                     recordingDestinationPath: projects[1].displayPath, recordingMicrophoneName: recordingName,
                                     microphoneSilenceWarning: "No input from \(recordingName) for 30 s. Check the selected microphone.")
            model.phase = .recording(startedAt: Date(timeIntervalSinceNow: -(42 * 60 + 17)))
        case .saving:
            model.debugSetPanelState(projects: projects, recentMeetings: meetings,
                                     recordingDestinationPath: projects[1].displayPath, recordingMicrophoneName: recordingName)
            model.savingProgress.fraction = 0.45
            model.phase = .saving(duration: 42 * 60 + 18, step: .mixingAudio)
        case .recent:
            model.debugSetPanelState(
                projects: projects, recentMeetings: meetings,
                pendingItems: [
                    pending(.processing, startedAt: day(0, hour: 16, minute: 20), project: "Spatial_core/projects/Xenium_workflow"),
                    pending(.failed("Not every audio block was transcribed"), startedAt: day(-1, hour: 16, minute: 30), project: "Team_update"),
                ],
                processingProgress: ProcessingProgress(stage: .transcribe(completed: 3, total: 8),
                                                       detail: "Transcribing with MAI-Transcribe-2 · 3 of 8"))
        default:
            model.debugSetPanelState(projects: projects, recentMeetings: meetings)
        }

        let content = ControlPanel(model: model)
            .environment(\.debugHoveredMeeting, scenario == .readyCollapsed ? meetings[1].url : nil)
            .environment(\.controlActiveState, .key)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PanelColors.background)
        let host = NSHostingView(rootView: content)
        let window = KeyWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Off screen, so pointer events cannot change what is rendered.
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeKey()
        try await Task.sleep(for: .seconds(0.6))
        let fitting = host.fittingSize
        window.setContentSize(CGSize(width: 400, height: fitting.height.rounded(.up)))
        try await Task.sleep(for: .seconds(1.2))
        try SummariesRender.write(host, to: output.appending(path: "panel-\(index)-\(scenario.rawValue)-\(suffix).png"))
        window.close()
    }
}

/// The menu bar panel is the key window while open, so prominent buttons draw in their active colours.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private struct DebugHoveredMeetingKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    /// Debug renderer only: draws this Recent row as hovered.
    var debugHoveredMeeting: URL? {
        get { self[DebugHoveredMeetingKey.self] }
        set { self[DebugHoveredMeetingKey.self] = newValue }
    }
}
#endif
