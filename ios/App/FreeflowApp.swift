import AVFoundation
import Speech
import SwiftUI

@main
struct FreeflowApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("freeflow — keyboard spike")
                        .font(.title2).bold()

                    stepsCard

                    Text("Test field")
                        .font(.headline)
                    TextField("Tap here, switch to the freeflow keyboard (🌐), tap the mic…",
                              text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                }
                .padding()
            }
            .navigationTitle("freeflow")
        }
        .onAppear {
            // Prime the permissions the keyboard will need.
            SFSpeechRecognizer.requestAuthorization { _ in }
            AVAudioApplication.requestRecordPermission { _ in }
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(1, "Settings → General → Keyboard → Keyboards → Add New Keyboard → freeflow")
            label(2, "Tap “freeflow” in that list → enable Allow Full Access")
            label(3, "Return here, tap the field, tap 🌐 to switch to freeflow, then the mic")
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").bold()
            Text(s)
        }.font(.subheadline)
    }
}
