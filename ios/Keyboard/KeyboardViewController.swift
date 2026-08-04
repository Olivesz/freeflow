import AVFoundation
import Speech
import UIKit

/// The spike: can a custom keyboard extension reach the mic + on-device Speech,
/// and insert the transcript straight into the focused field (no paste)?
/// The on-screen status label reports exactly what happens at each step.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var listening = false
    private var typed = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        nextButton.setTitle("🌐  next keyboard", for: .normal)
        nextButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        micButton.setTitle("🎙  Tap to dictate", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        micButton.backgroundColor = .systemBlue
        micButton.setTitleColor(.white, for: .normal)
        micButton.layer.cornerRadius = 14
        micButton.contentEdgeInsets = UIEdgeInsets(top: 16, left: 28, bottom: 16, right: 28)
        micButton.addTarget(self, action: #selector(toggleMic), for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = hasFullAccess ? "ready — tap the mic" : "⚠️ needs Allow Full Access"

        let stack = UIStackView(arrangedSubviews: [nextButton, micButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    @objc private func toggleMic() { listening ? stop() : start() }

    private func start() {
        guard hasFullAccess else { status("⚠️ enable Allow Full Access in Settings"); return }
        guard let recognizer, recognizer.isAvailable else { status("recognizer unavailable"); return }
        typed = ""
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .measurement, options: .duckOthers)
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { status("audio session: \(error.localizedDescription)"); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
            [weak self] buffer, _ in self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { status("engine: \(error.localizedDescription)"); return }

        let onDevice = recognizer.supportsOnDeviceRecognition
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async { self.reconcile(result.bestTranscription.formattedString) }
                if result.isFinal { self.stop() }
            }
            if let error { self.fail("recog: \(error.localizedDescription)") }
        }
        listening = true
        micButton.setTitle("●  Listening — tap to stop", for: .normal)
        micButton.backgroundColor = .systemRed
        status("listening\(onDevice ? " (on-device)" : "")… speak now")
    }

    /// In-place streaming edit into the focused field via the keyboard proxy.
    private func reconcile(_ full: String) {
        let old = Array(typed), new = Array(full)
        var i = 0
        while i < old.count && i < new.count && old[i] == new[i] { i += 1 }
        for _ in 0..<(old.count - i) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(String(new[i...]))
        typed = full
    }

    private func stop() { teardown(status: "done — tap to dictate again") }

    /// Stop but keep the error visible on screen (don't overwrite with "done").
    private func fail(_ msg: String) { teardown(status: "⚠️ " + msg) }

    private func teardown(status message: String) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel(); task = nil; request = nil
        listening = false
        DispatchQueue.main.async {
            self.micButton.setTitle("🎙  Tap to dictate", for: .normal)
            self.micButton.backgroundColor = .systemBlue
            self.status(message)
        }
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func status(_ s: String) {
        DispatchQueue.main.async { self.statusLabel.text = s }
    }
}
