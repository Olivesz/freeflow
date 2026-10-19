import Foundation
import FreeflowCore

/// Where a dictation's audio comes from: the microphone in the app, a file
/// played back on the wall clock in the --e2e harness.
protocol AudioSource: AnyObject {
    func start() throws
    func stop()
    func snapshot() -> [Float]
    func recentRMS(ms: Int) -> Float
    func recentQuietestRMS(ms: Int) -> Float
    func rms(fromSec: Double, toSec: Double) -> Float
    /// The input device, for the session log ("MacBook Pro Microphone").
    var deviceName: String { get }
}

/// One token as the decoder produced it, before words are assembled.
struct TokenRecord: Codable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Float
}

/// Decoders that can hand over the tokens behind their last pass.
protocol TokenReporting: AnyObject {
    var lastTokens: [TokenRecord] { get }
    /// True when the last pass was decoded twice (the blank-decode retry).
    var lastRetried: Bool { get }
}

/// Everything one dictation did, as the session log stores it. Times are
/// seconds since the dictation started, on the wall clock.
final class SessionTrace {
    enum StopReason: String { case auto, manual }

    struct TickRecord {
        let t: Double, audioEnd: Double
        let rms: Float?, quietest: Float?, noiseFloor: Float
        let voiced: Bool, silentMs: Int, limitMs: Int, sentenceOpen: Bool, stop: Bool
    }
    struct PassRecord {
        let t: Double
        let pass: Pass
        let tokens: [TokenRecord]
        let retried: Bool
    }
    struct OpRecord { let t: Double; let op: TextOp }

    let id = UUID()
    let started = Date()
    let engine: String
    let config: WhisperStreamer.Config
    let silenceMs: Int, tickMs: Int
    let device: String
    var app: String?                       // bundle id of the app typed into
    var trigger = "toggle"                 // toggle | hold | e2e
    var stopReason: StopReason = .manual
    var ended: Date?
    var ticks: [TickRecord] = []
    var passes: [PassRecord] = []
    var ops: [OpRecord] = []
    var audio: [Float] = []
    var typed = ""

    init(engine: String, config: WhisperStreamer.Config, silenceMs: Int, tickMs: Int, device: String) {
        self.engine = engine; self.config = config
        self.silenceMs = silenceMs; self.tickMs = tickMs; self.device = device
    }

    var now: Double { Date().timeIntervalSince(started) }
}
