import SwiftUI

/// The isolated 60fps ink current — its own view so only it redraws each frame,
/// not the whole window. Dashes travel along fixed streamlines via the clock's
/// accumulating phase (always one direction, never reversing).
struct FlowView: View {
    @ObservedObject var clock: FlowClock
    var brightness: Double
    private let field = FlowField.shared

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width, y: size.height)
            let w = size.width
            for p in field.paths {                                   // faint ink structure
                ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1.0 / w)
            }
            let style = StrokeStyle(lineWidth: 1.7 / w, lineCap: .round,
                                    dash: [0.012, 0.055], dashPhase: clock.phase)
            let a = 0.16 + 0.18 * brightness                         // the travelling current
            for p in field.paths {
                ctx.stroke(p, with: .color(.white.opacity(a)), style: style)
            }
        }
        .blendMode(.plusLighter)
    }
}

/// The freeflow window: a calm, living surface up top (animated ink current +
/// breathing voice-reactive glow), with a compact Setup / Words / History panel
/// below. The light tracks loudness (fast); the flow tracks a smoothed envelope
/// (slow) — two instruments, not one.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    // FF_TAB lets a dev screenshot a specific tab of the live window; defaults to Setup.
    @State private var tab: Tab = {
        switch ProcessInfo.processInfo.environment["FF_TAB"] {
        case "words": return .words
        case "history": return .history
        default: return .setup
        }
    }()

    enum Tab: String, CaseIterable { case setup = "Setup", words = "Words", history = "History" }

    private var accent: Color {
        model.recording ? Color(red: 0.98, green: 0.74, blue: 0.55)
                        : Color(red: 0.72, green: 0.86, blue: 0.98)
    }
    private var glowOpacity: Double {
        model.recording ? min(0.85, 0.45 + model.glowLevel * 0.5) : 0.4
    }

    var body: some View {
        ZStack {
            Color.black
            FlowView(clock: model.flowClock, brightness: model.recording ? 0.7 : 0.3)
            glow
            LinearGradient(colors: [.black.opacity(0.30), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 16) {
                header
                panel
            }
            .padding(20)
        }
        .frame(width: 440, height: 708)
        .preferredColorScheme(.dark)
        .onAppear {
            updateFlowSpeed()
            if !reduceMotion {   // respect the system Reduce Motion setting
                withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .onChange(of: model.recording) { _, _ in updateFlowSpeed() }
        .onChange(of: model.level) { _, _ in updateFlowSpeed() }
    }

    private func updateFlowSpeed() {
        model.flowClock.targetSpeed = model.recording ? (0.032 + model.level * 0.05) : 0.014
    }

    // MARK: - Hero

    private var glow: some View {
        Circle()
            .fill(RadialGradient(colors: [accent.opacity(0.9), accent.opacity(0.0)],
                                 center: .center, startRadius: 2, endRadius: 150))
            .frame(width: 300, height: 300)
            .blur(radius: 34)
            .scaleEffect((breathe ? 1.05 : 0.95) * (1 + model.glowLevel * 0.3))
            .opacity(glowOpacity)
            .offset(y: -210)
            .blendMode(.plusLighter)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("freeflow")
                .font(.system(size: 34, weight: .medium, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12)
            Text(model.recording ? "listening" : "dictate anywhere")
                .font(.system(size: 10, weight: .semibold)).tracking(5)
                .textCase(.uppercase).foregroundStyle(accent.opacity(0.85))
                .contentTransition(.opacity)
            if !model.captureNote.isEmpty {
                Text(model.captureNote)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
            }
        }
        .padding(.top, 18)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case .setup:   SetupPanel(model: model)
                case .words:   VocabPanel(model: model)
                case .history: HistoryPanel(model: model)
                }
            }
            .frame(height: 348)
        }
        .padding(16)
        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        .font(.system(size: 13))
    }
}
