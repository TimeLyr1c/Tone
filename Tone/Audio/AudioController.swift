import AVFoundation
import Combine
import Foundation

private final class OscillatorControls: @unchecked Sendable {
    private let lock = NSLock()
    private var frequency = 440.0
    private var amplitude = 0.0

    func set(frequency: Double, amplitude: Double) {
        lock.lock()
        self.frequency = frequency
        self.amplitude = amplitude
        lock.unlock()
    }

    func snapshot() -> (Double, Double) {
        lock.lock()
        defer { lock.unlock() }
        return (frequency, amplitude)
    }
}

/// Only one analysis job is admitted at a time, so microphone work cannot queue indefinitely.
private final class CaptureProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Tone.pitch", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    // This state is owned by the input tap; the worker only receives immutable snapshots.
    private var inputWindow: PitchInputWindow
    private let detector = PitchDetector()

    init(sampleRate: Double) { inputWindow = PitchInputWindow(sampleRate: sampleRate) }

    func submit(_ buffer: AVAudioPCMBuffer, sampleRate: Double,
                completion: @escaping (PitchReading?, Double) -> Void) {
        guard let channels = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        guard let window = inputWindow.append(samples), gate.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { gate.signal() }
            let rms = sqrt(window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count))
            let reduced = PitchInputWindow.downsample(window, sampleRate: sampleRate)
            let reading = detector.detect(samples: reduced.samples, sampleRate: reduced.rate)
            completion(reading, rms)
        }
    }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var display = PitchDisplay()
    var reading: DisplayPitch? { display.pitch }
    var inputStatus: String { display.status }
    @Published private(set) var isListening = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var playingNote: MusicalNote?
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false

    private var microphoneEngine: AVAudioEngine?
    private var toneEngine: AVAudioEngine?
    private let oscillator = OscillatorControls()
    private var captureID = UUID()
    private var wantsListening = false
    private var tracker = PitchTracker()
    private var activity = AudioActivity()
    private var displayClock: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if value == AVAudioSession.InterruptionType.began.rawValue {
                    self.activity.interruptionBegan()
                    self.halt()
                } else {
                    let allowed = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.activity.interruptionEnded(canResume: allowed)
                    if !allowed { self.errorMessage = "音频中断已结束，点重试恢复。" }
                    self.reconcileActivity()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                  value == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor in
                self?.halt()
                self?.reconcileActivity()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.halt()
                self?.reconcileActivity()
            }
        })
    }

    deinit {
        displayClock?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setProfile(_ profile: TrackingProfile) {
        guard tracker.profile != profile else { return }
        tracker = PitchTracker(profile: profile)
        display = tracker.display
    }

    func setActivity(isActive: Bool, isTuner: Bool) {
        activity.isActive = isActive
        activity.isTuner = isTuner
        reconcileActivity()
    }

    func retry() {
        activity.retry()
        errorMessage = nil
        reconcileActivity()
    }

    private func reconcileActivity() {
        switch activity.target {
        case .off: halt(message: errorMessage)
        case .tuner:
            // Set intent even while an older permission request is still pending.
            wantsListening = true
            Task { await startListening() }
        case .reference: prepareReferenceAudio()
        }
    }

    func startListening() async {
        guard activity.target == .tuner, !isListening, !isRequestingPermission else { return }
        stopToneImmediately()
        errorMessage = nil
        permissionDenied = false
        wantsListening = true
        isRequestingPermission = true
        let granted = await AVAudioApplication.requestRecordPermission()
        isRequestingPermission = false
        guard wantsListening, activity.target == .tuner else { return }
        guard granted else {
            permissionDenied = true
            wantsListening = false
            errorMessage = "需要麦克风权限才能检测音高。请在系统设置中允许 Tone 使用麦克风。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioFailure.noInput
            }
            let processor = CaptureProcessor(sampleRate: format.sampleRate)
            let id = UUID()
            captureID = id
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                processor.submit(buffer, sampleRate: format.sampleRate) { pitch, level in
                    Task { @MainActor [weak self] in
                        guard let self, self.isListening, self.captureID == id else { return }
                        self.receive(pitch, level: level)
                    }
                }
            }
            microphoneEngine = engine
            engine.prepare()
            try engine.start()
            isListening = true
            displayClock?.cancel()
            displayClock = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled, let self, self.isListening else { return }
                    self.display = self.tracker.advance(to: ProcessInfo.processInfo.systemUptime)
                }
            }
        } catch {
            stopListening()
            errorMessage = "无法启动麦克风：\(error.localizedDescription)"
        }
    }

    func stopListening() {
        wantsListening = false
        captureID = UUID()
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        microphoneEngine = nil
        isListening = false
        displayClock?.cancel()
        displayClock = nil
        tracker = PitchTracker(profile: tracker.profile)
        display = tracker.display
        inputLevel = 0
        if toneEngine == nil { deactivateSession() }
    }

    private func receive(_ pitch: PitchReading?, level: Double) {
        let decibels = 20 * log10(max(level, 0.000001))
        inputLevel = max(0, min(1, (decibels + 75) / 65))
        display = tracker.process(pitch, level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    func play(_ note: MusicalNote) {
        guard activity.target == .reference else { return }
        if isListening || wantsListening { stopListening() }
        prepareReferenceAudio()
        guard toneEngine != nil else { return }
        oscillator.set(frequency: note.frequency(), amplitude: 0.22)
        playingNote = note
    }

    func prepareReferenceAudio() {
        guard activity.target == .reference, toneEngine == nil else { return }
        stopListening()
        errorMessage = nil
        permissionDenied = false
        do {
            if toneEngine == nil {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setPreferredIOBufferDuration(0.005)
                try session.setActive(true)
                let engine = AVAudioEngine()
                let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
                guard var waveform = SineOscillator(sampleRate: sampleRate),
                      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                    throw AudioFailure.noOutput
                }
                let controls = oscillator
                let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                    let (frequency, targetAmplitude) = controls.snapshot()
                    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                    waveform.set(frequency: frequency, amplitude: targetAmplitude)
                    for frame in 0..<Int(frameCount) {
                        let value = waveform.nextSample()
                        for buffer in buffers {
                            buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                        }
                    }
                    return noErr
                }
                engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode, format: format)
                toneEngine = engine
                engine.prepare()
                try engine.start()
            }
        } catch {
            stopToneImmediately()
            errorMessage = "无法播放标准音：\(error.localizedDescription)"
        }
    }

    func stopTone() {
        oscillator.set(frequency: playingNote?.frequency() ?? 440, amplitude: 0)
        playingNote = nil
        // Keep the silent engine warm until leaving the pad / entering the background.
        // A new touch only changes oscillator controls; it never starts an audio graph.
    }

    private func stopToneImmediately() {
        oscillator.set(frequency: 440, amplitude: 0)
        toneEngine?.stop()
        toneEngine = nil
        playingNote = nil
        if microphoneEngine == nil { deactivateSession() }
    }

    func halt(message: String? = nil) {
        stopListening()
        stopToneImmediately()
        errorMessage = message
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum AudioFailure: LocalizedError {
    case noInput, noOutput
    var errorDescription: String? {
        switch self {
        case .noInput: return "没有可用的麦克风输入。"
        case .noOutput: return "没有可用的音频输出。"
        }
    }
}
