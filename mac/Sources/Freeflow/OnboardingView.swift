import SwiftUI

/// Drives the first-run walkthrough. The window controller polls the real
/// permission state into `micOK` / `axOK` so checkmarks flip live the moment the
/// user grants access in System Settings.
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var micOK = false
    @Published var micDenied = false     // denied/restricted → the system won't re-prompt
    @Published var axOK = false
    @Published var tryText = ""

    var shortcut: String { Settings.shared.shortcutLabel }

    var onRequestMic: () -> Void = {}
    var onOpenAccessibility: () -> Void = {}
    var onFinish: () -> Void = {}

    static let steps = 4
}

/// A calm, four-step welcome: what it is → microphone → Accessibility → try it.
/// Ends in a live text box so the very first thing the user does is watch their
/// own voice become text.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            Color.black
            InkBackdrop().opacity(0.5)
            LinearGradient(colors: [.black.opacity(0.2), .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                Spacer(minLength: 20)
                footer
            }
            .padding(28)
        }
        .frame(width: 460, height: 560)
        .preferredColorScheme(.dark)
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch model.step {
        case 0: welcome
        case 1: permission(
            icon: "mic.fill", title: "Let freeflow hear you",
            body: model.micDenied
                ? "Microphone access was declined. Open System Settings → Privacy → Microphone, switch freeflow on, and this will tick automatically."
                : "It listens only while you hold the shortcut, and everything stays on your Mac — nothing is ever uploaded.",
            granted: model.micOK,
            actionTitle: model.micDenied ? "Open System Settings" : "Enable microphone",
            action: model.onRequestMic)
        case 2: permission(
            icon: "keyboard.fill", title: "Let freeflow type for you",
            body: "macOS needs your OK for an app to type into other apps. Open Accessibility, find freeflow, and switch it on.",
            granted: model.axOK, actionTitle: "Open Accessibility settings", action: model.onOpenAccessibility)
        default: tryIt
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Text("freeflow")
                .font(.system(size: 46, weight: .medium, design: .serif))
                .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 14)
            Text("Speak anywhere you can type.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
            Text("Press \(Text(model.shortcut).font(.system(size: 14, weight: .semibold, design: .monospaced))), talk, and your words appear in whatever app you're in. Free, private, on-device.")
                .font(.system(size: 13)).foregroundStyle(Color.ffFaint)
                .multilineTextAlignment(.center).lineSpacing(3)
                .padding(.horizontal, 8)
        }
    }

    private func permission(icon: String, title: String, body: String,
                            granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.ffAccent.opacity(0.14)).frame(width: 78, height: 78)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(granted ? .green : Color.ffAccent)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            Text(body).font(.system(size: 13)).foregroundStyle(Color.ffFaint)
                .multilineTextAlignment(.center).lineSpacing(3)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
            } else {
                Button(action: action) { Text(actionTitle).frame(minWidth: 200) }
                    .buttonStyle(.borderedProminent).tint(Color.ffAccent).controlSize(.large)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 16) {
            Text(model.tryText.isEmpty ? "Try it" : "It works ✨")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.opacity)
            Text("Click the box, hold \(Text(model.shortcut).font(.system(size: 13, weight: .semibold, design: .monospaced))), and say “hello, this is my new voice.”")
                .font(.system(size: 13)).foregroundStyle(Color.ffFaint)
                .multilineTextAlignment(.center).lineSpacing(3)
            TextField("your words will appear here…", text: $model.tryText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14))
                .lineLimit(3, reservesSpace: true)
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ffAccent.opacity(0.4)))
        }
    }

    // MARK: - Footer (progress dots + advance)

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<OnboardingModel.steps, id: \.self) { i in
                    Circle()
                        .fill(i == model.step ? Color.ffAccent : .white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(action: advance) {
                Text(primaryTitle).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent).tint(Color.ffAccent).controlSize(.large)
            .disabled(!canAdvance)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case 0: return "Get started"
        case OnboardingModel.steps - 1: return "Done"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch model.step {
        case 1: return model.micOK
        case 2: return model.axOK
        default: return true
        }
    }

    private func advance() {
        if model.step >= OnboardingModel.steps - 1 { model.onFinish() }
        else { withAnimation(.easeInOut(duration: 0.25)) { model.step += 1 } }
    }
}

/// A still ink field (no animation) — the logo's texture, used as a quiet
/// backdrop so onboarding feels like the same object as the main window.
struct InkBackdrop: View {
    private let field = FlowField.shared
    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width, y: size.height)
            for p in field.paths {
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 1.0 / size.width)
            }
        }
    }
}
