# Time-pitch algorithms for sped-up speech

Research for [#44](https://github.com/kracobsen/logos/issues/44). Vocabulary follows `GLOSSARY.md` (Book, Server).

The symptom: `SystemAudioPlayer` sets `audioTimePitchAlgorithm = .spectral` on the `AVPlayerItem` of an `AVMutableComposition`. Above 1× the speech sounds tinny and choppy, worse at higher speeds, on device and in the Simulator. The bar is "at least as natural as BookPlayer and Apple Books".

## Sources

Every claim below is tagged with its source. **Verified** means read in a header, doc, or source file, or measured in the experiment described in [§6](#6-experiment-what-the-algorithms-are-underneath). **Inference** means my reading of the evidence, not something a source states.

| Source | Where | Notes |
|---|---|---|
| iOS 27.0 SDK headers | `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk` | Referred to as `SDK/<Framework>/<Header>` below |
| Apple Developer Forums | threads [4797](https://developer.apple.com/forums/thread/4797) and [5874](https://developer.apple.com/forums/thread/5874) (June 2015) | Answers by `theanalogkid`, Apple's Core Audio DTS engineer of that era. The archived page no longer shows a staff badge, so treat these as strong but not official. |
| Apple docs | [mediaServicesWereResetNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification), [Books for Mac user guide](https://support.apple.com/en-by/guide/books/ibks9a460640/mac) | |
| BookPlayer | [TortugaPower/BookPlayer@eb19a92](https://github.com/TortugaPower/BookPlayer/tree/eb19a92f368ba3d8144777999ca3baa5cb44280d) | |
| audiobookshelf app | [advplyr/audiobookshelf-app@7014e04](https://github.com/advplyr/audiobookshelf-app/tree/7014e04e6febcc5fd326e816a57b1065817e85f5) | iOS code is under `ios/App/`. Same commit as [existing-clients.md](https://github.com/kracobsen/logos/blob/research/existing-clients/docs/research/existing-clients.md). |
| Pocket Casts | [Automattic/pocket-casts-ios@79fc8e7](https://github.com/Automattic/pocket-casts-ios/tree/79fc8e7d1a6cfcd684a812b991a56032fa99882b) | Not on the issue's list. Added because it is the one open-source speech player that uses AVAudioEngine. |
| Sonic | [waywardgeek/sonic@b93885d](https://github.com/waywardgeek/sonic/tree/b93885dcb70aae50c6f76b0fe4e0868f029a077e) (2026-03-14) | |
| Media3 (ExoPlayer) | [androidx/media@8c6678b](https://github.com/androidx/media/tree/8c6678b657ede1e7883fc164ef73ed483c7796c3) | Google's Sonic port |
| SoundTouch | [soundtouch/soundtouch@f738b11](https://codeberg.org/soundtouch/soundtouch/src/commit/f738b1132ec1fd56efc90367898244cf52d9e6a5) (2026-04-19) | v2.4.0 |
| Apple Books for Mac | `/System/Applications/Books.app` 9.0, macOS 27.0.1 (26A434) | Closed source; only the binaries' imported symbols were read |

Link prefixes used below:
- `BP` = `https://github.com/TortugaPower/BookPlayer/blob/eb19a92f368ba3d8144777999ca3baa5cb44280d/`
- `APP` = `https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/`
- `PC` = `https://github.com/Automattic/pocket-casts-ios/blob/79fc8e7d1a6cfcd684a812b991a56032fa99882b/`
- `SON` = `https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/`

## TL;DR: lessons for Logos

1. **`.spectral` is the wrong algorithm for speech, and Logos is the only player studied that picks it.**
   - Apple's own header calls `.spectral` "Suitable for music" and `.timeDomain` "Suitable for voice" (`SDK/AVFoundation/AVAudioProcessingSettings.h`).
   - BookPlayer and Pocket Casts set `.timeDomain`. The audiobookshelf app sets nothing, and on iOS 15+ SDKs the default is `.timeDomain`.
   - Apple Books for Mac imports `AVAudioTimePitchAlgorithmTimeDomain` and no other algorithm constant.
   - The spectral unit is a phase vocoder. Its own parameter docs warn of a "phasey" or "reverberant" sound (`SDK/AudioToolbox/AudioUnitParameters.h` L355-358). That fits the "tinny" report (inference).
2. **`.timeDomain` is exactly Apple's `AUiPodTimeOther` (`'ipto'`) audio unit, and that unit advertises a rate range of only 0.5–2.0.**
   - Measured: AVFoundation's `.timeDomain` output is bit-identical to `'ipto'` rendered directly (§6).
   - The AVFoundation header still promises "1/32 to 32".
   - Above 2× it keeps running, but it tracks the speech's loudness envelope much less faithfully: correlation 0.98 at 1.5×, 0.90 at 2×, 0.67 at 3×.
   - So expect a quality cliff above 2× (inference). Apple Books caps speed at 2×.
3. **Moving to AVAudioEngine with Apple's units buys no new algorithm.**
   - `AVAudioUnitTimePitch` is `AUNewTimePitch` (`'nutp'`), the spectral family. This is verified by probe and by the forum thread.
   - `.timeDomain`'s unit (`'ipto'`) can already be used from AVPlayer.
   - The only extra control is `'nutp'`'s smoothness and transient switches.
4. **Sonic (Apache-2.0) is the permissive speech stretcher to use if `.timeDomain` falls short above 2×.**
   - It is built for speech above 2×: PICOLA below 2×, and partial pitch-period skipping at 2× and above.
   - Google ships it as Media3/ExoPlayer's speed processor.
   - SoundTouch is WSOLA tuned for music, and it is LGPL-2.1, so it is out.
5. **If Logos ever needs a custom stretcher, wire it as an AVAudioEngine source, not an `MTAudioProcessingTap`.**
   - Measured: a PreEffects tap sees source frames at the player rate. A PostEffects tap sees audio already stretched by AVPlayer.
   - Either way the tap must return exactly the frames requested. It can't take over the time-stretching while AVPlayer's clock runs at the target rate.

---

## 1. What AVFoundation's algorithms are

### What the headers say (verified)

`SDK/AVFoundation/AVAudioProcessingSettings.h`:

| Constant | Header description | Rate range in header | Availability |
|---|---|---|---|
| `.lowQualityZeroLatency` | "Low quality, very inexpensive. Suitable for brief fast-forward/rewind effects, low quality voice." | "snapped to {0.5, 0.666667, 0.8, 1.0, 1.25, 1.5, 2.0}" | **Deprecated** iOS 7–15: "Use AVAudioTimePitchAlgorithmTimeDomain instead" |
| `.timeDomain` | "Modest quality, less expensive. Suitable for voice." | "1/32 to 32" | iOS 7+ |
| `.spectral` | "Highest quality, most computationally expensive. Suitable for music." | "1/32 to 32" | iOS 7+ |
| `.varispeed` | "High quality, no pitch correction. Pitch varies with rate." | "1/32 to 32" | iOS 7+ |

- **No new algorithm on iOS 27.** The header is still "Copyright 2013-2021", and nothing in AVFAudio or AVFoundation tagged `ios(26…)` or `ios(27…)` touches time-pitch. A grep of the iOS 27 SDK found none.
- **Default for `AVPlayerItem.audioTimePitchAlgorithm`:** "for applications linked on or after iOS 15.0 … is AVAudioTimePitchAlgorithmTimeDomain. For iOS versions prior to 15.0 the default value is AVAudioTimePitchAlgorithmLowQualityZeroLatency" (`SDK/AVFoundation/AVPlayerItem.h` L466-467; same text for `AVSampleBufferAudioRenderer`).
  - Export, `AVAssetReaderAudioMixOutput` and other offline processing default to `.spectral` (`AVAudioProcessingSettings.h`; `AVAssetReaderOutput.h` L330).
- **The header's own advice for scaled edits:** "`AVAudioTimePitchAlgorithmSpectral` is often the best choice due to the highly inclusive range of rates it supports" (`AVAudioProcessingSettings.h`). This is advice about range of rates, not about speech.
- **`AVPlayer` warns that rates can be quantized.** "The effective rate of playback may differ from the desired rate … if the processing algorithm in use for managing audio pitch requires quantization of playback rate … You can always obtain the effective rate of playback from the currentItem's timebase" (`SDK/AVFoundation/AVPlayer.h` L154). Only the deprecated `.lowQualityZeroLatency` documents snapping.
- **The AudioQueue layer has the same family:** `kAudioQueueTimePitchAlgorithm_Spectral` (`'spec'`), `_TimeDomain` (`'tido'`, "Modest quality, less expensive. Suitable for voice."), and `_Varispeed`. `_LowQualityZeroLatency` was deprecated iOS 2–13 (`SDK/AudioToolbox/AudioQueue.h` L292-318). Per Apple DTS, `AVAudioPlayer` hard-wires `TimeDomain` ([forum 4797](https://developer.apple.com/forums/thread/4797)).

### The audio units underneath

- **`.spectral` is `AUNewTimePitch` (`'nutp'`).** Per Apple DTS: "When you create a AVAudioUnitTimePitch AU, what you get back is the kAudioUnitSubType_NewTimePitch audio unit, this is the same AU that is used when someone selects the kAudioQueueTimePitchAlgorithm_Spectral … and … equates to AVAudioTimePitchAlgorithmSpectral for AVPlayer" ([forum 5874](https://developer.apple.com/forums/thread/5874)).
  - My offline render through `AVAssetReaderAudioMixOutput` with `.spectral` did not match `'nutp'` with default parameters bit for bit (§6). That path may use other parameters, so treat the forum's statement as the best available evidence rather than verified.
- **`'nutp'` is a phase vocoder (verified from its parameters).** `SDK/AudioToolbox/AudioUnitParameters.h` L337-368:
  - `Smoothness`: "density of the processing time frames", 3–32, default 8.
  - `EnableSpectralCoherence`: "Spectral phase coherence is enabled through peak locking. This adds some computation cost but results in a less 'phasey' or reverberant sound", default on.
  - `EnableTransientPreservation`: "uses group delay to identify transients. It resets the phase at points of transients."
  - Peak locking, phase reset and group delay are phase-vocoder vocabulary.
  - `AVAudioUnitTimePitch.overlap` has the same 3–32 range and default of 8 (`SDK/AVFAudio/AVAudioUnitTimePitch.h`). A probe confirms `AVAudioUnitTimePitch()` is `aufc`/`nutp` (§6).
- **`.timeDomain` is `AUiPodTimeOther` (`'ipto'`) (verified, §6).**
  - AVFoundation's `.timeDomain` render and a direct `'ipto'` render correlate at 1.0000 with zero lag at 1.5×, 2× and 3×.
  - `AUComponent.h` L401-402 describes the unit as "An audio unit that provides time domain time stretching". Its registered component name is `AUNotQuiteSoSimpleTime`.
  - It exposes one parameter, rate, with range **[0.5, 2.0]** (probe, §6).
- **Is `.timeDomain` WSOLA? Not documented.**
  - Apple says only "time domain time stretching". No header, doc or WWDC session I found names the method, and the shared cache has no telling symbol names.
  - Inference: a time-domain stretcher with a 2.0 ceiling is consistent with the SOLA/WSOLA or PICOLA family. Those methods remove at most one segment per segment kept, which caps them near 2× unless they special-case higher rates the way Sonic does (§4). That is circumstantial.
- **`.varispeed` is resampling,** like `AVAudioUnitVarispeed` (`'vari'`): "changing the rate to 2.0 results in the output audio playing one octave higher" (`SDK/AVFAudio/AVAudioUnitVarispeed.h`). It is not usable for speech above 1×.
- **The deprecated `AUiPodTime` (`'iptm'`)** is "simple (and limited) control over playback rate", deprecated iOS 2–13 in favour of `NewTimePitch` (`AUComponent.h` L436-441). It is presumably what backed `.lowQualityZeroLatency` (inference).

### Rate ceilings and quality cliffs

- **`.spectral` (`'nutp'`):** rate 1/32–32 (`AudioUnitParameters.h` L340). There is no documented cliff. Its artifacts are phase-vocoder ones: "phasey", reverberant, smeared transients.
- **`.timeDomain` (`'ipto'`):**
  - Verified: the unit's own parameter range is 0.5–2.0, while AVFoundation's header says 1/32–32.
  - Measured: at 3× it still delivers 3× (the output tracks the 3×-compressed source envelope), but fidelity drops sharply above 2× (§6).
  - Inference: a quality cliff above 2× is likely. This is a crude objective proxy, so confirm it by ear on an iPhone at 2.5× and 3×.
- **`AVPlayerItem.canPlayFastForward`:** since iOS 7 every ready item can play at 1.0–2.0, and the property "indicates whether the item can be played at rates greater than 2.0" (`AVPlayerItem.h` L237-238). Measured: `true` for an audio-only `AVMutableComposition` of a local file (§6).

## 2. AVPlayer + `AVMutableComposition` quirks

- **The item-level algorithm applies to a composition item (measured, macOS 27, §6).**
  - Setting `.spectral`, `.timeDomain` or `.varispeed` on an `AVPlayerItem(asset: AVMutableComposition)` reads back unchanged.
  - The timebase runs at exactly 2.3 and 3.0 when asked. No quantization was seen for any of the three.
  - The offline equivalent (`AVAssetReaderAudioMixOutput` over a composition) demonstrably uses the chosen algorithm, because the `.timeDomain` render matches `'ipto'` bit for bit.
- **Per-track override.** `AVMutableAudioMixInputParameters.audioTimePitchAlgorithm` "Can be nil, in which case the audioTimePitchAlgorithm set on the AVPlayerItem … will be used for the associated track" (`SDK/AVFoundation/AVAudioMix.h` L144-148). If Logos ever adds an `audioMix`, leave that nil or set it to the same value.
- **Scaled edits.** The header's note about choosing an algorithm that "supports the full range of edit rates" applies only to `scaleTimeRange` edits, which Logos doesn't use. A forum thread reports silent audio after `scaleTimeRange` until `audioTimePitchAlgorithm` was set ([forum 83024](https://developer.apple.com/forums/thread/83024), community report, not verified).
- **New in iOS 27:** `AVAudioMixInputParametersTrackMixID = 0` lets one input-parameters object (volume ramps or a tap) apply "to the mix of all audio tracks rather than to a single specific audio track" (`AVAudioMix.h` L62-66, L136-142).
- **Not reproduced:** I found no primary source, and saw no evidence in the probe, for the algorithm "not applying to a composition item".

## 3. What other players use

| Player | Engine | Algorithm | Max speed | Source |
|---|---|---|---|---|
| **Apple Books (Mac 9.0)** | AVFoundation (closed source) | Imports `AVAudioTimePitchAlgorithmTimeDomain` and `setAudioTimePitchAlgorithm:`, in `BookCore.framework` and `BKAudiobooks.framework`. It references no Spectral or Varispeed constant. | 2× ("The fastest speed is 2x, and the slowest speed is 0.75x") | Symbols in `/System/Applications/Books.app` (verified on macOS 27.0.1); [Books for Mac guide](https://support.apple.com/en-by/guide/books/ibks9a460640/mac) |
| **BookPlayer** | One `AVPlayer`, one `AVPlayerItem` per file | `.timeDomain`, set on every new item | 4.0× (slider 0.5–4.0, presets to 4.0) | [BP `BookPlayer/Player/PlayerManager.swift`](https://github.com/TortugaPower/BookPlayer/blob/eb19a92f368ba3d8144777999ca3baa5cb44280d/BookPlayer/Player/PlayerManager.swift) L274-275 (rate set at L1194-1200); the watch player does the same at [BP `BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift`](https://github.com/TortugaPower/BookPlayer/blob/eb19a92f368ba3d8144777999ca3baa5cb44280d/BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift) L257; range in [BP `.../PlayerControlsSpeedSectionView.swift`](https://github.com/TortugaPower/BookPlayer/blob/eb19a92f368ba3d8144777999ca3baa5cb44280d/BookPlayer/Player/Views/Controls/PlayerControlsSpeedSectionView.swift) L20-21 and [BP `.../GlobalSpeedSectionView.swift`](https://github.com/TortugaPower/BookPlayer/blob/eb19a92f368ba3d8144777999ca3baa5cb44280d/BookPlayer/Settings/Sections/PlayerControls/GlobalSpeedSectionView.swift) L21 |
| **audiobookshelf (iOS)** | `AVQueuePlayer`, one item per file | **Not set**, so the iOS 15+ default `.timeDomain` applies. The shipped binary is built with a modern SDK (inference). | 10× in the UI (`MIN_SPEED: 0.5`, `MAX_SPEED: 10`) | [APP `ios/App/Shared/player/AudioPlayer.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/AudioPlayer.swift) L62, L108 (a grep of `ios/` for `pitch` finds nothing); [APP `components/modals/PlaybackSpeedModal.vue`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/components/modals/PlaybackSpeedModal.vue) L45-46 |
| **audiobookshelf (Android)** | ExoPlayer | Sonic, through ExoPlayer's speed processor (inference: ExoPlayer's documented default) | 10× | [APP `android/app/build.gradle`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/android/app/build.gradle) L103-107 |
| **Pocket Casts (AVPlayer path)** | `AVPlayer` | `.timeDomain`, "Set the pitch algorithm once here rather than re-applying it on every rate change" | | [PC `podcasts/DefaultPlayer.swift`](https://github.com/Automattic/pocket-casts-ios/blob/79fc8e7d1a6cfcd684a812b991a56032fa99882b/podcasts/DefaultPlayer.swift) L112-114 |
| **Pocket Casts (effects path)** | `AVAudioEngine`: player node → mixer → time-pitch → high-pass → dynamics → limiter → output | `AVAudioUnitTimePitch(audioComponentDescription:)` with **`kAudioUnitSubType_AUiPodTimeOther`**, which is the same unit as `.timeDomain` | | [PC `podcasts/EffectsPlayer.swift`](https://github.com/Automattic/pocket-casts-ios/blob/79fc8e7d1a6cfcd684a812b991a56032fa99882b/podcasts/EffectsPlayer.swift) L150-155, L428-435. Used for downloaded episodes with trim-silence on, and never for HLS, video or AirPlay ([PC `podcasts/PlaybackManager.swift`](https://github.com/Automattic/pocket-casts-ios/blob/79fc8e7d1a6cfcd684a812b991a56032fa99882b/podcasts/PlaybackManager.swift) L1559-1565). |

- **Every speech player studied lands on the time-domain unit.** None uses `.spectral`, and none ships a third-party stretcher on iOS.
- **Pocket Casts already followed DTS's advice** to wrap `'ipto'` in AVAudioEngine ([forum 5874](https://developer.apple.com/forums/thread/5874), where the asker `rustyshelf` is a Pocket Casts developer). This shows that AVAudioEngine does not give a better Apple algorithm, only extra effects.

## 4. Sonic vs SoundTouch for speech at 2–3×

| | Sonic | SoundTouch |
|---|---|---|
| Licence | **Apache-2.0** ([SON `README`](https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/README) L17; [SON `LICENSE`](https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/LICENSE)) | **LGPL-2.1**, "commercial license alternative also available" ([README.html](https://codeberg.org/soundtouch/soundtouch/src/commit/f738b1132ec1fd56efc90367898244cf52d9e6a5/README.html) §7). Not permissive, so out of scope. |
| Algorithm | Pitch-synchronous overlap-add (TD-PSOLA family). Pitch period by AMDF on 4 kHz downsampled audio, pitch 65–400 Hz ([SON `sonic.c`](https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/sonic.c) L808-850; [SON `sonic.h`](https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/sonic.h) L112-135). Below 2× it runs **PICOLA**: drop one pitch period, then copy input unmodified (sonic.c L1097-1105). At 2× and above, "we skip over a portion of each pitch period rather than dropping whole pitch periods" (sonic.c L1019-1040). | "WSOLA-like time-stretching routines that operate in the time domain", with sequence, seek-window and overlap parameters (README.html §3.3-3.4) |
| Tuned for | Speech: "optimized for speed ups of over 2X" (README L1-3); "up to 6X" ([SON `doc/index.md`](https://github.com/waywardgeek/sonic/blob/b93885dcb70aae50c6f76b0fe4e0868f029a077e/doc/index.md) L63) | Music: defaults "chosen … to obtain best subjective sound quality in pop/rock music processing". (README.html §3.4). A `-speech` switch exists in the SoundStretch CLI (README.html §5.2) |
| Quality claims | Author: "Sonic is better for speech, while WSOLA is better for music … WSOLA introduces unacceptable levels of distortion, making speech impossible to understand at high speed (over 2.5X) by blind speed listeners" (doc/index.md L48-56). This is the author's claim, with A/B samples in `doc/`. | Makes no speech claim |
| Latency | "two pitch periods, which is typically closer to 20 milliseconds" (doc/index.md L106-107) | Tens of milliseconds (sequence plus seek window) |
| Range | Speed 0.05–20 (sonic.h L123-124) | |
| Adoption | Media3/ExoPlayer's `Sonic.java`: "Based on https://github.com/waywardgeek/sonic" ([androidx/media `Sonic.java`](https://github.com/androidx/media/blob/8c6678b657ede1e7883fc164ef73ed483c7796c3/libraries/common/src/main/java/androidx/media3/common/audio/Sonic.java) L1-33). Also eSpeak and Debian `libsonic` (doc/index.md L25-31). | Wide (many DAWs and players) |
| Integration | Plain C, streaming API: `sonicCreateStream`, `sonicSetSpeed`, `sonicWriteFloatToStream`, `sonicReadFloatFromStream`, `sonicFlushStream` (sonic.c L282, L419, L603, L689, L1182). Internal buffers are 16-bit `short` (sonic.c L1020, L1043), so float input is quantized (inference from the signatures). | C++ |

**Measured (§6, synthetic `say` voice, envelope-tracking proxy):**

| Rate | Sonic | `.timeDomain` | `.spectral` |
|---|---|---|---|
| 1.5× | 0.996 | 0.979 | 0.993 |
| 2× | 0.996 | 0.903 | 0.979 |
| 3× | 0.944 | 0.668 | 0.949 |

- Sonic holds the source's syllable envelope at 2× and 3×, where `.timeDomain` falls off.
- `.spectral` also tracks the envelope. Its problem is timbre (phasiness), which this proxy can't see.
- This proxy is not a listening test.

## 5. Wiring a third-party stretcher into an iOS player

### Option A: `MTAudioProcessingTap` on the `AVPlayerItem` (not viable for stretching)

- **The contract is frames in, same frames out (verified).** "The tap must provide the same number of samples that are being requested … If less data is returned than requested, the remainder will be filled with silence" (`SDK/MediaToolbox/MTAudioProcessingTap.h` L185-191). A tap is placed either "before any effects" (PreEffects) or "after any effects" (PostEffects) (L36-39).
- **Measured on macOS 27 with `.timeDomain` at 2×:**
  - A PreEffects tap received about 89,000 frames per wall-clock second (2 × 44.1 kHz). It sits before AVPlayer's time-pitch and sees the raw source at the player rate.
  - A PostEffects tap received about 45,000 per second, so it sees already-stretched output.
  - At 1× both received about 44,000 per second.
- **Consequence (inference):** to stretch in a tap, the player would have to run at 1× while the tap consumes N× source.
  - The tap can't pull more source than the player schedules, and it must return exactly what is asked.
  - The item's clock (`currentTime`, boundary and periodic observers, Now Playing elapsed time) would then run at 1× while the audio plays at N×.
  - That breaks the `AudioPlayer` contract that player time is Book time.

### Option B: AVAudioEngine with a source node or player node feeding the stretcher (the viable route)

- **Shape (inference):**
  - Decode with `AVAudioFile` or `AVAssetReader` into a ring buffer.
  - Push the audio through Sonic, then into an `AVAudioSourceNode` render block, then the main mixer.
  - Alternatively, do the Sonic step offline into buffers scheduled on an `AVAudioPlayerNode`.
  - This is Pocket Casts' shape ([PC `EffectsPlayer.swift`](https://github.com/Automattic/pocket-casts-ios/blob/79fc8e7d1a6cfcd684a812b991a56032fa99882b/podcasts/EffectsPlayer.swift) L86-155), with Sonic in place of `'ipto'`.
- **It fits Logos's seam.** `AudioPlayer` already abstracts `load` (files back to back), `rate`, `currentTime`, `seek`, `observeTime`, `observeBoundaries` and `rebuild()` (`LogosKit/Sources/Playback/AudioPlayer.swift`). An engine-backed implementation could replace `SystemAudioPlayer` without touching `Player` (inference).
- **What you lose and have to rebuild:**
  - **Compositions:** there is no `AVMutableComposition` in AVAudioEngine. "Files back to back" becomes your own file list with frame offsets: schedule the next file, or decode across file boundaries.
  - **Time:** Book time = frames consumed from the source ÷ sample rate + file offset, not frames played out. Pocket Casts derives `currentTime` from frame counts (EffectsPlayer.swift L255, L271).
  - **Boundary observers:** there is no `addBoundaryTimeObserver`. `observeBoundaries` has to be driven from the consumed-frame clock: check on a periodic tick, or have the decode loop signal when it crosses a boundary. Precision is then bounded by the stretcher's latency (about 20 ms for Sonic) plus the I/O buffer (inference).
  - **Media-services reset:** Apple says to respond by "reinitializing your app's audio objects (such as players, recorders, converters, or audio queues) and resetting your audio session's category, options, and mode configuration", and not to restart playback until the user acts ([docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification)). `rebuild()` already has that meaning. For the engine it means a new `AVAudioEngine`, new nodes and a new Sonic stream.
  - **Configuration changes:** on a hardware sample-rate or channel change "the engine stops itself … and issues this notification". An output-only chain survives because "the output node supports rate conversion". The engine must not be deallocated inside the handler (`SDK/AVFAudio/AVAudioEngine.h` L1036-1061). AVPlayer handles this for you today.
  - **Real-time rules:** the source-node render block runs on the audio I/O thread. No allocation, locks, or Swift concurrency hops. Sonic's stream must be pre-sized and fed from a lock-free ring buffer (inference from Core Audio's general real-time rules, stated for taps at `MTAudioProcessingTap.h` L193-195).
  - **Now Playing and remote commands:** the elapsed time and rate must be published by hand. Logos already does this through `NowPlayingCenter`.
  - **Dependency policy:** Sonic is a C dependency, which needs an ADR (`CLAUDE.md`, Dependencies). Vendoring two C files as a SwiftPM C target inside Playback keeps "Apple frameworks only" at link level, but it is still a dependency for policy purposes.
- **Cost (inference):** this is a new player implementation, not a setting. Every device-only checklist item (interruptions, routes, lock screen, background, reboot) has to be re-verified.

## 6. Experiment: what the algorithms are underneath

**Setup.** Run on the macOS 27.0.1 host with Xcode's iOS 27 SDK toolchain. AVFoundation, AudioToolbox and the units are shared with iOS, but this was **not run on an iPhone** (inference that results carry over).

- **Source:** a 20.6 s English passage from `say`, encoded as AAC 64 kbit/s, 44.1 kHz mono.
- **Unit probe:**
  - `AVAudioUnitTimePitch().audioComponentDescription` is `aufc`/`nutp`, and `AVAudioUnitVarispeed` is `aufc`/`vari`.
  - `AVAudioUnitComponentManager` lists `AUNewTimePitch nutp`, `AUNotQuiteSoSimpleTime ipto`, `AUTimePitch tmpt` and `AUVarispeed vari`.
  - `'ipto'`'s only parameter is `0` (rate) with range [0.5, 2.0].
  - `'nutp'` has rate [1/32, 32], pitch, smoothness [3, 32] = 8, spectral coherence = 1, transient preservation = 1.
- **Offline renders at 1.5×, 2× and 3×:**
  1. `AVAssetReaderAudioMixOutput` over an `AVMutableComposition` whose track is `scaleTimeRange`d to 1/rate, with each `audioTimePitchAlgorithm`.
  2. `AVAudioEngine` offline manual rendering of `AVAudioPlayerNode` → `AVAudioUnitTimePitch(audioComponentDescription:)` for `'nutp'`, `'ipto'` and `'tmpt'` at the same rate.
  3. The Sonic CLI built from the pinned commit (`sonic -s <rate>`).
- **Bit-identity:**
  - Peak normalized cross-correlation over ±8192 samples on a 4 s mid-window: **`.timeDomain` vs `'ipto'` = 1.0000 at lag 0 at every rate**.
  - Two `.timeDomain` runs also give 1.0000, so the output is deterministic.
  - Every other pairing scored 0.10–0.23, including `.spectral` vs `'nutp'` at defaults.
- **Envelope proxy:** correlation of each render's 20 ms RMS envelope with the source envelope sampled every 20 × rate ms. A render that truly plays at N× and keeps the syllables tracks it. The numbers are in §4. `.timeDomain` at 3× scores 0.67, against 0.017 when a 2× render is compared with the 3× envelope, so it really does run at 3×.
- **Real-time probe (muted `AVPlayer`, composition item):**
  - The algorithm read back equals the one set.
  - `canPlayFastForward` is `true`.
  - `CMTimebaseGetRate` equals the requested 2.3 and 3.0 for all three algorithms.
  - Tap frame rates are as in §5.
- **Limits:**
  - One synthetic voice, not a narrated Book.
  - The envelope proxy measures syllable timing, not timbre.
  - The offline AVFoundation path is not guaranteed to equal the real-time one; only the real-time read-back and timebase were checked live.

## Open questions

- **Does `.timeDomain` sound right at 1.25–2× on an iPhone with real narration?** That is the cheapest fix, and the one every reference player uses. It needs a listening A/B against BookPlayer on the same Book.
- **How bad is `.timeDomain` at 2.5× and 3× by ear?** `'ipto'` advertises a 2.0 ceiling, and the envelope proxy drops. If it is bad, does Logos cap the speed (Apple Books caps at 2×), or take on Sonic?
- **Would `'nutp'` with `Smoothness` raised (for example 16–32) and transient preservation on make `.spectral` acceptable?** Those parameters are only reachable through AVAudioEngine, not through AVPlayer.
- **Does the offline `.spectral` path really differ from `'nutp'` at defaults, or did my harness's latency handling cause the mismatch?** This matters only if `'nutp'` tuning is pursued.
