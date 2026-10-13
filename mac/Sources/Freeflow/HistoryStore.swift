import Foundation

/// A past dictation. `text` is the final, processed transcript.
struct Dictation_Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    let text: String
    let date: Date
}

/// Persists the last N dictations to Application Support so you can recover or
/// re-insert something you lost. Local-only, capped, plain JSON — no cloud.
final class HistoryStore {
    static let shared = HistoryStore()
    private let cap = 50
    private let url: URL

    private(set) var entries: [Dictation_Entry] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Dictation_Entry(text: trimmed, date: Date()), at: 0)
        if entries.count > cap { entries = Array(entries.prefix(cap)) }
        save()
    }

    func clear() { entries = []; save() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Dictation_Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
