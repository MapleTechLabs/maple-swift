# maple-swift

Session replay **and** OpenTelemetry tracing for iOS, in one package.

Masked screenshots encoded to H.264, and spans exported as OTLP, both to Maple's ingest gateway.
Every span carries the live `session.id` and every trace id lands on the session's row, so a trace
resolves to the recording that produced it and back again — the same contract the browser SDK has.

```swift
import Maple

var options = MapleOptions()
options.ingestKey = "maple_pk_…"                     // required
options.replay.flushPolicy = .buffered(window: 30)   // or .continuous(segmentDuration: 5)
Maple.start(options: options, serviceName: "my-app", environment: "production")

// In buffered mode nothing is emitted until something asks for it:
Maple.flush(trigger: "error")
```

That single call starts replay, starts tracing, auto-instruments every outgoing `URLSession`
request with a W3C `traceparent` header, and tracks screens.

`MapleReplay` and `MapleTracing` are also separate products if you want only one of them. Both
refuse to start without a well-formed key — assertion in debug, a log line and nothing in release.
Work that can never be delivered costs the user battery and gains them nothing, and the 401 it
would earn is invisible behind a transport whose whole job is to swallow failures.

## Configuring a build

Nothing has to be hardcoded. Leave `ingestKey`, `endpoint`, `serviceName` and `environment` unset
and they come from `Info.plist`, so the whole integration is:

```swift
Maple.start()
```

Put the values in your `Info.plist` as build settings, which Xcode substitutes at build time:

```xml
<key>Maple</key>
<dict>
    <key>IngestKey</key>
    <string>$(MAPLE_INGEST_KEY)</string>
    <key>Endpoint</key>
    <string>$(MAPLE_ENDPOINT)</string>
    <key>Environment</key>
    <string>$(MAPLE_ENVIRONMENT)</string>
    <key>ServiceName</key>
    <string>$(MAPLE_SERVICE_NAME)</string>
</dict>
```

Then a pipeline sets them like any other build setting — no code change per environment:

```bash
# xcodebuild / Fastlane (xcargs:) / any CI
xcodebuild archive -scheme MyApp \
  MAPLE_INGEST_KEY="$MAPLE_INGEST_KEY" \
  MAPLE_ENVIRONMENT=production
```

**Xcode Cloud**: define `MAPLE_INGEST_KEY` as an environment variable on the workflow (mark it
secret) and add a `ci_post_clone.sh` that writes it into an `.xcconfig` the target already includes —
Xcode Cloud environment variables reach scripts, not build settings, so the script is the bridge:

```bash
# ci_scripts/ci_post_clone.sh
echo "MAPLE_INGEST_KEY = $MAPLE_INGEST_KEY" >> ../Config/Secrets.xcconfig
```

**Per-configuration** values are just `.xcconfig` files — `Debug.xcconfig` pointing at staging,
`Release.xcconfig` at production — with no `#if DEBUG` anywhere in your code.

`Examples/ReplayDemo` is wired exactly this way; see its `project.yml`.

### Keys and precedence

- **Values set in code win over the plist.** A value at the call site is a deliberate act by
  someone reading the code in front of them; the plist is the deployment default.
- Flat keys (`MapleIngestKey`, `MapleEnvironment`, …) work too, for apps that patch a plist in CI
  rather than substituting build settings. The nested `Maple` dictionary wins if both are present.
  Note that `INFOPLIST_KEY_<name>` build settings are *not* a way to set these: Xcode only honours
  that prefix for keys it knows about, and drops the rest from the generated plist without warning.
- An unsubstituted `$(MAPLE_INGEST_KEY)` surviving into the built plist means the build setting was
  never defined. The SDK treats that as unset and logs it, rather than sending `Bearer $(…)` and
  earning a 401 that a best-effort transport swallows.
- `TracesSampleRate` reads from either a number or a string, because a substituted build setting is
  always a string.

