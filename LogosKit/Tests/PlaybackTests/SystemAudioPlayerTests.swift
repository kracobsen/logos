import AVFoundation
import Foundation
import Playback
import Testing

/// The real AVPlayer adapter against real AAC files written here, so the timeline maths is checked on AVFoundation
/// itself. Listening for gaps at file boundaries stays a manual check (prototype #12).
@Suite("The AVPlayer composition player")
@MainActor
struct SystemAudioPlayerTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    /// Writes `seconds` of a quiet tone as AAC in an .m4a file.
    func audioFile(_ name: String, seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.1 * sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    @Test("Files load back to back as one timeline, and seeks across file boundaries land exactly")
    func timeline() async throws {
        let files = [try audioFile("1.m4a", seconds: 2), try audioFile("2.m4a", seconds: 3)]
        let player = SystemAudioPlayer()

        try await player.load(files)
        #expect(player.currentTime == 0)

        await player.seek(to: 3.5)  // inside the second file
        #expect(abs(player.currentTime - 3.5) < 0.001)
        await player.seek(to: 1.25)
        #expect(abs(player.currentTime - 1.25) < 0.001)
        player.unload()
    }

    @Test("Sped-up speech keeps its pitch: the timeline uses the spectral time-pitch algorithm")
    func spectralPitch() async throws {
        let player = SystemAudioPlayer()
        player.rate = 1.5

        try await player.load([try audioFile("1.m4a", seconds: 1)])

        #expect(player.pitchAlgorithm == .spectral)
        #expect(player.rate == 1.5)
        player.unload()
    }

    @Test("A missing file fails the load")
    func missingFile() async throws {
        let player = SystemAudioPlayer()
        await #expect(throws: (any Error).self) {
            try await player.load([directory.appending(path: "missing.m4a")])
        }
    }
}
