# DoorbellSDK — iOS Integration Guide

**Version 1.1.0 · Swift Package · AWS Kinesis Video Streams (KVS) WebRTC**

A lightweight Swift SDK for live video-doorbell streaming. It handles everything
between AWS credentials and a live picture on screen: signaling, ICE/DTLS,
**H.265** hardware video decode, and two-way audio (**Talk / Listen**) with
hardware echo cancellation. You give it credentials and a `UIView`; it gives you
a live stream.

Its headline feature is a **two-phase connect** engineered for calls: **pre-warm**
the connection the instant a call comes in (while the phone is still ringing),
then **accept** to go live the moment the user answers — so answering feels
*instant* instead of connecting from scratch.

> **Read this first if you only read one section:** [§4 — The performance model
> (prewarm & two-phase connect)](#4-the-performance-model--prewarm--two-phase-connect).
> It is the whole reason this SDK exists and is where all the speed comes from.

---

## Table of contents

1. [Requirements](#1-requirements)
2. [Installation (Swift Package Manager)](#2-installation-swift-package-manager)
3. [Info.plist keys](#3-infoplist-keys)
4. [The performance model — prewarm & two-phase connect](#4-the-performance-model--prewarm--two-phase-connect) ⭐
6. [Full CallKit integration (recommended)](#6-full-callkit-integration-recommended)
7. [Audio controls (Talk / Listen)](#7-audio-controls-talk--listen)
9. [Teardown](#9-teardown)
10. [Credentials](#10-credentials)
11. [Events & errors](#11-events--errors)
12. [State flags](#12-state-flags)
13. [How a connection is built (internals)](#13-how-a-connection-is-built-internals)
14. [Resilience — how the SDK survives a flaky network](#14-resilience--how-the-sdk-survives-a-flaky-network)
15. [Full API reference](#15-full-api-reference)
16. [Threading rules](#16-threading-rules)
17. [Integration checklist & troubleshooting](#17-integration-checklist--troubleshooting)

---

## 1. Requirements

| | |
| --- | --- |
| **iOS** | 14.0 or later |
| **Swift** | 5.7+ (Xcode 14+) |
| **Backend** | A KVS signaling channel + AWS credentials scoped to it (see [§10](#10-credentials)) |
| **Video codec** | The doorbell streams **H.265 (HEVC)**. All 64-bit iPhones/iPads since the iPhone 7 (A10, iOS 11+) decode HEVC in hardware, so every iOS 14 device is covered. |

The single public class you interact with is **`DoorbellSDKClient`** (a shared
singleton). Everything else in the package is internal.

---

## 2. Installation (Swift Package Manager)

In Xcode: **File ▸ Add Package Dependencies…**, paste the package URL, and add
the **DoorbellSDK** product to your app target. Or, in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://your-git-host/DoorbellSDK.git", from: "1.0.2")
]
```

Then import it wherever you use it:

```swift
import DoorbellSDK
```

> **One transitive dependency.** The SDK depends on **LiveKitWebRTC** (a
> pre-built WebRTC binary xcframework, `webrtc-xcframework` ≥ `144.7559.11`).
> SPM resolves and links it automatically — you do **not** add it yourself, and
> you do **not** need the AWS SDK for Swift. All AWS signing (SigV4) is done
> inside DoorbellSDK with `URLSession` + `CommonCrypto`, so the footprint stays
> small.

---

## 3. Info.plist keys

| Key | Why you need it |
| --- | --- |
| `NSMicrophoneUsageDescription` | Required for **Talk** (sending mic audio). Without it, the mic/audio path fails silently. |
| `NSLocalNetworkUsageDescription` | Required when the doorbell and phone can reach each other directly on the same Wi-Fi (iOS 14+ local-network privacy). This is what enables the fast **LAN-direct** path — see [§4](#4-the-performance-model--prewarm--two-phase-connect). |
| `UIBackgroundModes` → `audio`, `voip` | Only if the call / talkback must keep running when the app is backgrounded. **Recommended for CallKit.** |

---

## 4. The performance model — prewarm & two-phase connect

This is the core of the SDK. A cold WebRTC connect to KVS is slow — it is several
serial network round-trips plus a one-time SSL initialization. If you wait until
the user taps **Answer** to start all of that, the user stares at a black screen
for a second or more. DoorbellSDK's job is to make that time *disappear* by doing
the slow work **before** the user answers, and by **reusing** everything that can
safely be reused.

There are five independent optimizations. They stack.

### 4.1 — `prewarm()` at app launch (saves ~150 ms, once)

The very first WebRTC connection in a process pays a one-time cost to initialize
BoringSSL and build the peer-connection factory (~150 ms). Pay it at launch,
off the critical path, so the first real connect never sees it:

```swift
import DoorbellSDK

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [...]?) -> Bool {
    DoorbellSDKClient.prewarm()      // initializes SSL + logs codec capability
    return true
}
```

What it does under the hood:

- Calls `LKRTCInitializeSSL()` **exactly once** and remembers it — SSL then
  stays initialized for the entire process lifetime. It is deliberately **not**
  torn down when a stream stops, so every subsequent connect and reconnect
  reuses it for free.
- Logs the device's codec capability once, so you can confirm in the console
  that **H.265 decode is supported** on the build/device.

`prewarm()` is safe to call multiple times (subsequent calls are no-ops) and is
cheap. Call it once at launch.

### 4.2 — Two-phase connect: `prepareConnection()` → `acceptCall()` (hides the *entire* connect behind the ring)

This is the big one. Instead of one blocking "connect" call, the connect is split
into a **warm-up phase** and a **go-live phase**:

**Phase 1 — `prepareConnection(...)`** — call this the instant a call is
signalled (from your PushKit/VoIP handler, or when the ringing screen appears).
It runs **every slow step** of the connection:

- fetches (or reuses) the KVS signaling endpoints,
- fetches the TURN/ICE servers and signs the WebSocket URL **in parallel**,
- opens the signaling WebSocket,
- creates the peer connection and **starts local ICE candidate gathering**,

…but it deliberately **holds back the SDP offer**. Because the offer is never
sent, the doorbell never answers, so **no audio or video flows** and — critically
— **the audio session is left completely untouched**: the user's music keeps
playing and no microphone indicator lights up while the phone is merely ringing.

You receive `.connected` when the socket opens, then `.prepared` when warm-up is
complete and the offer is armed and waiting.

**Phase 2 — `acceptCall()`** — the user tapped Answer. This releases the
pre-armed offer, the handshake completes against an already-open socket with ICE
already gathered, and media goes live almost immediately. You then receive
`.streamStarted` and `.firstFrameReceived`.

**Phase 2 (alternative) — `declineCall()`** — the user declined or the call
timed out. Full teardown, everything released.

```
  Call rings          User answers
      │                    │
      ▼                    ▼
  prepareConnection()  acceptCall()
      │                    │
      ├─ fetch endpoints   └─ release the held offer ──▶ answer ──▶ media LIVE
      ├─ fetch ICE + sign WSS   (socket already open, ICE already gathered)
      ├─ open WebSocket
      ├─ gather ICE
      └─ ARM offer (hold) ──▶ .prepared
```

> **A fast "Answer" tap is never lost.** `acceptCall()` is safe to call **even
> before `.prepared` arrives**. If the socket is still connecting, the SDK
> remembers the accept and sends the offer the moment the socket opens. It is
> even safe to call `acceptCall()` *before* `prepareConnection()` has finished
> fetching credentials in the background — the accept is remembered and applied
> automatically when warm-up completes.

> **Keep the pre-warm window short.** ICE / TURN allocations go stale after a few
> minutes. If a call is never answered, call `declineCall()` (e.g. on your
> ring-timeout) so nothing lingers.

### 4.3 — Endpoint cache (saves ~396 ms on every reconnect)

The first step of any KVS connect is `GetSignalingChannelEndpoint`, a ~396 ms
round-trip that returns the channel's WSS + HTTPS endpoints. Those endpoints are
**stable** for the life of the channel (they only change if the channel is
deleted and recreated), so the SDK caches them **process-wide**, keyed by
`channelARN + role + region`, with a 5-minute TTL.

The result: the **second and subsequent** connects to the same channel — a
reconnect after a network blip, re-opening the live view, the next call within
five minutes — **skip the endpoint round-trip entirely**.

This is done safely:

- Only the **stable, non-secret** endpoints are cached. The channel ARN already
  scopes them to your account.
- Everything that actually **expires is always fetched fresh** on every connect:
  the SigV4-signed WSS URL and the TURN credentials. Nothing that can go stale is
  ever reused.
- The cache **self-heals**: any startup or pre-connect failure invalidates the
  entry (in case the channel was recreated), and every entry expires after 5
  minutes regardless.

### 4.4 — Parallel fetch + pre-armed offer (collapses serial round-trips)

Inside warm-up, the two independent network operations — **fetching the ICE/TURN
servers** and **signing the WebSocket URL** — run **concurrently** rather than
one after the other.

At the same time, the SDK **pre-arms the SDP offer**: it creates the offer and
sets the local description *while the WebSocket is still connecting*, which kicks
off **local ICE candidate gathering in parallel** with the handshake. A
pre-gathered ICE candidate pool (`iceCandidatePoolSize = 10`) means candidates
are ready and waiting rather than being gathered on demand. By the time the
socket is open and the user has answered, ICE is already well underway.

### 4.5 — Smart ICE candidate delivery + LAN-direct path (shaves seconds off "checking")

Two more optimizations get the first frame on screen sooner:

- **Prioritized candidate delivery.** Local ICE candidates are sent over the
  signaling channel through a small throttle queue that **pushes RELAY and UDP
  candidates to the front of the line**. The winning path is therefore offered to
  the doorbell first. A 10 ms spacing between sends prevents the doorbell's
  IoT-grade WebSocket buffer from overflowing, while still beating the doorbell's
  internal candidate timer.

- **LAN-direct when possible.** The ICE transport policy is `.all`, which allows
  host (LAN) candidates. When the phone and doorbell are on the **same Wi-Fi**,
  WebRTC can nominate a **direct sub-10 ms path** instead of relaying every packet
  through an AWS TURN server — lower latency and lower AWS cost. It transparently
  falls back to STUN/TURN on networks that require it, so there is no regression
  on cellular or segmented networks. *(This is why `NSLocalNetworkUsageDescription`
  matters — see [§3](#3-infoplist-keys).)*

### 4.6 — Putting it together

| Stage | Cold, naïve connect | With DoorbellSDK |
| --- | --- | --- |
| SSL init (~150 ms) | On first connect, blocking | Paid at launch via `prewarm()` |
| `GetSignalingChannelEndpoint` (~396 ms) | Every connect | Skipped on reconnect (endpoint cache) |
| ICE fetch + WSS signing | Serial | **Parallel** |
| ICE gathering | After socket opens | **Started during** warm-up (pre-armed offer) |
| Endpoint→answer round-trips | All happen *after* the user taps Answer | All happen *while the phone rings* |
| Perceived time to first frame after "Answer" | Full cold connect | ≈ one SDP answer + ICE nomination |

The user experience: **the connect happens during the ring, and answering just
lifts a curtain on a stream that is already there.**

---

## 6. Full CallKit integration (recommended)

This is the intended production flow for an incoming-doorbell **call**. It wires
the two-phase connect into CallKit so answering is instant.

### 6.1 — The stable render container

`prepareConnection(renderIn:)` needs a `UIView` to render into — but your call
screen may not exist yet at pre-warm time. The pattern: keep **one stable
container view** alive for the whole call, pre-warm into it, then re-parent it
into the call screen when the user answers. That way the frame is visible whether
pre-warm finished before or after the screen appeared.

```swift
/// A container the SDK renders into for the whole call. Created up front and
/// re-parented into the call screen on accept.
let videoContainer = UIView()
```

### 6.2 — The `CXProviderDelegate`

```swift
import CallKit
import AVFoundation
import UIKit
import DoorbellSDK

final class CallController: NSObject, CXProviderDelegate {

    static let shared = CallController()

    private let provider: CXProvider
    private var currentCallID: UUID?
    private var didAccept = false

    /// Stable render target for the whole call (see §6.1).
    let videoContainer = UIView()

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // ── Incoming call ──────────────────────────────────────────────
    // Call from your VoIP / PushKit handler. Report to CallKit, then
    // PRE-WARM immediately so answering is instant.
    func reportIncomingCall(named name: String) {
        let id = UUID()
        currentCallID = id
        didAccept = false

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = true

        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            guard error == nil else { return }
            self?.prewarm()                       // ← Phase 1 starts while ringing
        }
    }

    private func prewarm() {
        // Fetch your KVS credentials however you like (your backend, Cognito…).
        fetchDoorbellCredentials { [weak self] credentials in
            guard let self, let credentials else { return }
            DoorbellSDKClient.shared.prepareConnection(
                credentials: credentials,
                renderIn: self.videoContainer
            ) { event in
                switch event {
                case .connected:          print("Signaling connected")
                case .prepared:           print("Warm-up complete — ready to accept")
                case .streamStarted:      print("Media live")
                case .firstFrameReceived: print("Video rendering")
                case .error(let e):       print("SDK error: \(e.message)")
                default: break
                }
            }
        }
    }

    // ── User answered ──────────────────────────────────────────────
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Prime the audio category early; let CallKit activate the session.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        action.fulfill()
        didAccept = true

        DoorbellSDKClient.shared.acceptCall()     // ← Phase 2: release the offer, go live

        // Present your call UI and embed the SDK's render container.
        presentCallScreen(embedding: videoContainer)
    }

    // ── User declined / call ended ─────────────────────────────────
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        currentCallID = nil

        // If it was NEVER accepted, tear down the connection we pre-warmed while
        // ringing. If it WAS accepted, your call screen owns teardown — don't
        // disconnect here or you'll kill the live stream.
        if !didAccept {
            DoorbellSDKClient.shared.declineCall()
        }
        didAccept = false
    }

    // ── CallKit audio session ──────────────────────────────────────
    // Let CallKit own activation; just tell the SDK when to start/stop audio.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DoorbellSDKClient.shared.startAudio()
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DoorbellSDKClient.shared.stopAudio()
    }
    func providerDidReset(_ provider: CXProvider) {
        DoorbellSDKClient.shared.disconnect()
    }
}
```

### 6.3 — Embedding the container in your call screen

```swift
func embedVideo(_ container: UIView, into videoView: UIView) {
    container.removeFromSuperview()
    container.translatesAutoresizingMaskIntoConstraints = false
    videoView.addSubview(container)
    NSLayoutConstraint.activate([
        container.topAnchor.constraint(equalTo: videoView.topAnchor),
        container.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),
        container.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
    ])
}
```

> **Auto Layout gotcha:** the render container must have a non-zero width by the
> time video attaches. If it is zero, the SDK logs a warning
> (`video container width is 0; check Auto Layout`) and nothing renders. Give the
> container real constraints.

---

## 7. Audio controls (Talk / Listen)

Both default **off** — the user explicitly enables them.

```swift
DoorbellSDKClient.shared.setListen(enabled: true)  // hear the doorbell (speaker)
DoorbellSDKClient.shared.setTalk(enabled: true)    // send mic audio (push-to-talk)
```

Received audio and captured mic audio share **one** audio engine, so Apple's
voice-processing unit cancels echo automatically — no extra setup, no echo of the
visitor's voice back to them.

**About `startAudio()` / `stopAudio()`:** these are **for CallKit only**. Call
them from `didActivate` / `didDeactivate` (as in [§6.2](#62--the-cxproviderdelegate))
so CallKit owns audio-session activation. Outside CallKit you do **not** need
them — `setListen` / `setTalk` are enough on their own.

---

## 9. Teardown

```swift
DoorbellSDKClient.shared.disconnect()   // stop stream, release everything
```

`disconnect()` closes the signaling socket, tears down the peer connection,
stops any recording, and releases the renderer. `declineCall()` is an **alias**
for `disconnect()` that simply reads better at a call site. (SSL stays
initialized for the process — that is intentional, so the next connect is fast.)

---

## 10. Credentials

You supply your own AWS credentials — **no vendor credentials are baked into the
SDK**. Fetch temporary STS/Cognito credentials from your backend and pass them in:

```swift
let credentials = DoorbellCredentials.aws(
    accessKey:    "AKIA...",
    secretKey:    "...",
    sessionToken: "...",   // temporary STS/Cognito token; pass "" for permanent creds
    channelARN:   "arn:aws:kinesisvideo:us-east-1:123456789012:channel/my-doorbell/1700000000000",
    region:       "us-east-1"   // must match the CHANNEL's region
)
```

> **`region` must be the KVS *channel's* region**, which can differ from the
> region your IAM credentials were issued in.

**Security recommendation:** issue **short-lived, least-privilege** credentials
scoped to the one channel (via Cognito or an STS `AssumeRole`). Never ship
long-lived IAM keys inside the app.

Two other credential cases exist on the enum:

- **`.custom(serverURL:headers:)`** — connect to a generic WebSocket signaling
  server instead of KVS.
- **`.azure(connectionString:region:)`** — reserved for future support (not yet
  implemented; using it returns an `unsupportedCloudProvider` error).

---

## 11. Events & errors

All events are delivered on the **main thread** via your `onEvent` closure, so
you can update UI directly inside it.

### `DoorbellEvent`

| Event | Meaning |
| --- | --- |
| `.connected` | Signaling WebSocket connected. |
| `.prepared` | **Two-phase only:** warm-up complete, offer pre-armed & held. Call `acceptCall()` or `declineCall()`. |
| `.streamStarted` | WebRTC peer connected (SDP + ICE complete). |
| `.firstFrameReceived` | First video frame decoded & rendered — hide your spinner here. |
| `.streamStopped` | Stream ended (cleanly or by remote). |
| `.talkStateChanged(isEnabled:)` | Mic (Talk) state changed. |
| `.listenStateChanged(isEnabled:)` | Speaker (Listen) state changed. |
| `.snapshotCaptured(UIImage)` | A snapshot is ready. |
| `.recordingStarted` | Recording began. |
| `.recordingSaved(URL)` | Recording written to this file URL. |
| `.recordingSaveFailed` | Recording could not be saved. |
| `.error(DoorbellError)` | Something failed — read `error.message`. |

### `DoorbellError`

Every case exposes a human-readable `.message`. Categories:

| Category | Cases |
| --- | --- |
| Credentials / config | `.invalidCredentials`, `.missingChannelARN` |
| Cloud / network | `.failedToGetEndpoints`, `.failedToSignURL`, `.failedToGetICEServers`, `.signalingConnectionFailed` |
| WebRTC | `.webRTCOfferFailed`, `.webRTCAnswerFailed`, `.webRTCConnectionFailed` |
| Feature guards | `.notConnected`, `.streamNotActive` |
| Provider | `.unsupportedCloudProvider` |
| Generic | `.unknown` |

```swift
case .error(let e):
    print(e.message)   // e.g. "Invalid credentials: Missing AWS credentials or channelARN"
```

---

## 12. State flags

Read-only properties you can poll at any time:

```swift
DoorbellSDKClient.shared.isConnected    // signaling WebSocket connected
DoorbellSDKClient.shared.isStreaming    // media is flowing
DoorbellSDKClient.shared.isPrepared     // warmed up, awaiting accept / decline
DoorbellSDKClient.shared.remoteVideoView // the SDK's live video view (for fullscreen handoff)
DoorbellSDKClient.version               // "1.0.2"
```

---

## 13. How a connection is built (internals)

You do not need this to integrate, but it helps when reading the SDK's console
logs (every step is time-stamped and tagged `[DoorbellSDK] [+NNNms]`). The AWS
viewer path runs these steps:

| Step | What happens |
| --- | --- |
| **1** | `GetSignalingChannelEndpoint` → WSS + HTTPS endpoints *(reused from cache on reconnect)* |
| **2** | Fetch ICE/TURN servers **and** sign the WSS URL — **in parallel** |
| **3** | Create the peer connection **with** the fetched ICE servers (so TURN relay candidates are generated) |
| **4** | **Pre-arm** the SDP offer → local ICE gathering begins now |
| **5** | Connect the signaling WebSocket |
| **6** | On accept: send the pre-armed offer to the doorbell |
| **7** | Receive the SDP answer → `setRemoteDescription` |
| **8** | ICE candidate exchange (continual gathering, prioritized delivery) |
| **9** | ICE `connected`/`completed` → **`.streamStarted`** |
| **10** | First H.265 frame decoded & rendered → **`.firstFrameReceived`** |

In two-phase mode, steps 1–5 all happen during `prepareConnection()` (while the
phone rings) and the flow pauses at the pre-armed offer until `acceptCall()`
triggers step 6.

---

## 14. Resilience — how the SDK survives a flaky network

The SDK is deliberately forgiving of the doorbell's IoT-grade networking:

- **ICE-failure grace period (5 s).** When ICE reports `failed`/`disconnected`,
  the SDK does **not** tear down immediately — doorbells frequently trickle their
  winning relay/host candidate late, and libwebrtc can recover the pair once it
  arrives. Teardown only fires if the connection has not recovered after 5 s.
- **Frame watchdog (5 s).** After the first frame, if decoded frames stop
  arriving for 5 s the stream is declared dead and you get `.streamStopped`, so a
  silently frozen picture doesn't linger.
- **Self-healing endpoint cache.** A stale cached endpoint (channel recreated)
  is detected on the next failure and dropped automatically, so the following
  connect re-fetches cleanly.
- **Duplicate-disconnect guard.** Multiple failure paths (socket close + ICE
  failure) can't fire `.streamStopped` twice.

None of this needs configuration — it is on by default.

---

## 15. Full API reference

All calls go through the shared singleton `DoorbellSDKClient.shared` (except the
static `prewarm()` and `version`).

| Member | Purpose |
| --- | --- |
| `static func prewarm()` | Pre-init WebRTC SSL + factory at launch. Saves ~150 ms on first connect. |
| `static let version: String` | SDK version string (`"1.0.2"`). |
| `prepareConnection(credentials:renderIn:isMaster:clientId:onEvent:)` | **Phase 1** — warm up the whole connection, hold the offer. |
| `acceptCall()` | **Phase 2** — release the held offer, go live. Safe to call before `.prepared`. |
| `declineCall()` | **Phase 2** — tear everything down (alias for `disconnect()`). |
| `connectToStream(credentials:renderIn:isMaster:clientId:onEvent:)` | One-shot connect (no accept step) — starts media immediately. |
| `setListen(enabled:)` | Enable/disable hearing the doorbell (speaker). |
| `setTalk(enabled:)` | Enable/disable sending mic audio (push-to-talk). |
| `startAudio()` / `stopAudio()` | **CallKit only** — audio-session activation hooks. |
| `captureSnapshot(completion:)` | Grab the current frame as a `UIImage`. |
| `startRecording(fileName:)` | Begin recording the incoming stream to `.mp4`. |
| `stopRecording(completion:)` | Stop recording; returns the saved file `URL` (or `nil`). |
| `disconnect()` | Stop the stream and release all resources. |
| `isConnected` / `isStreaming` / `isPrepared` | Read-only state flags. |
| `remoteVideoView` | The SDK's live video `UIView`, for fullscreen handoff. |

**Optional parameters on the two connect methods:**

- `isMaster: Bool = false` — leave `false`. `false` = viewer (your app *receives*
  the stream), which is the doorbell use case. `true` = master, rarely needed on
  mobile.
- `clientId: String? = nil` — a custom client id. A UUID is auto-generated if
  you pass `nil`.

---

## 16. Threading rules

- **Call the SDK from the main thread.**
- **All events arrive on the main thread**, so you can touch UIKit directly
  inside the `onEvent` closure — no dispatching back to main needed.

---

## 17. Integration checklist & troubleshooting

**Checklist**

- [ ] Added the **DoorbellSDK** package to your app target (LiveKitWebRTC
      resolves automatically).
- [ ] Called `DoorbellSDKClient.prewarm()` in `didFinishLaunchingWithOptions`.
- [ ] Added `NSMicrophoneUsageDescription` and `NSLocalNetworkUsageDescription`
      to Info.plist (and `UIBackgroundModes` if using CallKit in background).
- [ ] Fetch **short-lived** AWS credentials from your backend; `region` matches
      the **channel's** region.
- [ ] Render into a container view that has **non-zero** Auto Layout constraints.
- [ ] For calls: `prepareConnection()` on ring, `acceptCall()` on answer,
      `declineCall()` on decline/timeout.

**Troubleshooting**

| Symptom | Likely cause / fix |
| --- | --- |
| Black screen, no `.firstFrameReceived` | Render container has zero width (check Auto Layout); or H.265 unsupported on the device (check the codec-capability log from `prewarm()`). |
| `.error` with "Invalid credentials" / "Missing AWS credentials" | Empty `accessKey`/`secretKey`/`channelARN`, or `region` doesn't match the channel. |
| `.error` fetching endpoints / signing URL | Credentials lack KVS permissions for the channel, or the session token expired. |
| Connect feels slow every time | You aren't reusing the process — make sure `prewarm()` runs at launch and you connect to the **same** channel within the cache window to benefit from the endpoint cache. |
| No audio from the doorbell | Call `setListen(enabled: true)`; under CallKit make sure `startAudio()` is wired to `didActivate`. |
| Talk doesn't work | Missing `NSMicrophoneUsageDescription`, or `setTalk(enabled:)` not called. |
| Stream drops on a brief blip | Expected to *recover* — the SDK holds a 5 s grace period. Only a genuine >5 s outage fires `.streamStopped`. |

---

*DoorbellSDK v1.0.2 — AWS KVS WebRTC · H.265 · two-way audio. Questions on
integration? Contact your SDK provider.*
