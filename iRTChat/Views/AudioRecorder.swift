import AVFoundation
import Foundation

/// 16 kHz mono WAV recorder for Gemma 4 audio input (≤ 30 s, per model card).
@Observable
@MainActor
final class AudioRecorder: NSObject {
  static let maxDuration: TimeInterval = 30

  private(set) var isRecording = false
  private(set) var elapsed: TimeInterval = 0
  private(set) var finishedURL: URL?
  var permissionDenied = false
  var errorMessage: String?

  private var recorder: AVAudioRecorder?
  private var timer: Timer?
  private var autoStopTask: Task<Void, Never>?

  func toggle() async {
    if isRecording {
      stop()
      return
    }
    let granted = await AVAudioApplication.requestRecordPermission()
    guard granted else {
      permissionDenied = true
      return
    }
    start()
  }

  func stop() {
    guard isRecording else { return }
    autoStopTask?.cancel()
    autoStopTask = nil
    timer?.invalidate()
    timer = nil
    if let recorder { elapsed = recorder.currentTime }
    recorder?.stop()
    finishedURL = recorder?.url
    recorder = nil
    isRecording = false
    try? AVAudioSession.sharedInstance().setActive(false)
  }

  /// Delete the staged recording (call after the message is sent).
  func discard() {
    if isRecording { stop() }
    if let url = finishedURL {
      try? FileManager.default.removeItem(at: url)
    }
    finishedURL = nil
    elapsed = 0
  }

  private func start() {
    discard()
    errorMessage = nil
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("irt-audio-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    do {
      try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
      try AVAudioSession.sharedInstance().setActive(true)
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      self.recorder = recorder
      guard recorder.record() else {
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        errorMessage = "Couldn't start recording."
        return
      }
      isRecording = true
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        // Read the recorder's clock (a counted timer drifts under load).
        Task { @MainActor in
          if let self, let recorder = self.recorder { self.elapsed = recorder.currentTime }
        }
      }
      autoStopTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.maxDuration))
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.stop() }
      }
    } catch {
      errorMessage = error.localizedDescription
      isRecording = false
    }
  }
}
