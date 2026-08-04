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

/// The freeflow window: a calm, living surface. Animated ink current + a
/// breathing, voice-reactive glow. The light tracks loudness (fast); the flow
/// tracks a smoothed envelope (slow) — two instruments, not one.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var breathe = false

    private var accent: Color {
        model.recording ? Color(red: 0.98, green: 0.74, blue: 0.55)
                        : Color(red: 0.72, green: 0.86, blue: 0.98)
    }
    private var glowOpacity: Double {
        model.recording ? min(0.85, 0.45 + model.glowLevel * 0.5) : 0.4   // never too dim/bright
    }

    var body: some View {
        ZStack {
            Color.black
            FlowView(clock: model.flowClock, brightness: model.recording ? 0.7 : 0.3)
            glow
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
            content
        }
        .frame(width: 440, height: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            updateFlowSpeed()   // the window controller starts/stops the clock by focus
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: model.recording) { _, _ in updateFlowSpeed() }
        .onChange(of: model.level) { _, _ in updateFlowSpeed() }
    }

    private func updateFlowSpeed() {
        model.flowClock.targetSpeed = model.recording ? (0.032 + model.level * 0.05) : 0.014
    }

    private var glow: some View {
        Circle()
            .fill(RadialGradient(colors: [accent.opacity(0.9), accent.opacity(0.0)],
                                 center: .center, startRadius: 2, endRadius: 150))
            .frame(width: 300, height: 300)
            .blur(radius: 34)
            .scaleEffect((breathe ? 1.05 : 0.95) * (1 + model.glowLevel * 0.3))
            .opacity(glowOpacity)
            .animation(.easeOut(duration: 0.2), value: model.glowLevel)
            .offset(y: -40)
            .blendMode(.plusLighter)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("freeflow")
                .font(.system(size: 40, weight: .medium, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12)
            Text(model.recording ? "listening" : "dictate anywhere")
                .font(.system(size: 11, weight: .semibold)).tracking(5)
                .textCase(.uppercase).foregroundStyle(accent.opacity(0.85))
                .padding(.top, 8).contentTransition(.opacity)
            if !model.captureNote.isEmpty {
                Text(model.captureNote)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 12).transition(.opacity)
            }
            Spacer()
            controls
        }
        .padding(24)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !model.accessibilityOK {
                Button(action: model.grantAccessibility) {
                    Label("Grant Accessibility to type into apps", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            HStack {
                Text("Shortcut").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(model.shortcutLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Button(model.recordingShortcut ? "press…" : "change") { model.beginRecordShortcut() }
                    .buttonStyle(.borderless).tint(accent).font(.system(size: 12))
            }
            HStack {
                Text("Auto-stop").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Slider(value: Binding(get: { model.silenceMs }, set: { model.setSilence($0) }),
                       in: 600...3000).frame(width: 130).tint(accent)
                Text("\(Int(model.silenceMs)) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55)).frame(width: 54, alignment: .trailing)
            }
            HStack {
                Text("Launch at login").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunch($0) }))
                    .labelsHidden().tint(accent)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
    }
}
