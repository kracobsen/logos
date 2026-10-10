# iOS 27 app icons: layers, Liquid Glass and appearances

Findings for #48 (part of #46, "Wayfinder: Logos app icon"). Researched 2026-10-10 against Xcode 27.0 (27A266a, Icon Composer 27.0).

## Sources

- [HIG] Human Interface Guidelines, [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons). Change log: "June 8, 2026: Refined guidance for Liquid Glass."
- [IC] Xcode docs, [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
- [AC] Xcode docs, [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
- [BSR] Xcode docs, [Build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference).
- [ICP] [Icon Composer product page](https://developer.apple.com/icon-composer/).
- [W25-220] WWDC25, [Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/).
- [W25-361] WWDC25, [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/).
- [W26-8012] WWDC26, [Icon Composer for Beginners Group Lab](https://developer.apple.com/videos/play/wwdc2026/8012/).
- [LOCAL] Checked on this machine: Xcode 27's `.icon` file template, strings in Icon Composer's `IconComposerFoundation.framework`, and an `actool` compile of a test `.icon` next to this repo's empty `AppIcon.appiconset` (details under "Local verification").

## Canvas, shape and safe area

- iPhone, iPad and Mac share one **1024 x 1024 px square** canvas. Watch is 1088 x 1088 px. [HIG Specifications] [IC] [W25-361]
- Supply **square, unmasked** layers. The system masks them to a rounded rectangle, and pre-masked layers spoil the specular highlights and leave jagged edges. Don't export the canvas mask. [HIG Icon shape] [IC]
- There is **no numeric safe area for iOS**. HIG: "Keep primary content centered to avoid truncation when the system adjusts corners or applies masking", and use the grid from the production templates in Apple Design Resources. Only tvOS has an explicit safe zone. [HIG Icon shape, Platform considerations]
- The 2025 grid is "simpler and more evenly spaced" with a rounder corner radius. Circular artwork has its own frame in the grid. [W25-220] Icon Composer can overlay the grid (Grid: Light or Dark). [IC]
- Colour spaces: sRGB, Gray Gamma 2.2, Display P3. [HIG Specifications]
- The system scales the icon down for Settings, notifications and so on, so detail has to survive small sizes. [HIG Specifications, Design]

## Structure of a `.icon`

A `.icon` is a folder bundle holding `icon.json` plus an `Assets/` folder of SVG or PNG layer images. [LOCAL] Xcode 27's template for a new iOS icon is:

```json
{ "fill": { "automatic-gradient": "extended-srgb:0.00000,0.53333,1.00000,1.00000" },
  "groups": [],
  "supported-platforms": { "squares": ["iOS"] } }
```

- **Background**: the icon's own `fill`, which is a solid colour or a gradient set in Icon Composer. A custom background image is rarely needed. If you import one it must be full-bleed and opaque. [HIG Layer design] [IC] Apple supplies "System Light" and "System Dark" gradients to use instead of pure white or black. [W25-220]
- **Groups**: from 1 up to a **maximum of 4**. Groups are the depth planes the system renders, back to front as listed in the sidebar, and the Liquid Glass properties live on them. [IC] [W25-361] Icon Composer rejects more: "This icon exceeds the maximum group limit of four." [LOCAL]
- **Layers**: the SVG or PNG images inside a group. Imported layers are glass by default, and a layer can opt out (Liquid Glass > Effects off). [IC] [W26-8012]
- **Per-layer Color settings**: Fill (Automatic from the file, None, Solid or Gradient), Opacity and Blend Mode. These are typically specialised per appearance. [IC] [W25-361]
- **Per-group Liquid Glass settings**:
  - Mode: Individual (each layer is its own glass) or Combined (the group is one glass object).
  - Specular: Automatic (the default), Inside, Outside or Off.
  - Blur.
  - Refraction: on/off plus strength and depth (`refractivity-strength` and `refractivity-depth` in the file).
  - Translucency.
  - Shadow: Neutral (the default) or Chromatic, plus opacity.
  [IC] [W25-361] [LOCAL]
- **Composition**: per-layer position and scale, and visibility. These may vary per platform. [IC]
- Any setting can be **specialised** per appearance (`*-specializations` keys) or per platform. Settings you don't specialise apply to every variant. [IC] [LOCAL]
- Artwork prep:
  - Use vectors, exported as SVG. Use PNG for mesh gradients and raster artwork.
  - Convert text to outlines, because SVG doesn't keep fonts.
  - Export every layer at full canvas size so it lands in position.
  - Name layers with back-to-front numbers.
  - Leave background colours, blur, shadow, specular, opacity and translucency out of the source artwork and set them in Icon Composer instead.
  [IC] [W25-361] [W26-8012]

## Appearances

- iOS shows **six appearances**: Default, Dark, Clear light, Clear dark, Tinted light and Tinted dark. [HIG Specifications] [W25-361]
- They come from **three annotations** in one file: **Default, Dark and Mono**. Mono is a grayscale annotation that produces both Clear variants and both Tinted variants. [IC] [ICP] [W25-361] [W26-8012] The system generates any variant you don't annotate. [HIG Appearances]
- Mono guidance:
  - Make at least one element (usually the most recognisable one) white and map the other colours to greys.
  - Maximise the dynamic range: dark darks and bright highlights.
  - Don't rely on colour to carry meaning.
  [W25-361] [W26-8012]
- Dark guidance: base the dark icon on the light one, use complementary colours, avoid excessive brightness, and prefer coloured backgrounds because they give the most contrast. [HIG Appearances] [W25-220]
- Keep the core features the same in every appearance. Don't swap elements in and out between variants. [HIG Appearances]
- Clear-mode glass is pinned and ignores the system transparency slider. [W26-8012]
- Alternate icons (not needed for Logos) need their own dark, clear and tinted variants. [HIG Appearances]

## HIG on motif and text

From [HIG Design, Visual effects], with [W25-220] where marked:

- **Motif**:
  - Pick one simple concept that captures the app's essence and draw it with as few shapes as possible.
  - Use a simple background (solid or gradient). You don't need to fill the canvas.
  - Filled, overlapping shapes with transparency give depth.
  - Prefer illustrations over photos, and don't copy UI components or screenshots.
  - Use a frontal, flatter view. Realistic 3D perspective competes with the material. [W25-220]
  - Avoid very thin lines and sharp corners. Rounder corners let the light travel along edges. [W25-220]
  - Foreground layers need crisp, defined edges, not feathered ones.
- **Text**: include it "only when it's essential to your experience or brand". Text in an icon isn't accessible or localisable, is often too small to read, and is redundant next to the app name. A mnemonic first letter is acceptable. Avoid words like "Play" or "New".
- **Effects**: don't bake in specular highlights, drop shadows, bevels, blurs or glows. The system adds them dynamically, and static copies conflict with them.
- **Consistency**: use one design across platforms.

## How Xcode consumes a `.icon`

- Add `AppIcon.icon` to the app target as an ordinary resource next to the sources, **not inside** `Assets.xcassets`. The target's App Icon name (`ASSETCATALOG_COMPILER_APPICON_NAME`, "Primary App Icon Set Name") must equal the file name without `.icon`. [IC] [W26-8012] [BSR]
- "If you add an Icon Composer file to your Xcode project, it replaces any existing icon asset catalog." With the same name, "the latest version of Xcode uses the Icon Composer file instead of an existing `AppIcon` asset catalog", and Apple suggests removing the old set. [IC] [W26-8012]
- For older deployment targets, Xcode generates flattened fallback images from the `.icon` at build time. Keep an appiconset only if you want a different look on old OS versions. [IC] This doesn't apply to Logos, which is iOS 27-only.
- An App Store or marketing image comes from the same file, because Icon Composer can export flattened images. [ICP]
- **For Logos specifically**:
  - `Config/Base.xcconfig` already sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, so no build setting changes.
  - `Logos/` is a buildable folder (`PBXFileSystemSynchronizedRootGroup`), so placing `Logos/AppIcon.icon` adds it to the target with no project-file edit.
  - Delete the empty `Logos/Assets.xcassets/AppIcon.appiconset` at the same time (Apple's advice, and it avoids two assets named AppIcon).
  - `LogosUITests.xcconfig` blanks the setting for the test bundle, which is unaffected.
  [LOCAL]

### Local verification

Run on Xcode 27.0 with `actool --platform iphoneos --minimum-deployment-target 27.0 --target-device iphone --app-icon AppIcon`. [LOCAL]

| Inputs | Result |
|---|---|
| Empty `AppIcon.appiconset` only (today's repo) | No icon at all: empty partial Info.plist, no `Assets.car`. |
| `AppIcon.icon` only | `Assets.car` with icon stacks for Light, Dark and Tintable, a flattened 1024 px image for each, `AppIcon60x60@2x.png`, and `CFBundleIconName = AppIcon`. |
| Both, same name | Same as `.icon` only. The `.icon` wins, with no warning or error. |

## iOS 27 versus iOS 26

- **The format and Xcode integration are unchanged.** "No, there is no change. It's exactly the same way." An iOS 26 `.icon` renders in the iOS 27 style without recompiling. [W26-8012] [ICP]
- **Rendering**:
  - New specular highlights: sharper, with dark parts that define the shape, and a vertical light angle from above. Inside and Outside placement are new user choices. [ICP] [W26-8012]
  - **Refraction**: layers pick up and transmit colour and shape from what's behind them, with adjustable strength and depth. It matters when layers overlap, and small changes make big differences. [ICP] [IC] [W26-8012]
  - IC note: "In iOS ... versions earlier than 27, specular highlights appear on when you choose Inside or Outside, and Refraction settings have no visible effect."
- **Design trend**: Apple reduced translucency in many of its own icons for 27, and "that part doesn't happen automatically". [W26-8012]
- The HIG was "Refined ... for Liquid Glass" on 2026-06-08. The 2025 changes (layers, six appearances, the Default/Dark/Mono annotations) still stand. [HIG change log]

## What the design brief must specify

1. **Motif**: one simple, frontal, flat-ish concept with few shapes, no text (or at most a single-glyph mnemonic, justified), no thin strokes or sharp corners, and crisp edges.
2. **Layer split**: at most 4 groups, back to front, naming the layers in each group. Each layer is a full-canvas 1024 px square SVG (PNG only for raster or mesh gradients) with its primary content centred on the Apple grid. Also say which layers overlap, because overlaps are where refraction and specular show.
3. **Background**: solid colour or gradient, given as hex values. A coloured background is preferred over white or black; otherwise use System Light or Dark.
4. **Per-group glass**: Individual or Combined; Specular (Automatic, Inside or Outside); Refraction on or off and its intent; Translucency (lean low for 27); Blur; Shadow (Neutral or Chromatic).
5. **Colours per annotation**:
   - Default: fill and opacity for every layer.
   - Dark: a subdued palette and dark background, with the same elements.
   - Mono: grayscale mapping with one hero element white and a wide dynamic range.
   - Note how both Clear and both Tinted variants should read.
6. **Invariants**: the same elements in every appearance, and the icon must still read at small sizes (Settings, notifications).
7. **Delivery**:
   - `Logos/AppIcon.icon` with iOS as the only platform.
   - Remove the empty `AppIcon.appiconset`.
   - No build setting changes.
   - A flattened export for the App Store and marketing.
