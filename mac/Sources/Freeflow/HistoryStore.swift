import Foundation

/// A past dictation. `text` is the final, processed transcript; `corrected`
/// is what the user says they actually said, once they fix it.
struct Dictation_Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    let text: String
    let date: Date
    var corrected: String?
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

    @discardableResult
    func add(_ text: String) -> Dictation_Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = Dictation_Entry(text: trimmed, date: Date())
        entries.insert(entry, at: 0)
        if entries.count > cap { entries = Array(entries.prefix(cap)) }
        save()
        return entry
    }

    func setCorrected(id: UUID, text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].corrected = text
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
