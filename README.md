# DoorbellSDK

A Swift SDK for live video-doorbell streaming over **AWS Kinesis Video Streams
(KVS) WebRTC**. It handles signaling, ICE/DTLS, H.265 video decoding and
rendering, and two-way audio (Talk / Listen) with hardware echo cancellation and
automatic loudspeaker routing — you give it credentials and a view, it gives you
a live stream.

Everything media-related lives inside the SDK. Your app never touches WebRTC,
audio sessions, decoders, or routing — the entire integration is the
`DoorbellSDKClient` API described below.

There are two ways to use it:

| Flow | Use when | Entry point |
| --- | --- | --- |
| **A. CallKit call flow** | The doorbell *rings* the phone and the user answers a call | `prepareConnection` → `acceptCall` |
| **B. Direct live view** | The user opens a "View Live" screen from inside your app | `connectToStream` |

---

## Requirements

- iOS 13.0+
- Swift 5.9+
- A KVS signaling channel + temporary AWS credentials (see [Credentials](#credentials))

## Installation (Swift Package Manager)

In Xcode: **File ▸ Add Package Dependencies…** and enter the package URL, or add
it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CharanBlaze/DoorbellSDK.git", from: "1.0.2")
]
```

The SDK depends on **LiveKitWebRTC** (a WebRTC binary), which SPM resolves
automatically.

## Info.plist keys

| Key | Why |
| --- | --- |
| `NSMicrophoneUsageDescription` | Required. Used by **Talk**, and by the audio engine while **Listen** is on (see [Audio behavior](#audio-behavior)). |
| `NSLocalNetworkUsageDescription` | Required if the doorbell and phone can reach each other directly on the LAN (iOS 14+ local-network privacy). |
| `UIBackgroundModes` → `audio`, `voip` | Required for the CallKit flow (VoIP push + audio continuing in background). |

## Microphone permission

Request record permission **before** the user first enables Talk or Listen —
for example when your live/call screen appears:

```swift
AVAudioSession.sharedInstance().requestRecordPermission { granted in
    // Update your Talk button state accordingly.
}
```

Talk cannot work without it, and Listen uses the audio engine's capture path
(muted) for correct loudspeaker routing, so grant it up front for the best
experience.

## Initialize at launch

Call once at app launch. It pre-initializes WebRTC (SSL, codec factories) and
removes ~150 ms from the first connection:

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    DoorbellSDKClient.prewarm()
    return true
}
```

---

# Flow A — CallKit call flow (doorbell rings the phone)

The SDK is built around a **two-phase connect** so answering feels instant:

1. **`prepareConnection(...)`** — call the instant the call is signalled (from
   your VoIP push handler, when you report the call to CallKit). It performs
   every slow step — credential/ICE fetch, signaling WebSocket connect, local
   ICE gathering — but **holds the SDP offer**, so no media flows and the audio
   session is untouched (the user's music keeps playing, no mic indicator).
   You receive `.connected`, then `.prepared`.

2. **`acceptCall()`** — the user answered. Releases the held offer, the
   handshake completes, and you receive `.streamStarted` then
   `.firstFrameReceived`.

3. **`declineCall()`** — the user declined or the ring timed out. Full teardown.

> `acceptCall()` is safe to call **at any moment** — before `.prepared`, even
> before `prepareConnection` has run (e.g. credentials still loading). The SDK
> remembers the accept and applies it as soon as it can, so a fast "Answer" tap
> is never lost.

> Keep the pre-warm window short. ICE/TURN allocations go stale after a few
> minutes — if the call is never answered, call `declineCall()` on your ring
> timeout.

### Step-by-step

| When | Call |
| --- | --- |
| Incoming VoIP push → after `reportNewIncomingCall` | `prepareConnection(credentials:renderIn:onEvent:)` |
| `CXAnswerCallAction` | `setCallKitSessionOwnership(owned: true)` → `action.fulfill()` → `acceptCall()` → present your call screen |
| `provider(_:didActivate:)` | `startAudio()` |
| `.streamStarted` event | `setListen(enabled: true)` (recommended — visitor audible immediately) |
| User taps Talk | `setTalk(enabled: true/false)` |
| `CXEndCallAction`, call was **never accepted** | `setCallKitSessionOwnership(owned: false)` → `declineCall()` |
| Call screen dismissed after an accepted call | `disconnect()` |
| `provider(_:didDeactivate:)` | `stopAudio()` |
| `providerDidReset` | `setCallKitSessionOwnership(owned: false)` |

Three rules make CallKit audio reliable:

1. **Tell the SDK CallKit owns the audio session** with
   `setCallKitSessionOwnership(owned: true)` in `CXAnswerCallAction`, *before
   any media negotiates*. The SDK then primes the audio session category for
   you and waits for CallKit to activate the session — **do not call
   `AVAudioSession.setCategory` / `setActive` yourself anywhere in the call
   flow.**
2. **Forward CallKit's audio activation** with `startAudio()` /
   `stopAudio()` from `didActivate` / `didDeactivate`. `startAudio()` is safe
   even if the stream isn't connected yet — the SDK defers it internally and
   starts audio when the stream comes up.
3. **Release ownership on every exit path** — declined call, `didDeactivate`
   (via `stopAudio()`), and `providerDidReset`.

### Rendering during pre-warm

`prepareConnection(renderIn:)` needs a `UIView`, but your call screen doesn't
exist while the phone is still ringing. Keep a **stable container view** alive
for the whole call: pre-warm into it, then re-parent it into your call screen
when the user answers. Video is rendered into it whether the first frame
arrives before or after the screen appears.

### Full CallKit example

```swift
import CallKit
import UIKit
// import DoorbellSDK

final class CallController: NSObject, CXProviderDelegate {

    static let shared = CallController()

    private let provider: CXProvider
    private var currentCallID: UUID?
    private var didAccept = false

    /// Stable render target for the whole call (see note above).
    let videoContainer = UIView()

    /// Re-broadcast SDK events so your call screen can subscribe without
    /// re-registering the SDK's single event handler mid-call.
    var onStreamEvent: ((DoorbellEvent) -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // ── 1. Incoming call: report to CallKit, then PRE-WARM immediately ──
    func reportIncomingCall(named name: String) {
        let id = UUID()
        currentCallID = id
        didAccept = false

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = true

        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            guard error == nil else { return }
            self?.prewarm()
        }
    }

    private func prewarm() {
        // Fetch your KVS credentials however you like (your backend, Cognito…).
        fetchDoorbellCredentials { [weak self] credentials in
            guard let self, let credentials else { return }
            self.videoContainer.subviews.forEach { $0.removeFromSuperview() }
            DoorbellSDKClient.shared.prepareConnection(
                credentials: credentials,
                renderIn: self.videoContainer
            ) { [weak self] event in
                if case .streamStarted = event {
                    // Visitor audible the moment media flows — no extra tap.
                    DoorbellSDKClient.shared.setListen(enabled: true)
                }
                self?.onStreamEvent?(event)
            }
        }
    }

    // ── 2. User answered ─────────────────────────────────────────────
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // CallKit owns the audio session from here. The SDK primes the session
        // category itself — do NOT call AVAudioSession.setCategory.
        DoorbellSDKClient.shared.setCallKitSessionOwnership(owned: true)
        action.fulfill()
        didAccept = true

        // Release the pre-armed offer → media goes live.
        DoorbellSDKClient.shared.acceptCall()

        // Present your call UI and embed the SDK's render container.
        presentCallScreen(embedding: videoContainer)
    }

    // ── 3. CallKit audio session hooks ───────────────────────────────
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Safe even if signaling hasn't finished — the SDK defers internally.
        DoorbellSDKClient.shared.startAudio()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DoorbellSDKClient.shared.stopAudio()
    }

    // ── 4. Decline / end ─────────────────────────────────────────────
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        currentCallID = nil

        // Never accepted → tear down the pre-warmed connection here.
        // Accepted → your call screen owns teardown (disconnect() on dismiss);
        // disconnecting here would kill the live stream.
        if !didAccept {
            DoorbellSDKClient.shared.setCallKitSessionOwnership(owned: false)
            DoorbellSDKClient.shared.declineCall()
        }
        didAccept = false
    }

    func providerDidReset(_ provider: CXProvider) {
        DoorbellSDKClient.shared.setCallKitSessionOwnership(owned: false)
    }
}
```

Embedding the container in your call screen:

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

And in the call screen itself:

```swift
final class CallScreenVC: UIViewController {

    @IBOutlet private weak var videoView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()
        embedVideo(CallController.shared.videoContainer, into: videoView)
        CallController.shared.onStreamEvent = { [weak self] event in
            switch event {
            case .firstFrameReceived:              self?.hideLoadingSpinner()
            case .listenStateChanged(let enabled): self?.updateListenButton(enabled)
            case .talkStateChanged(let enabled):   self?.updateTalkButton(enabled)
            case .streamStopped:                   self?.showCallEndedUI()
            case .error(let e):                    self?.showError(e.message)
            default: break
            }
        }
    }

    @IBAction private func talkTapped(_ sender: UIButton) {
        DoorbellSDKClient.shared.setTalk(enabled: !sender.isSelected)
    }

    @IBAction private func listenTapped(_ sender: UIButton) {
        DoorbellSDKClient.shared.setListen(enabled: !sender.isSelected)
    }

    @IBAction private func hangUpTapped(_ sender: UIButton) {
        CallController.shared.onStreamEvent = nil
        DoorbellSDKClient.shared.disconnect()   // CallKit end + didDeactivate → stopAudio()
        dismiss(animated: true)
    }
}
```

---

# Flow B — Direct live view (no call, no CallKit)

For a "View Live" button inside your app, use `connectToStream(...)`. It
connects and starts media immediately — no accept step, no CallKit, no session
ownership calls. `setListen` / `setTalk` are all the audio API you need.

```swift
final class LiveViewVC: UIViewController {

    @IBOutlet private weak var videoView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()

        fetchDoorbellCredentials { [weak self] credentials in
            guard let self, let credentials else { return }
            DoorbellSDKClient.shared.connectToStream(
                credentials: credentials,
                renderIn: self.videoView
            ) { [weak self] event in
                switch event {
                case .streamStarted:
                    // Optional: hear the doorbell without an extra tap.
                    DoorbellSDKClient.shared.setListen(enabled: true)
                case .firstFrameReceived:
                    self?.hideLoadingSpinner()
                case .streamStopped:
                    self?.showReconnectUI()
                case .error(let e):
                    self?.showError(e.message)
                default: break
                }
            }
        }
    }

    @IBAction private func talkTapped(_ sender: UIButton) {
        DoorbellSDKClient.shared.setTalk(enabled: !sender.isSelected)
    }

    @IBAction private func listenTapped(_ sender: UIButton) {
        DoorbellSDKClient.shared.setListen(enabled: !sender.isSelected)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DoorbellSDKClient.shared.disconnect()
    }
}
```

Notes for this flow:

- **Do not** call `startAudio()` / `stopAudio()` / `setCallKitSessionOwnership`
  — those are CallKit hooks only. The SDK manages the audio session itself here.
- You can also drive this flow with the two-phase API — call
  `prepareConnection(...)` then `acceptCall()` — useful if you want the SDK to
  warm up while your screen is still laying out.
- Call `disconnect()` when the screen goes away. Connecting again while
  connected is safe (`connectToStream` tears the old session down first).

---

# Audio behavior

```swift
DoorbellSDKClient.shared.setListen(enabled: true)  // hear the doorbell
DoorbellSDKClient.shared.setTalk(enabled: true)    // send mic audio
```

- Both default **off** on every new connection; enable them explicitly (for
  calls we recommend enabling Listen on `.streamStarted`, as shown above).
- Each call emits `.listenStateChanged` / `.talkStateChanged` so your buttons
  can bind to events rather than local state.
- **Loudspeaker routing is automatic.** While Listen is on, incoming audio
  plays through the phone's loud (bottom) speaker — in both flows — and moves
  to headphones / Bluetooth automatically when connected. You never call
  `overrideOutputAudioPort` or touch `AVAudioSession`.
- **Echo cancellation is automatic.** Received audio and mic capture share one
  voice-processed audio engine, so the doorbell never hears its own audio back.
  Full-duplex (Talk + Listen together) works without feedback.
- **Mic indicator during Listen.** While Listen is enabled the orange
  microphone indicator may be visible even with Talk off. The capture path runs
  **hardware-muted** for echo cancellation and loudspeaker routing — **no audio
  leaves the device until Talk is enabled**. This matches how system video-call
  apps behave.
- Talk is independent of Listen — use it as push-to-talk
  (`setTalk(enabled: true)` on press, `false` on release) or as a toggle.

---

# Snapshot, recording, fullscreen

```swift
// Still image of the current frame (requires an active stream).
DoorbellSDKClient.shared.captureSnapshot { image in
    guard let image else { return }
    // save / display
}

// Record the incoming stream to a local .mp4.
DoorbellSDKClient.shared.startRecording(fileName: "visitor.mp4")
DoorbellSDKClient.shared.stopRecording { url in
    guard let url else { return }   // nil on failure
    // move / share the file
}
```

For a fullscreen presentation, re-parent the SDK's live renderer view instead
of reconnecting:

```swift
if let renderer = DoorbellSDKClient.shared.remoteVideoView {
    embedVideo(renderer, into: fullscreenContainer)   // same helper as above
}
```

---

# Teardown

```swift
DoorbellSDKClient.shared.disconnect()   // stop stream, release everything
```

`declineCall()` is an alias for `disconnect()` that reads better at a call
site. After `disconnect()` the client is reusable — the next
`connectToStream` / `prepareConnection` starts a fresh session.

---

# Credentials

```swift
let credentials = DoorbellCredentials.aws(
    accessKey:    "AKIA...",
    secretKey:    "...",
    sessionToken: "...",   // temporary STS/Cognito token; "" for permanent creds
    channelARN:   "arn:aws:kinesisvideo:us-east-1:123456789012:channel/my-doorbell/1700000000000",
    region:       "us-east-1"   // must match the CHANNEL's region
)
```

> `region` must be the KVS **channel's** region, which may differ from the
> region your IAM credentials were issued in.

A `.custom(serverURL:headers:)` case is available for a generic WebSocket
signaling server. `.azure` is reserved for future support.

---

# Events (`DoorbellEvent`)

Delivered on the **main thread** via the `onEvent` closure you pass to
`connectToStream` / `prepareConnection`.

| Event | Meaning |
| --- | --- |
| `.connected` | Signaling WebSocket connected. |
| `.prepared` | Two-phase only: warm-up complete, offer held. Call `acceptCall()` or `declineCall()`. |
| `.streamStarted` | WebRTC peer connected (SDP + ICE done). Good moment to enable Listen. |
| `.firstFrameReceived` | First video frame decoded & rendered. Hide your spinner. |
| `.streamStopped` | Stream ended (cleanly or by remote). |
| `.talkStateChanged(isEnabled:)` | Talk (mic) state changed. |
| `.listenStateChanged(isEnabled:)` | Listen (speaker) state changed. |
| `.snapshotCaptured(UIImage)` | Snapshot ready. |
| `.recordingStarted` | Recording began. |
| `.recordingSaved(URL)` | Recording written to this file. |
| `.recordingSaveFailed` | Recording could not be saved. |
| `.error(DoorbellError)` | See `error.message`. |

### Errors (`DoorbellError`)

Every case exposes a human-readable `.message`. Categories: invalid credentials
(`.invalidCredentials`, `.missingChannelARN`), connection setup
(`.failedToGetEndpoints`, `.failedToSignURL`, `.failedToGetICEServers`,
`.signalingConnectionFailed`), WebRTC negotiation (`.webRTCOfferFailed`,
`.webRTCAnswerFailed`, `.webRTCConnectionFailed`), and feature guards
(`.notConnected`, `.streamNotActive`).

---

# State flags

```swift
DoorbellSDKClient.shared.isConnected   // signaling connected
DoorbellSDKClient.shared.isStreaming   // media flowing
DoorbellSDKClient.shared.isPrepared    // warmed up, awaiting accept/decline
DoorbellSDKClient.version              // SDK version string
```

---

# API summary

| Method | Purpose | Flow |
| --- | --- | --- |
| `prewarm()` *(static)* | Pre-init WebRTC at app launch. | Both |
| `prepareConnection(credentials:renderIn:isMaster:clientId:onEvent:)` | Phase 1 — warm up, hold the offer. | A |
| `acceptCall()` | Phase 2 — release the offer, go live. Safe at any time. | A |
| `declineCall()` | Phase 2 — tear down (alias of `disconnect`). | A |
| `setCallKitSessionOwnership(owned:)` | CallKit owns the audio session (answer) / released (decline, reset). Primes the session category for you. | A |
| `startAudio()` / `stopAudio()` | Forward CallKit `didActivate` / `didDeactivate`. | A |
| `connectToStream(credentials:renderIn:isMaster:clientId:onEvent:)` | One-shot connect, media starts immediately. | B |
| `setListen(enabled:)` | Hear the doorbell (loudspeaker, automatic routing). | Both |
| `setTalk(enabled:)` | Send mic audio (push-to-talk or toggle). | Both |
| `captureSnapshot(completion:)` | Still image of the current frame. | Both |
| `startRecording(fileName:)` / `stopRecording(completion:)` | Record incoming stream to .mp4. | Both |
| `remoteVideoView` | The SDK's live renderer view, for fullscreen re-parenting. | Both |
| `disconnect()` | Stop & release everything. | Both |
| `isConnected` / `isStreaming` / `isPrepared` | State flags. | Both |

---

# Do / Don't

**Do**

- Call `prewarm()` once at launch.
- Pre-warm (`prepareConnection`) the moment a call is signalled; accept with
  `acceptCall()` when answered.
- Enable Listen on `.streamStarted` for calls so the visitor is heard
  immediately.
- Request microphone permission before the first Talk/Listen use.
- Call `disconnect()` (or `declineCall()`) on every exit path.

**Don't**

- Don't call `AVAudioSession.setCategory` / `setActive` /
  `overrideOutputAudioPort` anywhere in either flow — the SDK owns the audio
  session end to end. (In the CallKit flow, `setCallKitSessionOwnership(owned:
  true)` primes the session for you.)
- Don't call `startAudio()` / `stopAudio()` / `setCallKitSessionOwnership`
  outside the CallKit flow.
- Don't play SDK audio through your own player, and don't run another
  `AVAudioEngine` / player during a stream — it will break echo cancellation.
- Don't leave a pre-warmed connection hanging — decline on ring timeout.
- Don't re-register the SDK event handler mid-call; relay events to your UI
  through your own closure (see `onStreamEvent` in the example).

---

# Threading

Call the SDK from the **main thread**. All events are delivered on the main
thread, so you can update UI directly inside the `onEvent` closure.
