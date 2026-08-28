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

        Settings {
            SettingsView(model: model)
        }
    }
}
