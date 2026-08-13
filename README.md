# maple-swift

Session replay capture for iOS.

**Milestone 1 — capture only.** There is no networking yet. Segments are written to disk in
exactly the form they will be transmitted, so adding upload is a transport swap rather than a
rewrite.

```swift
import MapleReplay

var options = ReplayOptions()
options.flushPolicy = .buffered(window: 30)   // or .continuous(segmentDuration: 5)
MapleReplay.shared.start(options: options, serviceName: "my-app")

// In buffered mode nothing is written until something asks for it:
MapleReplay.shared.flush(trigger: "error")
```

## Approach

Masked screenshots encoded to H.264, wrapped in rrweb-shaped events — the design Sentry's
`sentry-cocoa` uses, and MIT-licensed prior art we can read.

The alternative is serialising the view hierarchy into wireframes (Datadog, PostHog). We didn't
take it. That approach needs a per-UI-framework mapper built on private SwiftUI class names, which
Apple renames between releases — PostHog's iOS implementation carries separate mappings for iOS 18
and iOS 26 and symbols like `_TtC7SwiftUIP33_…CGDrawingLayer`. Screenshots are indifferent to what
drew the pixels.

The tradeoff is real: no selectable text in playback, and larger payloads. We think a recorder
that keeps working across iOS releases without maintenance is worth both.

### Redaction

Screenshots don't remove the need to walk the view tree — they narrow it. We walk it only to
locate sensitive regions, never to reconstruct the UI, and everything is decided **structurally**
rather than by class name. A view or layer is content if it has bitmap `contents`, is a
specialised drawing layer, or overrides `draw(_:)`; a view that can only paint `backgroundColor`
is not.

That inverts the usual failure mode. When Apple renames a SwiftUI internal, a wireframe recorder
draws a blank box where your UI was. Here an unrecognised drawing surface is *masked* — degraded,
never leaked.

All masking defaults are on (`maskAllText`, `maskAllImages`). `unmaskedViewClasses` is the only
opt-out.

Turn on `MaskingPreviewView` while developing: it runs the same scanner the recorder does and
draws the rects live, so a wrong mask is visible immediately instead of after exporting a video.

## Output

Per segment, in `<caches>/maple-replay/<session-id>/`:

| File | What it is |
| --- | --- |
| `segment-NNN.json.gz` | The gzipped rrweb event array — the future `POST /v1/sessionReplays/blob` body |
| `segment-NNN.mp4` | The same video, kept unreferenced so a human can double-click it |
| `meta.ndjson` | Rows for `POST /v1/sessionReplays/meta` |

Events per segment: an rrweb `meta` (type 4), a `custom` event (type 5) tagged `video` carrying the
MP4 as base64, a segment breadcrumb, and touch events as `incrementalSnapshot` (type 3).

## Measured sizes

25 frames (25 s) at 1 fps on an iPhone 17 Pro, mostly-static screens:

| Quality | Resolution | MP4 | B/frame | Gzipped chunk |
| --- | --- | --- | --- | --- |
| low | 236×512 | 11.9 KB | 477 | 7.0 KB |
| medium | 394×854 | ~19 KB | 675 | ~11 KB |
| high | 402×874 | 18.9 KB | 757 | 11.1 KB |

The gzipped chunk lands at roughly 0.6–1.0× the raw MP4 despite base64's 33% inflation, because a
near-static screen produces a highly compressible H.264 bitstream. **Carrying the MP4 as base64
inside the JSON chunk is comfortably viable** — a 30 s buffered segment measured 12.8 KB — which
means an upload path needs no gateway changes at all.

Known gap: capture happens at 1× points, so on a 402 pt-wide device `medium` and `high` barely
differ. The tiers are calibrated in pixels and want recalibrating, or `high` should capture above
1×.

## Development

```bash
xcodebuild test -scheme maple-swift -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`swift build` does not work — the package is UIKit-only, and SwiftPM builds for macOS by default.
Use an iOS Simulator destination.

The demo app is the real verification surface. Redaction correctness is a visual property; no unit
test substitutes for opening the MP4 and looking at it.

```bash
cd Examples/ReplayDemo && xcodegen generate
xcodebuild build -project ReplayDemo.xcodeproj -scheme ReplayDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

It has both a SwiftUI and a UIKit screen full of deliberate PII, a mask-preview toggle, mode and
quality switches, and a button that fires `flush(trigger:)`.

## Not here yet

Upload, the meta/blob POSTs, playback, crash-recovery of in-flight segments, and Android.
