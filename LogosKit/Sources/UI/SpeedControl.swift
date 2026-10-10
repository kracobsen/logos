import Domain
import Playback
import SwiftUI
import AVFoundation

/// The player's Speed control (in the sheet's bordered row): shows the global speed and opens the speed picker.
struct SpeedButton: View {
    let player: Player
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            Text(PlaybackSpeed.label(player.speed))
                .monospacedDigit()
        }
        .accessibilityLabel("Speed")
        .accessibilityValue(PlaybackSpeed.label(player.speed))
        .sheet(isPresented: $isPicking) {
            SpeedPicker(player: player) { isPicking = false }
                .presentationDetents([.height(480)])
        }
    }
}

/// Picks the global speed: the presets, or any speed from 0.5× to 3.0× in 0.05 steps. Applies at once.
struct SpeedPicker: View {
    let player: Player
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(PlaybackSpeed.label(player.speed))
                    .font(.largeTitle.bold().monospacedDigit())
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    ForEach(PlaybackSpeed.presets, id: \.self) { preset in
                        let isCurrent = player.speed == preset
                        Button(PlaybackSpeed.label(preset)) { player.setSpeed(preset) }
                            .buttonStyle(.bordered)
                            .tint(isCurrent ? .accentColor : .secondary)
                            .font(.subheadline.monospacedDigit())
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        player.setSpeed(player.speed - PlaybackSpeed.step)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.title2)
                    }
                    .disabled(player.speed <= PlaybackSpeed.minimum)
                    .accessibilityLabel("Slower")
                    Slider(
                        value: Binding(get: { player.speed }, set: { player.setSpeed($0) }),
                        in: PlaybackSpeed.minimum...PlaybackSpeed.maximum,
                        step: PlaybackSpeed.step
                    )
                    .accessibilityLabel("Speed")
                    .accessibilityValue(PlaybackSpeed.label(player.speed))
                    Button {
                        player.setSpeed(player.speed + PlaybackSpeed.step)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                    }
                    .disabled(player.speed >= PlaybackSpeed.maximum)
                    .accessibilityLabel("Faster")
                }
                .buttonStyle(.plain)
                PrototypeAlgorithmSwitch(player: player)
            }
            .padding(.horizontal, 24)
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
    }
}

/// PROTOTYPE (time-pitch ticket #45, branch prototype/time-pitch-switch): switches the time-pitch algorithm of the
/// playing item live, and jumps straight to the speeds under test. Never merged.
private struct PrototypeAlgorithmSwitch: View {
    let player: Player
    @State private var algorithm = SystemAudioPlayer.timePitchAlgorithm
    @State private var readBack = "–"

    private static let choices: [(String, AVAudioTimePitchAlgorithm)] = [
        ("Spectral", .spectral), ("Time domain", .timeDomain), ("Varispeed", .varispeed),
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("PROTOTYPE: time-pitch algorithm").font(.caption.bold()).foregroundStyle(.orange)
            Picker("Algorithm", selection: $algorithm) {
                ForEach(Self.choices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                ForEach([1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { speed in
                    Button(PlaybackSpeed.label(speed)) { player.setSpeed(speed) }
                        .buttonStyle(.bordered)
                        .tint(player.speed == speed ? .orange : .secondary)
                        .font(.subheadline.monospacedDigit())
                }
            }
            Text("Loaded item: \(readBack) at \(PlaybackSpeed.label(player.speed))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .onChange(of: algorithm, initial: true) {
            SystemAudioPlayer.timePitchAlgorithm = algorithm
            refresh()
        }
        .onChange(of: player.speed) { refresh() }
    }

    private func refresh() {
        let loaded = SystemAudioPlayer.current?.pitchAlgorithm
        readBack = loaded.map { Self.choices.first { $0.1 == loaded }?.0 ?? $0.rawValue } ?? "nothing loaded"
    }
}
