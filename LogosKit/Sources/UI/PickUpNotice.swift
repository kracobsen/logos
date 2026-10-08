import Playback
import SwiftUI

/// "Picked up from another device: <time> · Undo", after the paused Book moved to where another device left it.
enum PickUpNotice {
    static func text(_ pickedUp: Player.PickedUp) -> String {
        let place = pickedUp.isFinished ? "Finished" : BookDetailModel.clock(pickedUp.position)
        return "Picked up from another device: \(place)"
    }
}

/// The notice as a banner in the player sheet: the text, Undo, and a close button.
struct PickUpBanner: View {
    let player: Player

    var body: some View {
        if let pickedUp = player.pickedUp {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(PickUpNotice.text(pickedUp))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Undo") { player.undoPickUp() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Goes back to where this iPhone was")
                Button {
                    player.dismissPickUp()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
        }
    }
}
