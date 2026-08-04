import SwiftUI

/// Pre-computed streamlines through a static flow field, in unit space (0…1).
/// The view animates *dashes travelling along* these fixed paths, which reads as
/// ink flowing through channels — cheap (paths built once, only the dash phase
/// animates) and unmistakably "flow". Deterministic seed so it never jumps
/// between launches.
struct FlowField {
    let paths: [Path]

    static let shared = FlowField.generate()

    private static func angle(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let nx = x - 0.5, ny = y - 0.5
        return 0.55 * sin(nx * 6.2 + ny * 2.4)
             + 0.35 * sin(nx * 2.8 - ny * 6.8 + 1.1)
             + 0.18 * sin(ny * 12.0 + 2.0)
             + 0.12                                   // gentle rightward bias so it "travels"
    }

    private static func generate() -> FlowField {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        var paths: [Path] = []
        let spacing: CGFloat = 0.088
        var gy: CGFloat = -0.06
        while gy < 1.06 {
            var gx: CGFloat = -0.10
            while gx < 1.10 {
                var p = CGPoint(x: gx + rnd() * spacing, y: gy + rnd() * spacing)
                var path = Path()
                path.move(to: p)
                for _ in 0..<48 {
                    let a = angle(p.x, p.y)
                    p = CGPoint(x: p.x + cos(a) * 0.013, y: p.y + sin(a) * 0.013)
                    path.addLine(to: p)
                }
                paths.append(path)
                gx += spacing
            }
            gy += spacing
        }
        return FlowField(paths: paths)
    }
}