The ingest key is the **public** `maple_pk_` one, which is designed to ship inside an app binary —
it can only write telemetry. Still worth injecting from a CI secret rather than committing, so
rotating it does not need a code change.

`ProcessInfo.environment` is deliberately not consulted by the SDK. It is populated only when the
app is launched by Xcode or `simctl`, so an SDK configured that way works on a developer's machine
and is silently unconfigured in TestFlight. The demo layers env vars on top for its own local
testing, which is the right place for that.

## Tracing

```
Sources/MapleCore     the session/trace join and the shared request plumbing
Sources/MapleTracing  spans, sampling, OTLP export, URLSession + screen instrumentation
Sources/MapleReplay   the recorder
Sources/Maple         both, under one call
```

`MapleCore` exists so the two signals stay siblings: an app that wants only tracing should not link
a screenshot recorder to get it. It is the same role `packages/browser-session` plays on the web.

Spans go to `POST /v1/traces` as gzipped **OTLP/JSON** — the gateway accepts it, so there is no
protobuf dependency and the package still has none at all. Batched every 2 s, dropped rather than
retried, and force-flushed on `didEnterBackground` inside a `UIApplication` background task, which
is the last moment anything can be sent on iOS.

### How a session and a trace are joined

Three links, all three the ones the backend already reads:

| Link | Where |
| --- | --- |
| `session.id` **span attribute** | stamped on every span at start |
| `session_replays.TraceIds` | every trace id seen during the session, on the `ended` metadata row — this is what "which recording produced this trace" searches |
| `session_events.TraceId` | per distilled event |

`session.id` is deliberately **not** a resource attribute. The resource is fixed for the tracer's
lifetime, but iOS rotates the session on every foreground transition, so a resource-level id would
attribute every post-rotation span to a session that has already reported itself ended.

### Propagation

Outgoing requests carry `traceparent`, so the span your backend records is a **child** of the
phone's span rather than the root of an unrelated trace.

By default every host gets the header except Maple's own ingest paths. Set
`tracing.tracePropagationTargets` to a list of hosts or regexes to keep your trace ids away from
third-party services — the header is 55 bytes and there is no CORS on native, so the cost of the
broad default is disclosure, not breakage.

### Why a `URLProtocol` and not swizzled task-creation methods

The obvious approach is to swizzle `URLSession.dataTask(with:…)` and friends. It works for the
completion-handler and delegate APIs and **silently does not fire for `async` `data(for:)`**, which
on current iOS does not go through any of those Objective-C selectors.

That failure is invisible from the inside: spans are still produced by everything else, so the SDK
looks healthy while the API most modern apps actually call ships no `traceparent` at all. It was
caught only by asserting on bytes that left the process. `URLProtocol` sits underneath every
`URLSession` API, so there is one interception point and no list of selectors to keep matching
Apple's.

Two small swizzles remain, and each buys something the protocol cannot:

- `URLSessionTask.resume` captures the caller's active span onto the task. `URLProtocol` runs on
  the loading thread, where the caller's task-local context is gone — without this, a request made
  inside a `checkout` span starts its own trace and the backend's span hangs off a root that
  corresponds to nothing.
- `URLSessionConfiguration.default`/`.ephemeral` add the interceptor to sessions the app builds
  itself. `URLProtocol.registerClass` only reaches `URLSession.shared`.

Requests with an `httpBodyStream` are left alone: a stream cannot be replayed, and re-issuing the
request is exactly what the interceptor does. Losing a span there beats losing the upload.

`instrumentURLSession = .manual` installs none of it; use `MapleTracing.shared.trace(_:)` and
`traceHeaders()` instead.

### Screens

UIKit controllers are picked up by swizzling `viewDidAppear`/`viewDidDisappear`, giving a
`ui.screen` span whose duration is time-on-screen. SwiftUI has one `UIHostingController` for the
whole app, so screens announce themselves — `Maple.trackScreen("Checkout")` from `.onAppear`. Each
appearance also emits a `navigation` session event, which is what gives a mobile recording a
transcript beside the video.

