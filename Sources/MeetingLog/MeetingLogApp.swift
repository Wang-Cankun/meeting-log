import SwiftUI

@main
struct MeetingLogApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            let presentation = StatusItemPresentation(phase: model.phase)
            Image(systemName: presentation.systemImage)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel(presentation.accessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Window("Import Audio", id: "import-audio") {
            ImportAudioView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        Window("Meeting summaries", id: "meeting-summaries") {
            SummaryReviewView(model: model)
        }
        .defaultSize(width: 1000, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Window("Move meeting", id: "move-meeting") {
            MoveMeetingView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(model: model)
        }
    }
}
