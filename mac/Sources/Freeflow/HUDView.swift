import SwiftUI

/// The floating dictation pill. Lives in a non-activating panel, so showing it
/// never steals focus from your text field — it's pure feedback. A voice-lit
/// dot, your live transcript, and (once stopped) a Copy button so words are
/// recoverable even if they had nowhere to land.
struct HUDView: View {
    @ObservedObject var model: AppModel
    var onCopy: () -> Void

    private var accent: Color {
        model.recording ? Color(red: 0.98, green: 0.74, blue: 0.55)
                        : Color(red: 0.72, green: 0.86, blue: 0.98)
    }

    private var text: String {
        if !model.transcript.isEmpty { return model.transcript }
        return model.recording ? "listening…" : ""
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
                .shadow(color: accent, radius: 5 + model.glowLevel * 8)
                .scaleEffect(model.recording ? 1 + model.glowLevel * 0.7 : 1)
                .animation(.easeOut(duration: 0.15), value: model.glowLevel)

            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.head)                 // keep the newest words in view
                .frame(maxWidth: .infinity, alignment: .leading)

            if !model.recording && !model.transcript.isEmpty {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(width: 420)
        .background(.black.opacity(0.74), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}