### Status codes

`Error` on a transport failure or **5xx only**. A 4xx is the server correctly refusing something,
and marking those `Error` is what floods an error dashboard with expected outcomes — the ingest
gateway applies exactly this rule to its own spans, and the platform is easier to read when both
ends agree. The status code is recorded either way.

## Upload

Four POSTs, all best-effort, none retried.

| Endpoint | Body | When |
| --- | --- | --- |
| `/v1/sessionReplays/meta` | NDJSON, one row | `active` at session start, `ended` at session end |
| `/v1/sessionReplays/blob` | the gzipped chunk, verbatim | as each segment is produced |
| `/v1/sessionEvents` | NDJSON, one row per event | batched `track()`, `navigation` and `network` events |
| `/v1/traces` | gzipped OTLP/JSON | every 2 s, and on backgrounding |

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

## Crash recovery

In `.buffered` mode the ring buffer *is* the recording until something calls `flush(trigger:)`,
and a crash calls nothing. Without recovery, the 30 seconds before a crash — the most valuable
recording the SDK can produce, and the whole argument for buffered mode — is the one recording
guaranteed to be lost.

So every frame is also written to `<caches>/maple-replay/spool/<session-id>/` as it is captured,
and evicted on the same policy as the ring buffer. The in-memory buffer stays as the fast path for
ordinary flushes, but the disk copy is **complete**, not a sample — a partial copy recovers a
partial window, which is the failure this exists to prevent. At 1 fps the cost is one ~20 KB write
and one unlink per second.

Only redacted frames reach the spool. `RedactionPainter` is the first point a frame may be
retained anywhere, and the spool takes the same `CapturedFrame` the buffer holds; the unredacted
bitmap never leaves the main thread.

A spool directory that still exists at the next `start()` means that session never reached
`stop()`. Cleanup on clean shutdown is what makes the leftover meaningful — no signal handler or
exception hook is involved, and none of those survive `SIGKILL` or a watchdog kill anyway. The
frames are encoded into a segment carrying a `replay.crash_recovery` breadcrumb, numbered to
continue that session's sequence, posted under the **crashed** session's id, and followed by the
`ended` metadata row stamped with the last frame's time. Then the spool is deleted.

A user swiping the app away leaves the same trace and is recovered the same way. The two are
indistinguishable on disk, and the window is worth having either way.

Disk is bounded at three levels, because a crash loop leaves a fresh spool on every launch:

| Bound | Default | What it stops |
| --- | --- | --- |
| Frame capacity | the window | Ordinary growth — same eviction as the ring buffer |
| `maxSpoolBytes` | 16 MB | One session whose frames are far larger than its tier implies |
| `maxTotalSpoolBytes` | 48 MB | A crash loop filling the device one launch at a time |

Two spools are kept at most, newest first, and a spool that has failed to recover twice is
discarded rather than retried forever — the attempt count is persisted *before* the encode, so a
crash during recovery still counts. Set `crashRecovery = false` to turn all of it off.

Touch events are not recovered: they only ever lived in memory, so a recovered segment is video
and timing only.

## Crashes

A crash reaches Maple's `/errors` as an ordinary span: `Error` status, plus an OTel `exception`
event carrying `exception.type`, `.message` and `.stacktrace`. Nothing about the error pipeline is
iOS-specific, and nothing had to be added to it — the same contract the web SDK's errors arrive on.

```swift
options.reportCrashes = true   // the default
```

The source is **MetricKit**, not a signal handler or `NSSetUncaughtExceptionHandler`. This SDK ships
inside your app: installing a signal handler means running async-signal-unsafe code in a process
that is already dying, and taking a slot whatever crash reporter you already have wants too. The OS
captures the crash instead and hands it over on a later launch.

