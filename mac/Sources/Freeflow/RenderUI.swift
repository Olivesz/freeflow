import AppKit
import SwiftUI

/// Hidden dev hook: `Freeflow --render-ui <dir>` snapshots the dashboard to PNGs
/// (idle + listening) so the design can be reviewed without a screen grab.
enum RenderUI {
    static func run(_ dir: String) {
        MainActor.assumeIsolated {
            snapshot(recording: false, level: 0, to: "\(dir)/ui-idle.png")
            snapshot(recording: true, level: 0.72, to: "\(dir)/ui-active.png")
            snapshotHUD(to: "\(dir)/ui-hud.png")
        }
        exit(0)
    }

    @MainActor private static func snapshot(recording: Bool, level: Double, to path: String) {
        let model = AppModel()
        model.recording = recording
        model.level = level
        let renderer = ImageRenderer(content: DashboardView(model: model))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed for \(path)"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    @MainActor private static func snapshotHUD(to path: String) {
        let model = AppModel()
        model.recording = true
        model.level = 0.6
        model.transcript = "so this is the little floating pill that shows what I'm saying as I speak"
        let renderer = ImageRenderer(content: HUDView(model: model, onCopy: {}).padding(30).background(Color.gray.opacity(0.25)))
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
        }
    }
}
