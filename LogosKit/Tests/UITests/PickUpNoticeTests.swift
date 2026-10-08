import Playback
import Testing

@testable import UI

@Suite("The Picked up from another device notice")
@MainActor
struct PickUpNoticeTests {
    @Test("It says where the Book was picked up, as a Book time")
    func text() {
        #expect(
            PickUpNotice.text(Player.PickedUp(position: 3723.4, isFinished: false))
                == "Picked up from another device: 1:02:03")
        #expect(
            PickUpNotice.text(Player.PickedUp(position: 75, isFinished: false))
                == "Picked up from another device: 1:15")
        #expect(
            PickUpNotice.text(Player.PickedUp(position: 3600, isFinished: true))
                == "Picked up from another device: Finished")
    }
}
