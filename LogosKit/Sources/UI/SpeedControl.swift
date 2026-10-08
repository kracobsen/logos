import Domain
import Playback
import SwiftUI

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
                .presentationDetents([.height(300)])
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
