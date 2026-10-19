import Foundation

/// Opt-in, local-only recordings of dictations: the 16 kHz audio, what was
/// typed, and — once the user fixes it in History — what they actually said.
/// Corrected recordings are the personal benchmark (`bench/personal.py`) and
/// the data any tuning learns from. Nothing here leaves the Mac; off by default.
final class RecordingStore {
    static let shared = RecordingStore()
    static let cap = 300

    struct Meta: Codable {
        let id: UUID
        let date: Date
        let typed: String
        var corrected: String?
        let seconds: Double
        let model: String
    }

    let dir: URL
    private let queue = DispatchQueue(label: "freeflow.recordings", qos: .utility)

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freeflow/recordings", isDirectory: true)
    }

    var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".json") }.count ?? 0
    }

    func save(id: UUID, audio: [Float], typed: String, model: String) {
        queue.async { [dir] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = Meta(id: id, date: Date(), typed: typed, corrected: nil,
                            seconds: Double(audio.count) / 16000, model: model)
            guard (try? Self.wav(audio).write(to: dir.appendingPathComponent("\(id).wav"), options: .atomic)) != nil
            else { return }
            Self.write(meta, to: dir.appendingPathComponent("\(id).json"))
            self.prune()
        }
    }

    func setCorrected(id: UUID, text: String) {
        queue.async { [dir] in
            let url = dir.appendingPathComponent("\(id).json")
            guard var meta = (try? Data(contentsOf: url)).flatMap({ try? Self.decoder.decode(Meta.self, from: $0) })
            else { return }
            meta.corrected = text
            Self.write(meta, to: url)
        }
    }

    func deleteAll() {
        queue.sync { _ = try? FileManager.default.removeItem(at: dir) }
    }

    /// Keep the newest `cap` recordings.
    private func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let metas = names.filter { $0.hasSuffix(".json") }.compactMap { name -> (String, Date)? in
            let url = dir.appendingPathComponent(name)
            guard let m = (try? Data(contentsOf: url)).flatMap({ try? Self.decoder.decode(Meta.self, from: $0) })
            else { return nil }
            return (m.id.uuidString, m.date)
        }.sorted { $0.1 > $1.1 }
        for (id, _) in metas.dropFirst(Self.cap) {
            try? fm.removeItem(at: dir.appendingPathComponent("\(id).json"))
            try? fm.removeItem(at: dir.appendingPathComponent("\(id).wav"))
        }
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static func write(_ meta: Meta, to url: URL) {
        try? encoder.encode(meta).write(to: url, options: .atomic)
    }

    /// 16-bit PCM mono WAV at 16 kHz.
    static func wav(_ x: [Float]) -> Data {
        var pcm = Data(capacity: x.count * 2)
        for s in x {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d += u32(UInt32(36 + pcm.count)); d += Data("WAVE".utf8)
        d += Data("fmt ".utf8); d += u32(16); d += u16(1); d += u16(1)
        d += u32(16000); d += u32(32000); d += u16(2); d += u16(16)
        d += Data("data".utf8); d += u32(UInt32(pcm.count)); d += pcm
        return d
    }
}
