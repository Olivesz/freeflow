import Foundation
import FreeflowCore
import SQLite3

/// Opt-in, local-only log of every dictation, the raw material for tuning:
/// the audio, every decoder pass with its tokens, every endpointer tick, every
/// edit typed, how it stopped, and what the user later did to the text
/// (`CorrectionWatcher`). One SQLite file plus a WAV per session, under
/// Application Support/freeflow/sessions. Nothing here leaves the Mac.
///
/// `bench/voice/` reads it. Times are seconds since the dictation started;
/// dates are Unix seconds.
final class SessionLog {
    static let shared = SessionLog(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("freeflow/sessions", isDirectory: true))
    static let schemaVersion = 1

    let dir: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "freeflow.sessionlog", qos: .utility)

    init(dir: URL) { self.dir = dir }

    var dbURL: URL { dir.appendingPathComponent("sessions.sqlite") }

    // MARK: writes

    func record(_ t: SessionTrace) {
        queue.async { [self] in
            guard open() else { return }
            let wav = dir.appendingPathComponent("\(t.id.uuidString).wav")
            if !t.audio.isEmpty { try? Self.wav(t.audio).write(to: wav, options: .atomic) }
            exec("BEGIN")
            insert("""
                INSERT INTO sessions(id, started, ended, engine, window_after, window_context, silence_ms,
                  tick_ms, device, app, trigger, stop_reason, audio, audio_s, typed)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [t.id.uuidString, t.started.timeIntervalSince1970, t.ended?.timeIntervalSince1970,
                      t.engine, t.config.trimAfter.isFinite ? t.config.trimAfter : nil, t.config.context,
                      t.silenceMs, t.tickMs, t.device, t.app, t.trigger, t.stopReason.rawValue,
                      t.audio.isEmpty ? nil : wav.lastPathComponent, Double(t.audio.count) / 16000, t.typed])
            for (i, p) in t.passes.enumerated() {
                insert("""
                    INSERT INTO passes(session, idx, t, audio_end, window_start, decode_ms, final, retried,
                      words, committed, tokens) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, [t.id.uuidString, i, p.t, p.pass.audioEnd, p.pass.windowStart, p.pass.decodeMs,
                          p.pass.final, p.retried, Self.json(p.pass.hypothesis), Self.json(p.pass.committed),
                          Self.json(p.tokens)])
            }
            for (i, k) in t.ticks.enumerated() {
                insert("""
                    INSERT INTO ticks(session, idx, t, audio_end, rms, quietest, noise_floor, voiced, silent_ms,
                      limit_ms, sentence_open, stop) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [t.id.uuidString, i, k.t, k.audioEnd, k.rms, k.quietest, k.noiseFloor, k.voiced,
                          k.silentMs, k.limitMs, k.sentenceOpen, k.stop])
            }
            for (i, o) in t.ops.enumerated() {
                switch o.op {
                case .insert(let s): insert("INSERT INTO ops(session, idx, t, kind, text) VALUES(?,?,?,?,?)",
                                            [t.id.uuidString, i, o.t, "insert", s])
                case .delete(let n): insert("INSERT INTO ops(session, idx, t, kind, n) VALUES(?,?,?,?,?)",
                                            [t.id.uuidString, i, o.t, "delete", n])
                }
            }
            exec("COMMIT")
        }
    }

    /// The user's own transcript of a session, from History: `fixed` when
    /// they edited it, `confirmed` when they marked it right.
    func setReference(id: UUID, text: String, kind: String) {
        queue.async { [self] in
            guard open() else { return }
            insert("UPDATE sessions SET reference = ?, reference_kind = ?, reference_at = ? WHERE id = ?",
                   [text, kind, Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// What the dictated text became in the field (`CorrectionWatcher`).
    func recordEdit(id: UUID, status: String, app: String?, delay: Double, typed: String?,
                    followed: CorrectionTrail.Followed?) {
        queue.async { [self] in
            guard open() else { return }
            insert("""
                INSERT INTO edits(session, checked_at, delay_s, app, status, typed, now, distance, anchored)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [id.uuidString, Date().timeIntervalSince1970, delay, app, status, typed,
                      followed?.text, followed?.distance, followed?.anchored])
        }
    }

    var count: Int {
        queue.sync {
            guard FileManager.default.fileExists(atPath: dbURL.path), open() else { return 0 }
            return scalarInt("SELECT count(*) FROM sessions")
        }
    }

    func deleteAll() {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Blocks until every queued write has landed (the harness, before exit).
    func drain() { queue.sync {} }

    // MARK: SQLite

    private func open() -> Bool {
        if db != nil { return true }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { db = nil; return false }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS sessions(
              id TEXT PRIMARY KEY, started REAL, ended REAL, engine TEXT,
              window_after REAL, window_context REAL, silence_ms INTEGER, tick_ms INTEGER,
              device TEXT, app TEXT, trigger TEXT, stop_reason TEXT, audio TEXT, audio_s REAL,
              typed TEXT, reference TEXT, reference_kind TEXT, reference_at REAL);
            CREATE TABLE IF NOT EXISTS passes(
              session TEXT, idx INTEGER, t REAL, audio_end REAL, window_start REAL, decode_ms REAL,
              final INTEGER, retried INTEGER, words TEXT, committed TEXT, tokens TEXT);
            CREATE TABLE IF NOT EXISTS ticks(
              session TEXT, idx INTEGER, t REAL, audio_end REAL, rms REAL, quietest REAL,
              noise_floor REAL, voiced INTEGER, silent_ms INTEGER, limit_ms INTEGER,
              sentence_open INTEGER, stop INTEGER);
            CREATE TABLE IF NOT EXISTS ops(session TEXT, idx INTEGER, t REAL, kind TEXT, text TEXT, n INTEGER);
            CREATE TABLE IF NOT EXISTS edits(
              session TEXT, checked_at REAL, delay_s REAL, app TEXT, status TEXT,
              typed TEXT, now TEXT, distance INTEGER, anchored INTEGER);
            CREATE INDEX IF NOT EXISTS passes_s ON passes(session);
            CREATE INDEX IF NOT EXISTS ticks_s ON ticks(session);
            CREATE INDEX IF NOT EXISTS ops_s ON ops(session);
            CREATE INDEX IF NOT EXISTS edits_s ON edits(session);
            """)
        insert("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [String(Self.schemaVersion)])
        return true
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func insert(_ sql: String, _ values: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() {
            let k = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, k)
            case let x as String: sqlite3_bind_text(stmt, k, x, -1, Self.transient)
            case let x as Bool: sqlite3_bind_int(stmt, k, x ? 1 : 0)
            case let x as Int: sqlite3_bind_int64(stmt, k, Int64(x))
            case let x as Double: sqlite3_bind_double(stmt, k, x)
            case let x as Float: sqlite3_bind_double(stmt, k, Double(x))
            default: sqlite3_bind_null(stmt, k)
            }
        }
        sqlite3_step(stmt)
    }

    private func scalarInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private struct JWord: Encodable { let w: String; let s: Double; let e: Double; let c: Float? }

    private static func json(_ words: [Word]) -> String {
        json(words.map { JWord(w: $0.text, s: $0.start, e: $0.end, c: $0.confidence) })
    }

    private static func json<T: Encodable>(_ v: T) -> String {
        (try? JSONEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
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
