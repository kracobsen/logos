# What Absorb and Overcast use to speed up speech

Research for [#50](https://github.com/kracobsen/logos/issues/50). It follows on from [time-pitch.md](https://github.com/kracobsen/logos/blob/research/time-pitch/docs/research/time-pitch.md) (#44), whose findings are not repeated here: `.timeDomain` is `AUiPodTimeOther` (`'ipto'`), `.spectral` and `AVAudioUnitTimePitch` are `AUNewTimePitch` (`'nutp'`), and Sonic is the permissive fast-speech stretcher. Vocabulary follows `GLOSSARY.md` (Book, Server).

## Sources

Every claim below is tagged with its source. **Verified** means read in source code at the pinned commit, or stated in the developer's own words. **Inference** means my reading of the evidence, not something a source states.

| Source | Where | Notes |
|---|---|---|
| Absorb | [pounat/absorb@8633477](https://github.com/pounat/absorb/tree/86334772b2bde1b39910e47bcde93c8836191a42) (2026-10-09, `pubspec.yaml` version 1.11.1+291) | GPL-3.0 ([`LICENSE`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/LICENSE)). Read only, for facts; no code may be copied into Logos. |
| Absorb issues | [#389](https://github.com/pounat/absorb/issues/389) | Developer's (`pounat`) own replies |
| Absorb on the App Store | [id6760673498](https://apps.apple.com/us/app/absorb-for-audiobookshelf/id6760673498), "Absorb - for Audiobookshelf" by Nathan Poulson, v1.10.0 (2026-09-08) | iTunes lookup API |
| audiobookshelf docs | [Community apps](https://audiobookshelf.org/docs/documentation/community/community-apps) | Lists Absorb |
| Marco Arment (Overcast's developer) | [2013-10-18 "Podcast App Playback Speeds"](https://marco.org/2013/10/18/podcast-app-playback-speeds), [2014-07-16 "Overcast"](https://marco.org/2014/07/16/overcast), [2015-01-23 "Smart Speed vs. Real Time"](https://marco.org/2015/01/23/smart-speed-test), [2015-10-09 "Overcast 2"](https://marco.org/2015/10/09/overcast2), [2020-01-31 "Voice Boost 2"](https://marco.org/2020/01/31/voiceboost2), [2024-07-16 "A new foundation"](https://marco.org/2024/07/16/overcast-rewrite) | Primary |
| Marco Arment interview | Matthew Panzarino, ["Why Marco Arment Built A Podcast App"](https://techcrunch.com/2014/07/20/why-marco-arment-built-a-podcast-app/), TechCrunch, 2014-07-20 | Q&A transcript, so his own words |
| Marco Arment on Twitter | [Thread of 2020-12-18](https://twitter.com/marcoarment/status/1339965184421621760), read through the mirror [convopage.com](https://convopage.com/c/1339965184421621760) | The mirror is third-party. The date comes from the tweet ID. |
| Overcast on the App Store | [id888422857](https://apps.apple.com/us/app/overcast-podcast-app/id888422857), v2026.10 (2026-10-09) | Description and release notes |
| BuzzFeed News | ["Meet the People Who Listen to Podcasts at Super-Fast Speeds"](https://www.buzzfeednews.com/article/doree/meet-the-people-who-listen-to-podcasts-at-super-fast-speeds), 2017-11-12 | Secondary; reports a figure from Arment |

Link prefix used below: `AB` = `https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/`

## TL;DR: lessons for Logos

1. **Absorb on iOS is one more `.timeDomain` player.**
   - Its native engine is a single `AVPlayer` with `audioTimePitchAlgorithm = .timeDomain` on every item. Its EQ is a PostEffects `MTAudioProcessingTap`, which sees already-stretched audio.
   - On Android it uses Media3's `SonicAudioProcessor`, with the platform's own `AudioTrack` speed explicitly turned off. That is Sonic, but not on iOS.
   - It lets the listener pick up to 5× on both platforms. Up to 5× on iOS means `'ipto'` well past its advertised 2.0 ceiling. No quality complaint about high speed was found in its issue tracker.
2. **Overcast's stretcher is not public, and the developer's own words point to an Apple unit, not a custom one.**
   - Verified (2014, Arment): he tried "third-party commercial libraries" and "ended up using some of the Apple's newer APIs", choosing an algorithm setting that is "a trade-off between CPU time and quality". On iOS 7, the newer choices were `.timeDomain` and `.spectral`. Which one he chose is not stated.
   - Verified (2014 and 2020): the custom parts are the Core Audio engine around it, Smart Speed (shortening silences) and Voice Boost 2 (written "from scratch, without using AudioUnits", in "pure C").
   - Verified (2020): Arment recommended `AVAudioTimePitchAlgorithmTimeDomain` for sped-up speech and argued that spectral artifacts in speech are worse than "*SOLA" artifacts in music.
   - Inference: Overcast most likely uses Apple's time-domain unit, wrapped in its own engine. This is not verified, and the binary could not be inspected.
3. **Overcast's quality edge is Smart Speed, not the stretcher.** Arment frames Smart Speed as "another speed increment for free" without stretching the speech harder. Reportedly only about 1% of Overcast listeners use 2× or more (2017).
4. **Nothing here changes the route.** Neither app ships something better than `.timeDomain` on iOS. Sonic shows up only on Android (Absorb), as in the audiobookshelf app. If Logos wants an Overcast-style edge above 1×, silence shortening is a separate, additive feature.

---

## 1. Absorb

### Which app it is (verified)

- "Absorb" is **Absorb, a third-party audiobookshelf client for Android and iOS** by Nathan Poulson (GitHub `pounat`).
- The audiobookshelf docs' [Community apps](https://audiobookshelf.org/docs/documentation/community/community-apps) page lists "Absorb" for Android, iOS and iPadOS, linking to `github.com/pounat/absorb`, which describes itself as "A modern audiobookshelf client with a card-based player experience" ([AB `README.md`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/README.md)).
- The App Store has "Absorb - for Audiobookshelf" by Nathan Poulson ([id6760673498](https://apps.apple.com/us/app/absorb-for-audiobookshelf/id6760673498)).
- `gh search repos absorb audiobookshelf` finds only `pounat/absorb` and forks of it.
- It is a Flutter app, open source under **GPL-3.0**. The pinned commit is version 1.11.1, ahead of the App Store's 1.10.0.

### Time-stretch algorithm and wiring

| Platform | Player | Time-stretch | Source |
|---|---|---|---|
| **iOS (books, current)** | A native Swift `AbsorbAudioEngine`: "Single AVPlayer that owns audio playback for the entire app lifetime", with one `AVPlayerItem` per file and `replaceCurrentItem` between them, driven over a Flutter method channel | `item.audioTimePitchAlgorithm = .timeDomain` on every item | [AB `ios/Runner/Audio/AbsorbAudioEngine.swift`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/ios/Runner/Audio/AbsorbAudioEngine.swift) L5-23, L517-526; Dart side [AB `lib/services/native_ios_audio_player.dart`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/lib/services/native_ios_audio_player.dart) L7-13. Added in commit [2926bdd](https://github.com/pounat/absorb/commit/2926bdd699571d26b41a03eda840a0264e5cde15) (2026-05-28, "Native iOS audio engine"). |
| iOS (queue hand-over) | `AVQueuePlayer` items prepared natively | `.timeDomain` | [AB `ios/Runner/IOSQueueAdvancer.swift`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/ios/Runner/IOSQueueAdvancer.swift) L167-168 |
| iOS (vendored `just_audio`) | `AVQueuePlayer` | `.timeDomain`, commented "This does the best at reducing distortion on voice with speeds below 1.0". `setSpeed` passes any rate straight to `player.rate`, because `canPlayFastForward` is "unreliable". | [AB `packages/just_audio/darwin/.../UriAudioSource.m`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/packages/just_audio/darwin/just_audio/Sources/just_audio/UriAudioSource.m) L76-79; [AB `.../AudioPlayer.m`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/packages/just_audio/darwin/just_audio/Sources/just_audio/AudioPlayer.m) L1140-1172 |
| iOS EQ | `MTAudioProcessingTap` on the item's `audioMix`, created with `kMTAudioProcessingTapCreationFlag_PostEffects` | None. The EQ runs after AVPlayer's stretch. | [AB `ios/Runner/Audio/AudioEQProcessor.m`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/ios/Runner/Audio/AudioEQProcessor.m) L339-356 |
| **Android (not iOS)** | ExoPlayer (Media3), through a vendored `just_audio` whose `buildAudioSink` is patched | Media3 `SonicAudioProcessor` first in the chain, then mono and gain processors, with `setEnableAudioTrackPlaybackParams(false)` ("AudioTrack speed DISABLED"). So the speed change is always done by Sonic, never by the platform's `AudioTrack`. | [AB `packages/just_audio/android/.../AudioPlayer.java`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/packages/just_audio/android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java) L879, L955-967; speed set via `PlaybackParameters` at L1202 |

- No AVAudioEngine, `AVAudioUnitTimePitch`, Sonic or SoundTouch code exists under `ios/` (grep at the pinned commit).
- The PostEffects EQ tap matches what #44 measured: the tap only post-processes and can't do the stretching.

### Speed range (verified)

- **0.5× to 5×** in the player's speed sheet: `_speed = s.clamp(0.5, 5.0)` ([AB `lib/widgets/card_buttons.dart`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/lib/widgets/card_buttons.dart) L745).
- The limit was raised from 3× in [#389](https://github.com/pounat/absorb/issues/389) (2026-09). A parent asked for more because "My kids … typically max out at 4.5x or rarely 5x speed" and "the speed limit is a non starter". The developer replied, "Will be in 1.11.1 beta 4, speed goes up to 5x now". This was commit [a1cdf6c](https://github.com/pounat/absorb/commit/a1cdf6c00e705620059883c6bf6fbcc546eadb26) of 2026-09-15. So the App Store's 1.10.0 still caps at 3× (inference from the dates).
- Default presets: 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5 ([AB `lib/services/player_settings.dart`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/lib/services/player_settings.dart) L135).
- The default-speed setting draws a 0.5–5.0 slider but still clamps to 3.0 ([AB `lib/screens/settings_screen.dart`](https://github.com/pounat/absorb/blob/86334772b2bde1b39910e47bcde93c8836191a42/lib/screens/settings_screen.dart) L85, L2728-2729). This is a leftover from the old cap and doesn't affect the stretcher.
- The same range applies to both platforms. On iOS that means `.timeDomain` (`'ipto'`, advertised 0.5–2.0) is driven up to 5×.

### Quality claims and complaints

- **The developer makes no quality claim** about high-speed audio in the README or code, apart from the vendored `just_audio` comment about speeds below 1.0.
- **No speed-quality complaint was found.** A search of the issue tracker for "speed" (25 issues, open and closed) finds feature requests (faster speeds, speed controls in CarPlay or Android Auto, speed-adjusted times) and display bugs, but none about how sped-up speech sounds on either platform. The one audio-quality issue, [#177](https://github.com/pounat/absorb/issues/177) (Android, "pumping" at sentence ends), was a gain and compressor stage, not the stretcher.
- Absence of complaints is weak evidence: the user base is small and asking for speed, not quality (inference).

## 2. Overcast

Overcast is closed source. Everything below is Marco Arment's own words unless tagged otherwise.

### Time-stretch algorithm

- **2013, before Overcast shipped (verified, [marco.org](https://marco.org/2013/10/18/podcast-app-playback-speeds)):**
  - "all popular podcast players on iOS are using Apple's AVAudioPlayer or AVPlayer rate parameter. Under the hood, those use the AUiPodTime AudioUnit, which only supports a handful of speeds".
  - Lower-level audio units can vary speed further, "but they're much more complex to use, much harder on the CPU and battery, and mostly designed for music. They're not nearly as natural-sounding and listenable as Apple's built-in (but limited) … iPodTime algorithm that's specifically designed for processing speech."
  - "It's very unlikely, therefore, that we'll see an iOS podcast app that can legitimately offer playback faster than 2x." He also wrote "Overcast will use speed-accurate labels", and called Pocket Casts' "3x" of the time "simulated from 2x audio".
- **2014, at launch (verified, [TechCrunch interview](https://techcrunch.com/2014/07/20/why-marco-arment-built-a-podcast-app/)):**
  - "I started playing with different libraries, different even third-party commercial libraries to time shift and time bend, and I ended up using some of the Apple's newer APIs using some new settings they had launched."
  - "There's a low-level API you can set to say, 'All right, I want the time stretching algorithm to be this,' and it's a trade-off between CPU time and quality … At my level that I'm working on, I have the same option that I can take, so I made the same choice there."
  - Castro had improved "the voice quality of their speed-up algorithm" by "choosing one of these newer APIs".
- **Reading the 2014 statement (inference):**
  - "Newer APIs" and "new settings" match iOS 7's `AVAudioTimePitchAlgorithm` (2013), whose only non-deprecated pitch-corrected choices are `.timeDomain` ("Modest quality, less expensive") and `.spectral` ("Highest quality, most computationally expensive"). That is exactly "a trade-off between CPU time and quality".
  - At the Core Audio level, the matching units are `'ipto'` and `'nutp'` (time-pitch.md §1).
  - The interview does not say which side he picked.
- **2020 (verified, [tweet thread](https://convopage.com/c/1339965184421621760), mirror):**
  - Arment complained that macOS Safari uses "the worst/fastest" of Apple's "quality modes for variable-speed audio playback". His suggested fix was "Try AVAudioTimePitchAlgorithmTimeDomain."
  - On WebKit's choice of spectral, he asked: "what's worse when guessing wrong: speech under freq domain, or music under *SOLA?" He also wrote that it doesn't follow "that the *SOLA artifacts in music are less acceptable than the spectral artifacts in speech."
  - Apple's WebKit engineer `@jernoble` replied that TimeDomain "would solve Marco/Overcast's use case".
- **Conclusion on the algorithm:**
  - Verified: Overcast uses an Apple time-stretch API rather than a third-party library. That was true in 2014, in his words.
  - Inference: given his 2020 preference for time-domain stretching on speech and Apple's DTS advice to wrap `'ipto'` in an engine (time-pitch.md §3), the most likely candidate is `.timeDomain`/`'ipto'`.
  - Not verified: whether that unit survived the 2020 Voice Boost 2 rewrite, which replaced AudioUnits elsewhere in the chain (next section).

### How it's wired into the player

- **Custom Core Audio engine, not AVPlayer (verified).**
  - 2014: "I learned the low-level Core Audio API and made a 'Castaway' prototype that could apply these effects to a podcast file", with "liberal use of low-level Accelerate vDSP operations" ([marco.org](https://marco.org/2014/07/16/overcast)).
  - In the interview: Voice Boost and "the higher speed algorithm, you can do that with AVPlayer … You can't do smart speed with it though", so he chose "to write my own audio engine, and use Core Audio down to the raw levels" ([TechCrunch](https://techcrunch.com/2014/07/20/why-marco-arment-built-a-podcast-app/)).
- **Streaming architecture since 2015 (verified).** "converting the audio engine to a streaming architecture has made all playback faster to start", and "Smart Speed and Voice Boost are always available, even when streaming" ([Overcast 2](https://marco.org/2015/10/09/overcast2)).
- **Voice Boost 2 replaced Apple's AudioUnits in the effects chain (verified, [marco.org](https://marco.org/2020/01/31/voiceboost2)).**
  - The original Voice Boost "was a single configuration of Apple's AudioUnits". Voice Boost 2 is "an all-new audio engine": "I had to write every component from scratch, without using AudioUnits, because I wanted to understand and control everything … and avoid Apple's platform-specific API limits."
  - "The code had to be pure C, with highly optimized and vectorized code". It runs "as a streaming process … without needing to scan the entire file first or look very far ahead".
  - "Smart Speed was actually entirely rewritten as part of Voice Boost 2".
  - The same release brought "full-blown Smart Speed and Voice Boost" to AirPlay 2 on iOS 13.1+.
  - The post names loudness normalization to −14 LUFS, compression, EQ and a true-peak lookahead limiter. **It does not mention the time-stretcher.**
- **The engine was kept through the 2024 rewrite (verified).** "The audio engine. It's the best part of Overcast, and still leads the industry in sound quality, silence skipping, and volume normalization" (under "What's not" rewritten, [marco.org](https://marco.org/2024/07/16/overcast-rewrite)). Speed is not among the three things claimed.
- **Inference:** AirPlay 2 with custom DSP suggests Overcast renders its own PCM into an AVFoundation sample-buffer path (`AVSampleBufferAudioRenderer` and `AVSampleBufferRenderSynchronizer`). That path has its own `audioTimePitchAlgorithm` (default `.timeDomain` per time-pitch.md §1), so speed could be applied there rather than in Arment's C code. Nothing public confirms this.
- **Binary not inspected.** Overcast is not installed on this Mac (`/Applications` has no Overcast or Absorb), no IPA is available, and I did not install apps on the user's machine. Checking its imported symbols (for example `AVAudioTimePitchAlgorithmTimeDomain`, `kAudioUnitSubType_AUiPodTimeOther`, `AVSampleBufferAudioRenderer`) through the iPad-on-Mac build would settle the algorithm question. See [Open questions](#open-questions).

### Smart Speed and Voice Boost

- **Smart Speed "shortens silences"** and "is like getting another speed increment for free: it saves time without sounding weird" ([marco.org 2014](https://marco.org/2014/07/16/overcast)).
  - It "usually averages about 15% faster than normal" on his shows. "I can tweak the parameters to be more aggressive and go a bit faster", but he doesn't think the unnatural pacing is worth it ([marco.org 2015](https://marco.org/2015/01/23/smart-speed-test)).
  - Since 2015 it "adapts dynamically to quieter voices" ([Overcast 2](https://marco.org/2015/10/09/overcast2)). Since 2020 it uses Voice Boost's measured loudness when both are on ([Voice Boost 2](https://marco.org/2020/01/31/voiceboost2)).
  - The App Store copy today: "Smart Speed saves time without distorting the audio or sounding unnatural" ([App Store](https://apps.apple.com/us/app/overcast-podcast-app/id888422857)).
- **Voice Boost** is "a combination of dynamic compression and equalization" (2014). In version 2 it is a "mastering-quality audio-processing pipeline" with LUFS normalization and a true-peak limiter, at "less than 1% CPU usage on an iPhone SE" (2020).
- **Relevance to Logos (inference):** both features are speech-aware DSP before or after the stretch. Neither changes the stretch algorithm itself.

### Speed range

- **Not verified from a primary source.** Neither the App Store description nor overcast.fm states a range.
- Arment's 2013 promise was speed-accurate labels and scepticism about anything above a true 2× ([marco.org](https://marco.org/2013/10/18/podcast-app-playback-speeds)).
- Secondary sources say the slider went to 2× at launch and "up to 2.5 or 3x" by 2016 ([Andrew Heiss, 2016](https://www.andrewheiss.com/blog/2016/02/11/fauxcasts/index.html)). The current maximum needs checking in the app.

### Quality claims and complaints at 2–3×

- **Arment's claims are about Smart Speed and Voice Boost, not about high-speed stretching.** The 2024 post claims sound quality, silence skipping and normalization, with no speed claim ([marco.org](https://marco.org/2024/07/16/overcast-rewrite)).
- His only statement about 2× is that "true 2x playback is very fast and hard to keep up with" (2013).
- **Usage:** "only around 1% of Overcast listeners use speeds of 2x or higher", according to Arment as reported by [BuzzFeed News](https://www.buzzfeednews.com/article/doree/meet-the-people-who-listen-to-podcasts-at-super-fast-speeds) (2017). This is secondary, and the figure is old.
- **No first-party or tracker-grade complaints were found** about Overcast at 2–3×. Overcast has no public issue tracker.

## 3. Comparison with the players in #44

| Player | iOS engine | Stretcher | Max speed | Notes |
|---|---|---|---|---|
| Absorb | Single `AVPlayer`, one item per file | `.timeDomain` | 5× (3× in App Store 1.10.0) | Android: Media3 Sonic |
| Overcast | Custom Core Audio engine, pure-C DSP | An Apple time-stretch API (2014, his words); most likely time-domain (inference) | Unverified (about 3× per secondary sources) | Smart Speed and Voice Boost 2 are its own |
| BookPlayer, Pocket Casts, audiobookshelf, Apple Books | See time-pitch.md §3 | `.timeDomain` / `'ipto'` | 2× to 10× | |

## Open questions

- **Which algorithm does the shipping Overcast binary import?** Install Overcast on an Apple Silicon Mac (iPad app) and run `nm -u` / `otool -L` on it, looking for `AVAudioTimePitchAlgorithmTimeDomain`, `AVAudioTimePitchAlgorithmSpectral`, `kAudioUnitSubType_AUiPodTimeOther` or `NewTimePitch`, and `AVSampleBufferAudioRenderer`. This needs the user to install the app.
- **What is Overcast's current maximum speed?** Check it in the app.
- **Does Absorb on iOS at 3–5× (`'ipto'` well past 2.0) sound acceptable to its users?** No complaints so far, but 5× only landed in September 2026. The answer would inform whether Logos can drive `.timeDomain` above 2× or should cap it.
- **Is silence shortening (Smart Speed-style) worth a separate ticket?** It is the one speed-related technique here that the other players don't have, and it needs the same AVAudioEngine-style custom pipeline as Sonic would (time-pitch.md §5).
