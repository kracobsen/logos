// PROTOTYPE — throwaway. An MTAudioProcessingTap that watches the right channel of the synthetic test Books
// (a continuous 220 Hz tone) for silence runs and sample jumps: the content-level traces of a gap or click
// at a file boundary, e.g. AAC priming/padding that wasn't trimmed.
//
// Limits: it sees decoded source audio with source timestamps, so a gap the player inserts *between* two
// queue items (no samples at all) is invisible here. Listen for that with headphones. It's also blind on real
// Books, which have no tone channel.

import AVFoundation
import MediaToolbox

nonisolated final class GapDetector: @unchecked Sendable {
    struct Event: Sendable {
        let bookTime: Double
        let text: String
    }

    private let lock = NSLock()
    private var pending: [Event] = []

    // Render-thread state, shared across queue items so a jump between files is still seen.
    fileprivate var lastSample: Float?
    fileprivate var lastBookTime: Double = -1
    fileprivate var silentRun = 0
    fileprivate var silentStart: Double = 0
    fileprivate var lastEventTime: Double = -10

    func drain() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = []
        return out
    }

    func reset() {
        lock.lock()
        pending = []
        lock.unlock()
    }

    fileprivate func report(_ t: Double, _ text: String) {
        guard t - lastEventTime > 0.05 else { return }
        lastEventTime = t
        lock.lock()
        pending.append(Event(bookTime: t, text: text))
        lock.unlock()
    }

    /// Returns an audio mix that taps `track`. `offset` maps the item's own time to Book time.
    func audioMix(for track: AVAssetTrack, offset: Double) -> AVAudioMix? {
        let context = TapContext(detector: self, offset: offset)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.sampleRate = format.pointee.mSampleRate
                ctx.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                ctx.interleaved = format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                ctx.channels = Int(format.pointee.mChannelsPerFrame)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.analyze(bufferList, frames: Int(framesOut.pointee), start: range.start.seconds)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
            let tap
        else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

private nonisolated final class TapContext: @unchecked Sendable {
    let detector: GapDetector
    let offset: Double
    var sampleRate = 44_100.0
    var isFloat = true
    var interleaved = false
    var channels = 2

    init(detector: GapDetector, offset: Double) {
        self.detector = detector
        self.offset = offset
    }

    func analyze(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double) {
        guard isFloat, channels >= 2, start.isFinite, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let samples: UnsafePointer<Float>
        let stride: Int
        if interleaved {
            guard let data = buffers[0].mData else { return }
            samples = UnsafePointer(data.assumingMemoryBound(to: Float.self) + 1)
            stride = channels
        } else {
            guard buffers.count >= 2, let data = buffers[1].mData else { return }
            samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            stride = 1
        }
        let d = detector
        let bookStart = start + offset
        // A seek: don't treat the jump in the waveform as a click.
        if abs(bookStart - d.lastBookTime) > 0.05 { d.lastSample = nil; d.silentRun = 0 }
        let minSilent = Int(sampleRate * 0.002)  // 2 ms of near-zero where a tone should be
        for i in 0..<frames {
            let x = samples[i * stride]
            let t = bookStart + Double(i) / sampleRate
            if abs(x) < 0.003 {
                if d.silentRun == 0 { d.silentStart = t }
                d.silentRun += 1
            } else {
                if d.silentRun >= minSilent {
                    d.report(d.silentStart, String(format: "silence %.1f ms in the tone", Double(d.silentRun) / sampleRate * 1000))
                }
                d.silentRun = 0
            }
            // The tone's largest natural step between samples is ~0.006; 0.08 is a click.
            if let last = d.lastSample, abs(x - last) > 0.08 {
                d.report(t, String(format: "click: jump of %.2f between samples", abs(x - last)))
            }
            d.lastSample = x
        }
        d.lastBookTime = bookStart + Double(frames) / sampleRate
    }
}
