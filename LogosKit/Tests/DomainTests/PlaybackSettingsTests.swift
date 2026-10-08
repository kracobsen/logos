import Domain
import Testing

@Suite("Speed and skip settings")
struct PlaybackSettingsTests {
    @Test("Speeds run from 0.5x to 3.0x in 0.05 steps: others are rounded to the nearest step and held to the range")
    func speedSteps() {
        #expect(PlaybackSpeed.normalized(1.25) == 1.25)
        #expect(PlaybackSpeed.normalized(1.32) == 1.3)
        #expect(PlaybackSpeed.normalized(1.33) == 1.35)
        #expect(PlaybackSpeed.normalized(0.1) == 0.5)
        #expect(PlaybackSpeed.normalized(3.5) == 3.0)
        #expect(PlaybackSpeed.normalized(.nan) == 1.0)
        #expect(PlaybackSpeed.all.count == 51)
        #expect(PlaybackSpeed.all.first == 0.5)
        #expect(PlaybackSpeed.all.last == 3.0)
        #expect(PlaybackSpeed.all[11] == 1.05)
    }

    @Test("The presets are 1.0, 1.25, 1.5, 1.75 and 2.0")
    func presets() {
        #expect(PlaybackSpeed.presets == [1.0, 1.25, 1.5, 1.75, 2.0])
    }

    @Test("Skips are 10, 15, 30 or 60 s; back defaults to 15 and forward to 30, at 1x")
    func defaults() {
        #expect(SkipInterval.allCases.map(\.seconds) == [10, 15, 30, 60])
        #expect(PlaybackSettings.default == PlaybackSettings(speed: 1, skipBack: .fifteen, skipForward: .thirty))
    }

    @Test("A speed is labelled with as few decimals as it needs")
    func labels() {
        #expect(PlaybackSpeed.label(1) == "1.0×")
        #expect(PlaybackSpeed.label(1.5) == "1.5×")
        #expect(PlaybackSpeed.label(1.25) == "1.25×")
        #expect(PlaybackSpeed.label(1.05) == "1.05×")
        #expect(PlaybackSpeed.label(3) == "3.0×")
    }
}
