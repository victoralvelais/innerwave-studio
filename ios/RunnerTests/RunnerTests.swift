import AVFoundation
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testDecodeKeepsTheTwoChannelsSeparateWhileResampling() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("right-only.wav")
    let target = folder.appendingPathComponent("converted.pcm")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = buffer.frameCapacity
    let samples = try XCTUnwrap(buffer.floatChannelData)
    for frame in 0..<Int(buffer.frameLength) {
      samples[0][frame] = 0
      samples[1][frame] = Float(0.35 * sin(2 * Double.pi * 227 * Double(frame) / 48_000))
    }
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: source, settings: format.settings)
      try file.write(from: buffer)
    }
    let frames = try AppDelegate.decode(input: source.path, output: target.path)
    XCTAssertEqual(Double(frames), 44_100, accuracy: 4)
    let bytes = try Data(contentsOf: target)
    XCTAssertEqual(bytes.count, Int(frames) * 4)
    var peakRight = 0
    for i in stride(from: 0, to: bytes.count, by: 4) {
      let left = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
      let right = Int16(bitPattern: UInt16(bytes[i + 2]) | (UInt16(bytes[i + 3]) << 8))
      XCTAssertLessThanOrEqual(abs(Int(left)), 2)
      peakRight = max(peakRight, abs(Int(right)))
    }
    XCTAssertGreaterThan(peakRight, 8000)
  }

}
