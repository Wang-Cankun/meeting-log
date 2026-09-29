import Foundation

/// Short source names for the collapsed sources row.
func checkPanelSourceNames() {
    precondition(SourceNames.microphone(nil) == "Default" && SourceNames.microphone("  ") == "Default")
    precondition(SourceNames.microphone("MacBook Pro Microphone") == "MacBook Pro")
    precondition(SourceNames.microphone("Built-in Microphone") == "Built-in")
    precondition(SourceNames.microphone("Studio Display microphone") == "Studio Display")
    precondition(SourceNames.microphone("Jabra Evolve2 65 - Mic") == "Jabra Evolve2 65")
    precondition(SourceNames.microphone("Scarlett 2i2 USB Audio Input") == "Scarlett 2i2 USB")
    // A name that is only the generic word, or ends in it without a word break, is kept whole.
    precondition(SourceNames.microphone("Microphone") == "Microphone")
    precondition(SourceNames.microphone("AirPods Pro") == "AirPods Pro")
    precondition(SourceNames.microphone("Yeti Nano Stereomic") == "Yeti Nano Stereomic")
    precondition(SourceNames.microphone("iPhone 麦克风") == "iPhone 麦克风")
    precondition(SourceNames.macAudio(applicationName: nil) == "All apps" && SourceNames.macAudio(applicationName: "") == "All apps")
    precondition(SourceNames.macAudio(applicationName: "zoom.us") == "zoom.us")
    print("Panel source names passed: default, generic suffixes, whole names")
}
