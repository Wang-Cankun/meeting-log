#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders the Meeting summaries window to PNG without Screen Recording permission.
///
///     MeetingLog --render-summaries <out-dir> [--name <prefix>] [--meeting <folder>] [--scope <project>]
///                [--query <text>] [--no-inspector] [--show-line <n>] [--popover <n>]
///                [--appearance light|dark|both] [--size 1280x820] [--document]
///
/// `--document` also writes the whole summary document, beyond the window's height.
///
/// Reads the archive configured for the installed app (read-only); starts no capture, preview or processing.
@MainActor
enum SummariesRender {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-summaries"), flag + 1 < arguments.count else { return false }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let output = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
        // Read the installed app's settings, such as the archive root; writes stay in this binary's domain.
        UserDefaults.standard.addSuite(named: "com.wangcankun.meeting-log")
        UserDefaults.standard.setVolatileDomain(["summariesShowsTranscript": !arguments.contains("--no-inspector")],
                                                forName: UserDefaults.argumentDomain)
        let size = value("--size").map { $0.split(separator: "x").compactMap { Double($0) } }
            .flatMap { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil } ?? CGSize(width: 1280, height: 820)
        let appearances: [NSAppearance.Name] = switch value("--appearance") ?? "both" {
        case "light": [.aqua]
        case "dark": [.darkAqua]
        default: [.aqua, .darkAqua]
        }
        let job = Job(output: output, name: value("--name") ?? "summaries", size: size,
                      meeting: value("--meeting").map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL },
                      scope: value("--scope").map(LibraryScope.project), query: value("--query") ?? "",
                      showLine: value("--show-line").flatMap(Int.init), popover: value("--popover").flatMap(Int.init),
                      document: arguments.contains("--document"))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for appearance in appearances { try await render(job, appearance: appearance) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        return true
    }

    private struct Job {
        let output: URL
        let name: String
        let size: CGSize
        let meeting: URL?
        let scope: LibraryScope?
        let query: String
        let showLine: Int?
        let popover: Int?
        let document: Bool
    }

    private static func render(_ job: Job, appearance: NSAppearance.Name) async throws {
        NSApp.appearance = NSAppearance(named: appearance)
        let suffix = appearance == .darkAqua ? "dark" : "light"
        let model = AppModel(startsServices: false)
        if let meeting = job.meeting {
            let match = model.recentMeetings.first { $0.url.standardizedFileURL == meeting }?.url ?? meeting
            model.summaryOpenRequest = SummaryOpenRequest(url: match)
        }
        let navigator = TranscriptNavigator()
        let host = NSHostingView(rootView: SummariesView(model: model, navigator: navigator,
                                                         scope: job.scope ?? .all, query: job.query))
        host.sceneBridgingOptions = .all
        // Like a Window scene: content sets the minimum size but never grows the window.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: job.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Meeting summaries"
        window.contentView = host
        window.setContentSize(job.size)
        // Off screen, so pointer and scroll events cannot change what is rendered.
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(4))
        if let line = job.showLine ?? job.popover {
            navigator.show(line: line)
            try await Task.sleep(for: .seconds(1.5))
        }
        let frame = window.contentView?.superview ?? host
        try write(frame, to: job.output.appending(path: "\(job.name)-\(suffix).png"))
        if job.document {
            // The widest scroll view is the summary; its document view holds the full page.
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            if let page = scrollViews(frame).max(by: { $0.frame.width < $1.frame.width })?.documentView {
                try write(page, to: job.output.appending(path: "\(job.name)-document-\(suffix).png"), background: .textBackgroundColor)
            }
        }
        if let line = job.popover {
            let popover = NSHostingView(rootView: EvidencePopover(mark: EvidenceMark(line: line), navigator: navigator,
                                                                  player: navigator.player, dismiss: {}))
            let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = popover
            panel.setContentSize(popover.fittingSize)
            panel.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            panel.orderFrontRegardless()
            try await Task.sleep(for: .seconds(0.8))
            try write(popover, to: job.output.appending(path: "\(job.name)-popover-\(suffix).png"), background: .windowBackgroundColor)
            panel.close()
        }
        window.close()
        navigator.player.pause()
    }

    /// `cacheDisplay` leaves Liquid Glass panes (sidebar, inspector) blank or filled with noise, so each large
    /// glass pane is repainted with a flat background and its content drawn separately on top.
    private static func snapshot(_ root: NSView) throws -> NSBitmapImageRep {
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CocoaError(.fileWriteUnknown) }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        var panes: [NSView] = []
        var platters: [NSView] = []
        func collect(_ view: NSView) {
            if String(describing: type(of: view)).contains("GlassEffectView") {
                if view.bounds.width > 120, view.bounds.height > 120 { panes.append(view) } else { platters.append(view) }
                return
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        guard !panes.isEmpty || !platters.isEmpty,
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              case () = canvas.size = root.bounds.size,
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return bitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let previousAppearance = NSAppearance.current
        NSAppearance.current = root.effectiveAppearance
        defer { NSAppearance.current = previousAppearance }
        bitmap.draw(in: CGRect(origin: .zero, size: root.bounds.size))
        for platter in platters {
            let rect = platter.convert(platter.bounds, to: root)
            let target = root.isFlipped ? CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
            let cg = context.cgContext
            cg.addPath(CGPath(roundedRect: target, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
            cg.setFillColor(NSColor.controlBackgroundColor.cgColor)
            cg.fillPath()
            cg.addPath(CGPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), cornerWidth: rect.height / 2 - 0.5,
                              cornerHeight: rect.height / 2 - 0.5, transform: nil))
            cg.setStrokeColor(NSColor.separatorColor.cgColor)
            cg.strokePath()
        }
        for pane in panes {
            let rect = pane.convert(pane.bounds, to: root)
            let target = root.isFlipped ? CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
            let radius: CGFloat = rect.minX > 0 && rect.maxX < root.bounds.width ? 12 : 0
            context.cgContext.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.cgContext.setFillColor((rect.minX < 20 ? NSColor.underPageBackgroundColor : NSColor.windowBackgroundColor).cgColor)
            context.cgContext.fillPath()
            // The pane's own `_NSCoreHostingView` draws the glass itself; only the content holder's views are content.
            // Vibrant list rows draw blank as part of a larger view, so each list row is drawn on its own.
            func draw(_ view: NSView) {
                guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: image)
                let frame = view.convert(view.bounds, to: root)
                let place = root.isFlipped ? CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height) : frame
                image.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            func cells(_ view: NSView) -> [NSView] {
                guard !view.isHidden else { return [] }
                let name = String(describing: type(of: view))
                if name.hasPrefix("CellHostingView") || name.contains("HeaderForSection") { return [view] }
                return view.subviews.flatMap(cells)
            }
            for content in pane.subviews.filter({ String(describing: type(of: $0)) == "ContentHolderView" }).flatMap(\.subviews) {
                draw(content)
                cells(content).forEach(draw)
            }
        }
        // The toolbar sits above the panes; draw its items again where a pane was repainted.
        func toolbarItems(_ view: NSView) -> [NSView] {
            String(describing: type(of: view)) == "NSToolbarItemViewer" ? [view] : view.subviews.flatMap(toolbarItems)
        }
        for item in toolbarItems(root) where !item.isHidden && item.bounds.width > 0 {
            let frame = item.convert(item.bounds, to: root)
            guard let image = item.bitmapImageRepForCachingDisplay(in: item.bounds) else { continue }
            item.cacheDisplay(in: item.bounds, to: image)
            let place = root.isFlipped ? CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height) : frame
            image.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    /// `background` fills behind a view that has none of its own, such as a scroll view's document or a popover.
    private static func write(_ view: NSView, to url: URL, background: NSColor? = nil) throws {
        var bitmap = try snapshot(view)
        if let background,
           let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            canvas.size = view.bounds.size
            if let context = NSGraphicsContext(bitmapImageRep: canvas) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                var fill = background.cgColor
                view.effectiveAppearance.performAsCurrentDrawingAppearance { fill = background.cgColor }
                context.cgContext.setFillColor(fill)
                context.cgContext.fill(CGRect(origin: .zero, size: view.bounds.size))
                bitmap.draw(in: CGRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: false, hints: nil)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                bitmap = canvas
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        print(url.path)
    }
}
#endif
