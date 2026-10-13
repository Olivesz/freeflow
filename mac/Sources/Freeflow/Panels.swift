import SwiftUI

extension Color {
    /// Calm accent for panel controls — stays constant so controls don't flash
    /// orange while the hero glow reacts to the voice.
    static let ffAccent = Color(red: 0.72, green: 0.86, blue: 0.98)
    static let ffLabel = Color.white.opacity(0.72)
    static let ffFaint = Color.white.opacity(0.45)
}

// MARK: - Setup

/// Shortcut, trigger mode, auto-stop, launch-at-login, and the voice-feature
/// toggles that drive the TextProcessor.
struct SetupPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if !model.accessibilityOK {
                    Button(action: model.grantAccessibility) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Grant Accessibility so freeflow can type into apps")
                        }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }

                labeledRow("Shortcut") {
                    Text(model.shortcutLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    Button(model.recordingShortcut ? "press…" : "change") { model.beginRecordShortcut() }
                        .buttonStyle(.borderless).tint(Color.ffAccent).font(.system(size: 12))
                }

                labeledRow("Trigger") {
                    Picker("", selection: Binding(get: { model.mode },
                                                  set: { model.setMode($0) })) {
                        Text("Tap").tag("toggle")
                        Text("Hold").tag("hold")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }

                labeledRow("Auto-stop") {
                    Slider(value: Binding(get: { model.silenceMs }, set: { model.setSilence($0) }),
                           in: 600...3000).frame(width: 120).tint(Color.ffAccent)
                    Text("\(Int(model.silenceMs)) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.ffFaint).frame(width: 48, alignment: .trailing)
                }

                labeledRow("Launch at login") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunch($0) }))
                        .labelsHidden().tint(Color.ffAccent)
                }

                Divider().overlay(.white.opacity(0.10)).padding(.vertical, 2)

                featureToggle("Clean up filler", "drops “um”, “uh”, “er”", $model.fillerCleanup)
                featureToggle("Voice commands", "“new line”, “new paragraph”, “scratch that”", $model.voiceCommands)
                featureToggle("Auto-capitalize", "capitalize the start of sentences", $model.autoCapitalize)
                featureToggle("Spoken punctuation", "say “period”, “comma”, “question mark”", $model.spokenPunctuation)
            }
            .padding(.vertical, 4)
        }
    }

    private func labeledRow<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.ffLabel)
            Spacer()
            control()
        }
    }

    private func featureToggle(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.white.opacity(0.9))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Color.ffFaint)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Color.ffAccent)
        }
    }
}

// MARK: - Vocabulary

/// Editor for the correction dictionary: spoken word → what to actually type.
struct VocabPanel: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var write = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("Fix words freeflow mishears. What you say → what it types.")
                .font(.system(size: 11)).foregroundStyle(Color.ffFaint)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                field("heard", text: $heard)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Color.ffFaint)
                field("types", text: $write)
                Button(action: add) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Color.ffAccent)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty
                              || write.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.vocabPairs.isEmpty {
                Spacer()
                Text("No corrections yet.\nAdd “neuro → neural” and freeflow fixes it every time.")
                    .font(.system(size: 11)).foregroundStyle(Color.ffFaint)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.vocabPairs, id: \.spoken) { pair in
                            HStack(spacing: 8) {
                                Text(pair.spoken).foregroundStyle(.white.opacity(0.85))
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Color.ffFaint)
                                Text(pair.replacement).foregroundStyle(Color.ffAccent)
                                Spacer()
                                Button { model.removeVocab(pair.spoken) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain).foregroundStyle(Color.ffFaint)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func add() {
        model.addVocab(heard, write)
        heard = ""; write = ""
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: .infinity)
            .onSubmit(add)
    }
}

// MARK: - History

/// The last N dictations — recover or re-copy anything you lost.
struct HistoryPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recent dictations").font(.system(size: 11)).foregroundStyle(Color.ffFaint)
                Spacer()
                if !model.history.isEmpty {
                    Button("Clear") { model.clearHistory() }
                        .buttonStyle(.borderless).tint(Color.ffFaint).font(.system(size: 11))
                }
            }

            if model.history.isEmpty {
                Spacer()
                Text("Nothing yet.\nWhat you dictate shows up here.")
                    .font(.system(size: 11)).foregroundStyle(Color.ffFaint)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.history) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.text)
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(entry.date, style: .relative)
                                        .font(.system(size: 10)).foregroundStyle(Color.ffFaint)
                                    Text("ago").font(.system(size: 10)).foregroundStyle(Color.ffFaint)
                                    Spacer()
                                    Button { model.copyToClipboard(entry.text) } label: {
                                        Image(systemName: "doc.on.doc")
                                    }.buttonStyle(.plain).foregroundStyle(Color.ffAccent).font(.system(size: 11))
                                }
                            }
                            .padding(10)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
}
