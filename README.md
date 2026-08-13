# maple-swift

Session replay capture for iOS.

Masked screenshots, encoded to H.264 and uploaded to Maple's ingest gateway.

```swift
import MapleReplay

var options = ReplayOptions()
options.ingestKey = "maple_pk_…"              // required
options.flushPolicy = .buffered(window: 30)   // or .continuous(segmentDuration: 5)
MapleReplay.shared.start(options: options, serviceName: "my-app")

// In buffered mode nothing is emitted until something asks for it:
MapleReplay.shared.flush(trigger: "error")
```

`start()` refuses to record without a well-formed key — assertion in debug, a log line and no
recording in release. A capture that can never be delivered costs the user battery and gains them
nothing, and the 401 it would earn is invisible behind a transport whose whole job is to swallow
failures.

## Upload

Three POSTs, all best-effort, none retried.

| Endpoint | Body | When |
| --- | --- | --- |
| `/v1/sessionReplays/meta` | NDJSON, one row | `active` at session start, `ended` at session end |
| `/v1/sessionReplays/blob` | the gzipped chunk, verbatim | as each segment is produced |
| `/v1/sessionEvents` | NDJSON, one row per event | batched `track(_:properties:)` calls |

The **meta row is the billed unit** and the only thing that makes a session exist in the UI; blobs
are not metered. An SDK that uploads chunks and never posts one bills nothing and records into a
void, so the `ended` row keeps going even after uploads have been cut off.

### Why there are no retries

The gateway assumes clients drop on non-2xx and says so in the handler. `413` is not a transient
error — it means this session spent its 1 GiB decompressed budget and every further chunk will be
rejected before it is read. `429` is backpressure. Retrying either is arguing with a server that
is asking for less. So a failure drops the payload, and the only thing a response can change is
whether we stop:

| Status | What happens |
| --- | --- |
| `413` | Stop uploading chunks for this session. Metadata still goes — a truncated session still has to end cleanly. |
| `402` | Entitlement denied. Stop everything for this session. |
| `429`, `5xx`, transport errors | Drop the payload, keep going. |

Failures warn at most once every 30 s, matching the browser SDK, so a misconfigured endpoint is
visible in the log without flooding it.

### Sessions end at the background transition

There is no `keepalive` and no unload beacon on iOS, so backgrounding is the last moment anything
can be sent. On `UIApplication.didEnterBackground` the SDK flushes the tail, posts the `ended` row,
and holds a `UIApplication` background task open until those requests finish (8 s ceiling — the OS
kills an app that overruns). Coming back to the foreground starts a **new** session with a new id:
a session that has reported itself ended must not keep recording under the same id, and the
per-session byte budget resets with it.

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

Nothing is written to disk on the upload path. Set `options.writeSegmentsToDisk = true` and each
segment is also mirrored to `<caches>/maple-replay/<session-id>/`, which is how this gets debugged:

| File | What it is |
| --- | --- |
| `segment-NNN.json.gz` | The gzipped rrweb event array — byte-for-byte the `POST /v1/sessionReplays/blob` body |
| `segment-NNN.mp4` | The same video, kept unreferenced so a human can double-click it |
| `meta.ndjson` | The rows posted to `POST /v1/sessionReplays/meta` |

Events per segment: an rrweb `meta` (type 4), a `custom` event (type 5) tagged `video` carrying the
MP4 as base64, a segment breadcrumb, and touch events as `incrementalSnapshot` (type 3).

## Quality tiers

A tier is a multiple of the window's own size in points, not an absolute pixel cap:

| Quality | Pixels per point | On a 402×874 pt phone |
| --- | --- | --- |
| low | 0.5× | 202×438 |
| medium | 1× | 402×874 |
| high | 2× | 804×1748 |

Capture scale follows the tier, so `high` rasterises at 2× and genuinely resolves detail the point
grid can't. A single ceiling of 2048 px on the longest edge bounds worst-case memory; it only binds
on iPad.

Absolute pixel caps don't work here. A phone window is ~400×875 pt and capture ran at 1×, so caps
of 854 and 1280 px both landed on the native size — `medium` and `high` came out within 4% of each
other and the setting did nothing above `low`. Rendering at 2× costs about 1 ms and a 5.4 MB
transient bitmap per frame; at 1 fps that is not a cost worth avoiding.

## Measured sizes

31 frames (a full 30 s buffered window) at 1 fps, mostly-static screens, iPhone 17 Pro simulator:

| Quality | Resolution | MP4 | B/frame | Gzipped chunk |
| --- | --- | --- | --- | --- |
| low | 202×438 | 11.5 KB | 380 | 7.2 KB |
| medium | 402×874 | 21.8 KB | 721 | 12.9 KB |
| high | 804×1748 | 37.7 KB | 1246 | 15.3 KB |

The gzipped chunk lands at roughly 0.4–0.6× the raw MP4 despite base64's 33% inflation, because a
near-static screen produces a highly compressible H.264 bitstream. **Carrying the MP4 as base64
inside the JSON chunk is comfortably viable** — a full 30 s buffered segment is 12.9 KB at the
default tier, and 15.3 KB even at 2× resolution — which means an upload path needs no gateway
changes at all.

Four times the pixels costs 1.7× the MP4 and 1.2× the chunk: H.264 spends its bits on the parts of
the frame that change, and resolution mostly buys sharper still detail rather than more bitstream.

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

Point it at a gateway with environment variables rather than an edit-and-rebuild cycle:

```bash
SIMCTL_CHILD_MAPLE_ENDPOINT=http://localhost:3475 \
SIMCTL_CHILD_MAPLE_INGEST_KEY=MAPLE_TEST \
xcrun simctl launch booted dev.maple.ReplayDemo
```

`MAPLE_TEST` is the gateway's sentinel key: it authenticates, and everything sent under it is
accepted and discarded — useful for exercising the request path without a real key. Note the
gateway logs rejections but not successes, so a recording proxy in front of it is the only way to
watch the 200s.

## Not here yet

Playback and Android.
