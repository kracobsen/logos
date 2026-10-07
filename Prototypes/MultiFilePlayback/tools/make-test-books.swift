// PROTOTYPE — throwaway. Generates the synthetic "talking clock" test Books for the multi-file playback
// prototype (https://github.com/kracobsen/logos/issues/12). Run on the Mac (run.sh does it for you):
//
//   swift tools/make-test-books.swift <output-dir>
//
// Every test Book is the same 15-minute stereo signal, split into files in different ways:
//   left  channel: a voice announcing the Book time every 10 s ("Chapter 3. 4 minutes 20")
//   right channel: one continuous 220 Hz tone, phase-continuous across the whole Book
// So a gap or click at a file boundary is audible in the right ear, and a seek lands where the voice says it should.
// Chapters come from each Book's manifest (`<id>.book.json`), mirroring what the Server reports.

import AVFoundation
import Foundation

let sampleRate = 44_100.0
let bookDuration = 900.0
let chapterStarts: [Double] = [0, 90, 250, 400, 610, 760]
let toneFrequency = 220.0
let toneAmplitude: Float = 0.2

struct Variant {
    let id: String
    let title: String
    let splits: [Double]  // file start times; the last file runs to bookDuration
    let ext: String
}

let variants = [
    Variant(id: "clock-single", title: "Clock · single file (.m4b)", splits: [0], ext: "m4b"),
    Variant(id: "clock-perchapter", title: "Clock · one file per Chapter (AAC)", splits: chapterStarts, ext: "m4a"),
    // Splits off Chapter boundaries, a 7 s file, and one split in the middle of a spoken announcement (400.7 s).
    Variant(id: "clock-oddsplits", title: "Clock · odd splits (AAC)", splits: [0, 137.3, 144.3, 400.7, 655.05], ext: "m4a"),
    Variant(id: "clock-oddsplits-mp3", title: "Clock · odd splits (MP3)", splits: [0, 137.3, 144.3, 400.7, 655.05], ext: "mp3"),
]

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TestBooks")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("logos-clock-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func chapterIndex(at t: Double) -> Int { chapterStarts.lastIndex { $0 <= t }! }

func shell(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// 1. Speech for every 10 s mark, as mono Float32 at sampleRate.
print("Synthesising announcements…")
var announcements: [(start: Int, samples: [Float])] = []
for mark in stride(from: 0.0, to: bookDuration, by: 10) {
    let m = Int(mark) / 60, s = Int(mark) % 60
    let text = "Chapter \(chapterIndex(at: mark) + 1). \(m) minute\(m == 1 ? "" : "s") \(s)"
    let aiff = scratch.appendingPathComponent("say-\(Int(mark)).caf")
    guard shell(["say", "-o", aiff.path, "--data-format=LEF32@44100", text]) == 0 else { fatalError("say failed") }
    let file = try AVAudioFile(forReading: aiff, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    announcements.append((Int(mark * sampleRate), samples.map { $0 * 0.8 }))
}

// 2. Render frames [from, to) of the Book into a stereo buffer.
let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
func render(from: Int, to: Int) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(to - from))!
    buf.frameLength = AVAudioFrameCount(to - from)
    let left = buf.floatChannelData![0], right = buf.floatChannelData![1]
    for i in 0..<(to - from) {
        let n = from + i
        left[i] = 0
        right[i] = toneAmplitude * Float(sin(2 * .pi * toneFrequency * Double(n) / sampleRate))
    }
    for a in announcements where a.start < to && a.start + a.samples.count > from {
        for j in max(a.start, from)..<min(a.start + a.samples.count, to) { left[j - from] = a.samples[j - a.start] }
    }
    return buf
}

func write(_ url: URL, from: Int, to: Int, settings: [String: Any]) throws {
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = Int(sampleRate) * 30
    var n = from
    while n < to {
        try file.write(from: render(from: n, to: min(n + chunk, to)))
        n += chunk
    }
}

let aac: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000,
]
let wav: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
]
let hasLame = shell(["which", "lame"]) == 0

// 3. Write each variant's files plus its manifest.
for v in variants {
    if v.ext == "mp3" && !hasLame {
        print("Skipping \(v.id): `lame` not installed (brew install lame)")
        continue
    }
    print("Writing \(v.id)…")
    var tracks: [[String: Any]] = []
    for (i, start) in v.splits.enumerated() {
        let end = i + 1 < v.splits.count ? v.splits[i + 1] : bookDuration
        let from = Int((start * sampleRate).rounded()), to = Int((end * sampleRate).rounded())
        let name = "\(v.id)-\(String(format: "%02d", i + 1)).\(v.ext)"
        let url = out.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        switch v.ext {
        case "mp3":
            let tmp = scratch.appendingPathComponent("\(name).wav")
            try write(tmp, from: from, to: to, settings: wav)
            guard shell(["lame", "--quiet", "-b", "128", tmp.path, url.path]) == 0 else { fatalError("lame failed") }
        case "m4b":
            let tmp = scratch.appendingPathComponent("\(name).m4a")
            try write(tmp, from: from, to: to, settings: aac)
            try FileManager.default.moveItem(at: tmp, to: url)
        default:
            try write(url, from: from, to: to, settings: aac)
        }
        tracks.append(["file": name, "startOffset": Double(from) / sampleRate, "duration": Double(to - from) / sampleRate])
    }
    let chapters = chapterStarts.enumerated().map { i, start -> [String: Any] in
        ["title": "Chapter \(i + 1)", "start": start, "end": i + 1 < chapterStarts.count ? chapterStarts[i + 1] : bookDuration]
    }
    let manifest: [String: Any] = [
        "id": v.id, "title": v.title, "author": "Logos prototype", "duration": bookDuration,
        "hasToneChannel": true, "tracks": tracks, "chapters": chapters,
    ]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: out.appendingPathComponent("\(v.id).book.json"))
}
print("Done → \(out.path)")
