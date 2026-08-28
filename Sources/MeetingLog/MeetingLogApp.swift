import SwiftUI

@main
struct MeetingLogApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("MeetingLog")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
