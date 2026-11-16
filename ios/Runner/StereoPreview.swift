import AVFoundation

// A single output node plays every clip against the same hardware clock.
// Audio session and microphone routing are owned by the editor transport.
final class StereoPreview {
  let queue = DispatchQueue(label: "studio.innerwave.preview", qos: .userInitiated)
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var accepted: Int64 = 0
  private var finished: Int64 = 0
  private var silentFrames: Int64 = 0
  private var generation: UInt64 = 0

  static func failure(_ message: String) -> NSError {
    NSError(domain: "studio.innerwave.preview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  func start(_ data: Data) throws {
    _ = stop()
    let graph = AVAudioEngine()
    let node = AVAudioPlayerNode()
    graph.attach(node)
    graph.connect(node, to: graph.mainMixerNode, format: format)
    engine = graph
    player = node
    try write(data)
    graph.prepare()
    try graph.start()
    node.play()
  }

  private var nodeFrame: Int64 {
    guard let node = player, let render = node.lastRenderTime,
          let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return 0 }
    return max(0, Int64(Double(time.sampleTime) * format.sampleRate / time.sampleRate))
  }

  var position: Int64 { min(accepted, max(finished, nodeFrame - silentFrames)) }

  func write(_ data: Data) throws {
    guard let node = player else { throw Self.failure("Stereo output has stopped.") }
    guard !data.isEmpty, data.count % 4 == 0,
          let count = AVAudioFrameCount(exactly: data.count / 4),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
          let channels = buffer.floatChannelData else {
      throw Self.failure("Expected complete stereo audio frames.")
    }
    buffer.frameLength = count
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      for frame in 0..<Int(count) {
        let i = frame * 4
        let l = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
        let r = UInt16(bytes[i + 2]) | (UInt16(bytes[i + 3]) << 8)
        channels[0][frame] = Float(Int16(bitPattern: l)) / 32768
        channels[1][frame] = Float(Int16(bitPattern: r)) / 32768
      }
    }
    // If the queue previously drained, elapsed silence is outside project time.
    silentFrames = max(silentFrames, nodeFrame - accepted)
    accepted += Int64(count)
    let edge = accepted
    let epoch = generation
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      self?.queue.async { [weak self] in
        guard let self, self.generation == epoch else { return }
        self.finished = max(self.finished, edge)
      }
    }
  }

  @discardableResult func stop() -> Int64 {
    let at = position
    generation &+= 1
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    accepted = 0
    finished = 0
    silentFrames = 0
    return at
  }
}
