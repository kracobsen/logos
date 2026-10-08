import Domain
import Playback
import SwiftUI

/// Puts the player into the tab shell: the player in the environment, the mini-player as the tab view's bottom
/// accessory (once a Book is loaded) opening the full-height player sheet, the last-played Book restored paused just
/// after launch, playback stopped when the loaded Book's Download goes away, and a save on going to the background.
struct PlayerChrome: ViewModifier {
    let player: Player?
    @State private var showsPlayer = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .tabViewBottomAccessory(isEnabled: player?.book != nil) {
                if let player {
                    MiniPlayerView(player: player) { showsPlayer = true }
                }
            }
            .sheet(isPresented: $showsPlayer) {
                if let player {
                    PlayerSheet(player: player)
                        .presentationDetents([.large])
                }
            }
            .onChange(of: player?.book == nil) { _, unloaded in
                if unloaded { showsPlayer = false }
            }
            .environment(player)
            .task {
                // Off the critical path: after the first frame, once the Library is interactive. Never plays.
                await Task.yield()
                await player?.restoreLastPlayed()
            }
            .task { await player?.observeDownloads() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { player?.enteredBackground() }
            }
    }
}