The cost is latency. A payload can arrive up to 24 hours after the crash, so this answers *what is
broken in this release*, not *what is broken right now*. Payloads are written to disk the moment
they arrive, because MetricKit delivers each one exactly once and a launch that drops one never
sees it again.

The crash span carries the session id of the run that **crashed**, so it resolves to the recording
recovered from that run — the seconds before the crash, in video. It also reports the `service.version`
that crashed rather than the one now running, which is usually the update that fixed it.

### Unsymbolicated, and what that costs

MetricKit gives binary names, UUIDs and text-segment offsets. It does not give function names: those
live in a dSYM that never leaves your build machine. So a frame reads

```
0   MyApp   0x104a2c1f0   +0x1d0f0
```

Maple groups those frames by binary, not by function, because the offset is rendered in hex and its
fingerprint deliberately redacts hex runs. That is coarser than a backend stack trace — but an
offset moves with any code change above it, so keying on it would split every crash into a fresh
issue on every build. Grouping by binary is stable across releases. Upload dSYMs and the same slot
fills with function names.

Non-fatal errors do not need any of this. Record one on the span you are already inside:

```swift
span.recordError(error)                                   // a caught Swift error
span.recordException(type: "PaymentDeclined", message: …) // or name it yourself
```

Both set `Error` status *and* add the event, because Maple needs the pair — an `exception` event on
an `Ok` span produces no error row at all.

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
xcodebuild test -scheme maple-swift-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`swift build` does not work — the package is UIKit-only, and SwiftPM builds for macOS by default.
Use an iOS Simulator destination. The scheme is `maple-swift-Package`, not `maple-swift`: the
package has several products now, and SwiftPM names the aggregate scheme accordingly.

The demo app is the real verification surface. Redaction correctness is a visual property; no unit
test substitutes for opening the MP4 and looking at it.

```bash
cd Examples/ReplayDemo && xcodegen generate
xcodebuild build -project ReplayDemo.xcodeproj -scheme ReplayDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

It has both a SwiftUI and a UIKit screen full of deliberate PII, a mask-preview toggle, mode and
quality switches, a button that fires `flush(trigger:)`, and a **Network** tab that makes real
requests and prints the trace id each one used.

That tab is the verification surface for tracing, for the same reason the PII screens are the one
for redaction: "the backend span is a child of the phone's span" is not visible anywhere on the
device. It is a property of what arrives at the warehouse, so the only way to check it is to fire a
request at a real instrumented backend and go look.

Point it at a gateway with environment variables rather than an edit-and-rebuild cycle:

```bash
SIMCTL_CHILD_MAPLE_ENDPOINT=http://localhost:3475 \
SIMCTL_CHILD_MAPLE_INGEST_KEY=MAPLE_TEST \
SIMCTL_CHILD_MAPLE_TRACE_TARGET=https://api.maple.dev/v2/services \
xcrun simctl launch booted dev.maple.ReplayDemo
```

`MAPLE_TRACE_TARGET` is the backend the Network tab calls; it defaults to the API sibling of
whatever ingest host is configured. Deliberately not a `/health` route — the API disables its
tracer for those, so a request there proves nothing about propagation.

`MAPLE_TEST` is the gateway's sentinel key: it authenticates, and everything sent under it is
accepted and discarded — useful for exercising the request path without a real key. Note the
gateway logs rejections but not successes, so a recording proxy in front of it is the only way to
watch the 200s.

## Not here yet

Playback and Android.

Known gaps in tracing, all deliberate:

- A **crash-recovered** `ended` row cannot carry that session's trace ids. The sink died with the
  process, and the row is written on the next launch.
- **Crash stacks are unsymbolicated** — no dSYM upload yet, so frames are binary + offset and
  grouping is by binary rather than by function.
- MetricKit delivers nothing on the **simulator**. Crash reporting needs a device.
- **Upload tasks with a body stream** are not traced (see above).
- `identify()` is not wired to spans yet: `user.id` is stamped by the browser SDK, and the mobile
  metadata row still sends the identity columns empty.
