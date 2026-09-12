import SwiftUI

/// Monochrome companion to the waveform-and-notes app icon.
struct MeetingMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, 0.35, 0.11, 0.30), (0.14, 0.17, 0.11, 0.66),
            (0.28, 0, 0.11, 1), (0.42, 0.23, 0.11, 0.62),
            (0.56, 0.38, 0.11, 0.40),
            (0.71, 0.36, 0.29, 0.10), (0.71, 0.54, 0.25, 0.10),
            (0.71, 0.72, 0.21, 0.10)
        ]
        for (x, y, width, height) in bars {
            let box = CGRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                             width: width * rect.width, height: height * rect.height)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: min(box.width, box.height) / 2, height: min(box.width, box.height) / 2))
        }
        return path
    }
}
