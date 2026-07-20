# DoorbellSDK

The iOS SDK for the B.One Video Doorbell. One package, **three clients** — each
owning one stage of the doorbell experience:

| Client | What it does | Docs |
| --- | --- | --- |
| **`DoorbellOnboardingSDK`** | BLE setup: scan, connect, provision WiFi credentials — and fetch the local **RTSP URL** in hotspot mode. | [Part 1](#part-1--ble-onboarding-doorbellonboardingsdk) |
| **`DoorbellSDKClient`** | Cloud live streaming over **AWS KVS WebRTC** — CallKit calls, in-app live view, two-way audio, pinch-to-zoom, snapshot, recording. | [Part 2](#part-2--cloud-live-streaming-doorbellsdkclient) |
| **`DoorbellLocalStreamClient`** | Plays the doorbell's **local RTSP stream** over the LAN — no cloud, no AWS credentials. | [Part 3](#part-3--local-rtsp-streaming-doorbelllocalstreamclient) |

A typical integration touches them in that order: onboard the device over BLE
(Part 1), then watch it from anywhere via the cloud (Part 2) — or watch it
directly on the local network (Part 1's *local stream* flow fetches the RTSP
URL, Part 3 plays it).

Everything protocol- and media-related lives inside the SDK. Your app never
touches CoreBluetooth internals, WebRTC, RTSP sockets, decoders, or
`AVAudioSession` — you drive the three client APIs below and build UI.

## Contents

- [Requirements](#requirements)
- [Installation](#installation-swift-package-manager)
- [Info.plist keys](#infoplist-keys)
- [Microphone permission](#microphone-permission)
- [Initialize at launch](#initialize-at-launch)
- **Part 1 — BLE onboarding**
  - [Quick start](#quick-start)
  - [Configuration properties](#configuration-properties)
  - [Delegate protocol](#delegate-protocol--vdbonboardingdelegate)
  - [Flow 1: Onboard a new doorbell](#flow-1-onboard-a-new-doorbell)
  - [Flow 2: Local stream setup (fetch the RTSP URL)](#flow-2-local-stream-setup-fetch-the-rtsp-url)
  - [Types](#types)
  - [Errors](#errors-vdberror)
  - [BLE protocol reference](#ble-protocol-reference)
- **Part 2 — Cloud live streaming**
  - [Flow A: CallKit call flow](#flow-a--callkit-call-flow-doorbell-rings-the-phone)
  - [Flow B: Direct live view](#flow-b--direct-live-view-no-call-no-callkit)
  - [Audio behavior](#audio-behavior)
  - [Snapshot, recording, fullscreen](#snapshot-recording-fullscreen)
  - [Video zoom](#video-zoom)
  - [Credentials](#credentials)
  - [Events](#events-doorbellevent)
  - [API summary](#api-summary)
- **Part 3 — Local RTSP streaming**
  - [Getting the RTSP URL](#getting-the-rtsp-url)
  - [Quick start](#quick-start-local)
  - [Local API summary](#local-api-summary)

---

## Requirements

- iOS 13.0+ (local-network streaming features require iOS 14+)
- Swift 5.9+
- **Part 1** needs Bluetooth (CoreBluetooth is linked automatically).
- **Part 2** needs a KVS signaling channel + temporary AWS credentials
  (see [Credentials](#credentials)).
- **Part 3** needs only an RTSP URL (Part 1, Flow 2 provides it).

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

| Key | Needed for |
| --- | --- |
| `NSBluetoothAlwaysUsageDescription` | **Part 1.** Required — the app crashes at runtime on first BLE use without it. |
| `NSMicrophoneUsageDescription` | **Parts 2 & 3.** Required. Used by **Talk**, and by the audio engine while **Listen** is on (see [Audio behavior](#audio-behavior)). |
| `NSLocalNetworkUsageDescription` | **Parts 2 & 3.** Required when the doorbell and phone reach each other directly on the LAN (iOS 14+ local-network privacy). |
| `UIBackgroundModes` → `audio`, `voip` | **Part 2.** Required for the CallKit flow (VoIP push + audio continuing in background). |

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to set up your Video Doorbell.</string>
```

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

Call once at app launch. It pre-initializes WebRTC (SSL, codec factories) for
the cloud client and removes ~150 ms from the first connection:

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    DoorbellSDKClient.prewarm()
    return true
}
```

---
---

# Part 1 — BLE onboarding (`DoorbellOnboardingSDK`)

`DoorbellOnboardingSDK` handles the complete Bluetooth Low Energy flow for the
Video Doorbell. It abstracts all CoreBluetooth complexity — scanning,
connecting, the authentication handshake, WiFi list retrieval, credential
provisioning, and timeout management — behind a delegate-based API. The app
builds UI screens; the SDK does everything else.

One class drives **two flows**, selected with `sessionType`:

| Flow | `sessionType` | Purpose |
| --- | --- | --- |
| [Flow 1](#flow-1-onboard-a-new-doorbell) | `.newDeviceAddition` *(default)* | First-time setup: put the doorbell on the user's WiFi and onto the cloud. |
| [Flow 2](#flow-2-local-stream-setup-fetch-the-rtsp-url) | `.hotspotTesting` | Local stream setup: send hotspot credentials, receive the **RTSP URL** back, play it with [Part 3](#part-3--local-rtsp-streaming-doorbelllocalstreamclient). |

## Quick start

Create **one instance** and retain it for the lifetime of the flow. The
`CBCentralManager` is initialised internally — do not create your own.

```swift
import DoorbellSDK

let sdk = DoorbellOnboardingSDK()
sdk.delegate = self
```

If Bluetooth is not yet powered on when you call `startScanning()` (common on
first launch), the SDK waits and starts the scan automatically once BLE becomes
ready — you don't need to observe Bluetooth state yourself.

## Configuration properties

Set these **before** calling `startScanning()`.

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `advertisingNameFilter` | `String` | `"BLAZE-VDB"` | Case-insensitive *contains* match against BLE advertising names. |
| `sessionType` | `VDBSessionType` | `.newDeviceAddition` | Selects the flow (see table above). Must be set before `startScanning()`. |
| `is2GHz` | `Bool` | `true` | `false` requests the 5 GHz band. Sets `band` / `scan_type` to `2` (2.4 GHz) or `1` (5 GHz) in the BLE commands. |
| `scanDuration` | `TimeInterval` | `10` | Seconds to scan before delivering results via `didDiscoverDevices`. |
| `wifiListTimeout` | `TimeInterval` | `15` | Seconds to wait for the device's WiFi scan-list response. |
| `provisioningTimeout` | `TimeInterval` | `150` | Seconds to wait for the device's response after `selectWifi` / `sendLocalStream`. |
| `isVerboseLoggingEnabled` | `Bool` | `false` | Scan/packet diagnostics. Leave off in production. |

## Delegate protocol — `VDBOnboardingDelegate`

Implement in your coordinator or view-model. All callbacks arrive on the
**main thread**.

**Required:**

| Method | When it fires / what to do |
| --- | --- |
| `sdk(_:didDiscoverDevices:)` | Scan finished. Show the list; call `selectDevice(_:)` on tap. Empty array = nothing found (`.scanTimeout` also fires). |
| `sdk(_:didFetchWifiList:)` | Device returned its WiFi networks. Show SSIDs + password field; call `selectWifi(ssid:password:)` on submit. |
| `sdkDidCompleteProvisioning(_:)` | Device accepted the WiFi credentials. Dismiss onboarding; wait for the device-added event on your own server channel (MQTT etc.). |
| `sdk(_:didFailWith:)` | Any-stage failure. Show `error.errorDescription`; retry with `startScanning()` or exit with `cancel()`. |

**Optional** (default no-op implementations are provided):

| Method | When it fires |
| --- | --- |
| `sdk(_:didChangeState:)` | State machine transitioned — drive a progress indicator. |
| `sdk(_:didConnectDevice:)` | BLE connection to the selected device succeeded. |
| `sdk(_:didDisconnectDevice:)` | BLE peripheral disconnected. |
| `sdkIsReadyForHotspot(_:)` | **Flow 2 only** — auth done, device is waiting for hotspot credentials. Call `sendLocalStream(ssid:password:)`. |
| `sdk(_:didReceiveLocalStreamURL:)` | **Flow 2 only** — the complete RTSP URL, ready to play. |
| `sdkDidCloseStream(_:)` | **Flow 2 only** — device acknowledged `sendCloseStream()`. |

> The Flow 2 callbacks are *protocol-optional* but **functionally required**
> when `sessionType == .hotspotTesting` — implement all three in that flow.

## Flow 1: Onboard a new doorbell

### Step-by-step

| # | Client app does | SDK does internally | Delegate fires |
| --- | --- | --- | --- |
| 1 | `startScanning(advertisingName:payload:)` | Starts BLE scan + scan timer | `didChangeState(.scanning)` |
| 2 | Wait | Filters peripherals by advertising name | — |
| 3 | Wait | Scan timer fires | `didDiscoverDevices([VDBDiscoveredDevice])` |
| 4 | Show list; user taps a device → `selectDevice(_:)` | Stops scan, connects | `didChangeState(.connecting)` |
| 5 | Wait | Discovers services/characteristics, sends auth handshake | `didConnectDevice` |
| 6 | Wait | Auth accepted → sends `ScanList` command (~1 s later) | `didChangeState(.fetchingWifiList)` |
| 7 | Wait | Assembles chunked JSON response | `didFetchWifiList([VDBWifiNetwork])` |
| 8 | Show networks; user submits SSID + password → `selectWifi(ssid:password:)` | Writes `WifiCred` command; starts provisioning timer | `didChangeState(.provisioning)` |
| 9 | Wait | Device joins WiFi and acknowledges | `sdkDidCompleteProvisioning` |
| 10 | Dismiss onboarding; listen for *device added* on your server channel | SDK is done | — |

If any step fails, `didFailWith(VDBError)` fires instead and the SDK resets to
a recoverable state — call `startScanning()` to retry, or `cancel()` to abort.

### The `payload` dictionary

`startScanning(payload:)` takes a dictionary of server-side values the SDK
embeds in the provisioning write. For Flow 1, pass:

| Key | Value |
| --- | --- |
| `device_id` | The device ID issued by your server. |
| `url` | Your API base URL (no trailing slash). |
| `scope_id` | Your scope/tenant ID. |

> Keys `ssid`, `passwd`, `cmd_type`, and `band` are **reserved** — the SDK
> writes those itself. Do not include them.

### Example

```swift
import CoreBluetooth
import DoorbellSDK

final class OnboardingCoordinator: VDBOnboardingDelegate {

    let sdk = DoorbellOnboardingSDK()

    func start(deviceId: String) {
        sdk.delegate = self
        sdk.sessionType        = .newDeviceAddition
        sdk.is2GHz             = true      // false = 5 GHz
        sdk.scanDuration       = 10
        sdk.wifiListTimeout    = 15
        sdk.provisioningTimeout = 150

        sdk.startScanning(
            advertisingName: "BLAZE-VDB",           // nil → use advertisingNameFilter
            payload: [
                "device_id": deviceId,
                "url":       "https://api.example.com",
                "scope_id":  "your-scope-id"
                // DO NOT include ssid / passwd / cmd_type / band
            ]
        )
    }

    // Step 3 — show the device list, then:
    func sdk(_ sdk: DoorbellOnboardingSDK, didDiscoverDevices devices: [VDBDiscoveredDevice]) {
        // Present in your UI; when the user taps one:
        sdk.selectDevice(devices[selectedRow])
    }

    // Step 7 — show the WiFi list, then:
    func sdk(_ sdk: DoorbellOnboardingSDK, didFetchWifiList networks: [VDBWifiNetwork]) {
        // Present SSIDs + password entry; on submit:
        sdk.selectWifi(ssid: chosenSSID, password: enteredPassword)
    }

    // Step 9 — done.
    func sdkDidCompleteProvisioning(_ sdk: DoorbellOnboardingSDK) {
        // Dismiss onboarding UI.
        // Listen for the device-added event on your own server channel.
    }

    func sdk(_ sdk: DoorbellOnboardingSDK, didFailWith error: VDBError) {
        // Show error.errorDescription to the user.
        // sdk.startScanning(...) to retry, or sdk.cancel() to abort.
    }
}
```

`refreshWifiList()` re-sends the scan-list command to the connected device —
wire it to a refresh button on your WiFi list screen.

## Flow 2: Local stream setup (fetch the RTSP URL)

The doorbell can broadcast a live RTSP feed directly over a local hotspot — no
cloud connection. This flow delivers the hotspot credentials over BLE and hands
you back the **complete RTSP URL**. Set `sessionType = .hotspotTesting`
**before** `startScanning()` — this single flag changes the whole flow: the SDK
skips the WiFi scan and instead tells you when the device is ready for
credentials.

### Step-by-step

| # | Client app does | SDK does internally | Delegate fires |
| --- | --- | --- | --- |
| 1 | Set `sessionType = .hotspotTesting`; `startScanning(advertisingName:payload:)` (payload may be `[:]`) | Starts BLE scan + timer | `didChangeState(.scanning)` |
| 2 | Wait | Scan timer fires | `didDiscoverDevices` |
| 3 | User taps a device → `selectDevice(_:)` | Connects, sends auth handshake | `didChangeState(.connecting)`, `didConnectDevice` |
| 4 | Wait | Auth accepted → **skips** the WiFi scan | `sdkIsReadyForHotspot` |
| 5 | Collect hotspot SSID + password → `sendLocalStream(ssid:password:)` | Writes `LocalStream` command; starts provisioning timer | `didChangeState(.provisioning)` |
| 6 | Wait | Device joins the hotspot, starts its RTSP server, and reports its IP; SDK builds the full RTSP URL | `sdk(_:didReceiveLocalStreamURL:)` |
| 7 | Play the URL with [`DoorbellLocalStreamClient`](#part-3--local-rtsp-streaming-doorbelllocalstreamclient) | SDK state = `.completed` | — |
| 8 | User exits → stop the player, then `sendCloseStream()` | Writes `RtspClosed` command | — |
| 9 | Wait | Device stops its RTSP server and acknowledges | `sdkDidCloseStream` |
| 10 | Navigate away | SDK is idle | — |

### The RTSP URL

The `rtspURL` delivered by `sdk(_:didReceiveLocalStreamURL:)` is complete and
ready to play — **no URL construction needed**:

```
rtsp://<device-ip>:8554/live/main        e.g. rtsp://10.55.26.239:8554/live/main
```

Pass it directly to `DoorbellLocalStreamClient.connect(rtspURL:renderIn:onEvent:)`
([Part 3](#part-3--local-rtsp-streaming-doorbelllocalstreamclient)).

### Closing the stream

- Keep the `DoorbellOnboardingSDK` instance (and its BLE link) alive while the
  stream plays — it is your only channel for the close command.
- On exit: stop the player first (`DoorbellLocalStreamClient.shared.disconnect()`),
  then call `sendCloseStream()`, and navigate away on `sdkDidCloseStream`.
- Add a short fallback (≈5 s) that navigates away anyway if the ack never
  arrives.
- If the BLE link is already gone when you call `sendCloseStream()`,
  `sdkDidCloseStream` fires **immediately** so you can still exit cleanly.

### Example (end-to-end: BLE → RTSP URL → play)

```swift
import UIKit
import DoorbellSDK

final class LocalStreamCoordinator: VDBOnboardingDelegate {

    let sdk = DoorbellOnboardingSDK()
    weak var videoContainer: UIView?

    // Step 1 — scan (hotspot mode).
    func start() {
        sdk.delegate    = self
        sdk.sessionType = .hotspotTesting          // must be set BEFORE startScanning()
        sdk.provisioningTimeout = 150
        sdk.startScanning(advertisingName: "BLAZE-VDB", payload: [:])
    }

    // Step 2 — show the device list.
    func sdk(_ sdk: DoorbellOnboardingSDK, didDiscoverDevices devices: [VDBDiscoveredDevice]) {
        sdk.selectDevice(devices[selectedRow])
    }

    // Step 4 — device is ready for hotspot credentials.
    func sdkIsReadyForHotspot(_ sdk: DoorbellOnboardingSDK) {
        // Show your credential-entry UI; when the user submits:
        sdk.sendLocalStream(ssid: "MyHotspot", password: "secret123")
    }

    // Step 6 — complete RTSP URL, ready to play (Part 3).
    func sdk(_ sdk: DoorbellOnboardingSDK, didReceiveLocalStreamURL rtspURL: String) {
        guard let container = videoContainer else { return }
        DoorbellLocalStreamClient.shared.connect(
            rtspURL: rtspURL,                      // e.g. rtsp://10.55.26.239:8554/live/main
            renderIn: container
        ) { event in
            // .streamStarted / .firstFrameReceived / .reconnecting / .error — see Part 3
        }
    }

    // Step 8 — user exits the stream screen.
    func closeTapped() {
        DoorbellLocalStreamClient.shared.disconnect()   // stop the player first
        sdk.sendCloseStream()                           // then close the device's RTSP server
        // Fallback: navigate away after ~5 s even if no ack arrives.
    }

    // Step 9 — device acknowledged the close.
    func sdkDidCloseStream(_ sdk: DoorbellOnboardingSDK) {
        // Navigate away and release everything.
    }

    // Required no-ops for this flow.
    func sdk(_ sdk: DoorbellOnboardingSDK, didFetchWifiList networks: [VDBWifiNetwork]) {}
    func sdkDidCompleteProvisioning(_ sdk: DoorbellOnboardingSDK) {}

    func sdk(_ sdk: DoorbellOnboardingSDK, didFailWith error: VDBError) {
        // Show error.errorDescription; retry or cancel().
    }
}
```

## Types

### `VDBDiscoveredDevice`

Returned by `didDiscoverDevices`. Pass it straight to `selectDevice(_:)` — do
not construct it yourself.

| Property | Type | Description |
| --- | --- | --- |
| `name` | `String` | BLE advertising name. |
| `identifier` | `UUID` | CoreBluetooth peripheral UUID — a stable list key. |

### `VDBWifiNetwork`

Returned by `didFetchWifiList`.

| Property | Type | Description |
| --- | --- | --- |
| `ssid` | `String` | Network name, whitespace-trimmed. |
| `securityType` | `String` | Currently always empty — reserved for future firmware. |

### `VDBSessionType`

| Case | Behaviour |
| --- | --- |
| `.newDeviceAddition` | Default. After auth, sends `ScanList` → `didFetchWifiList`. |
| `.hotspotTesting` | Skips `ScanList`; fires `sdkIsReadyForHotspot`. Local stream flow. |

### `VDBOnboardingState`

`.idle` → `.scanning` → `.connecting` → `.fetchingWifiList` (Flow 1 only)
→ `.provisioning` → `.completed`. `cancel()` returns to `.idle` from anywhere.

## Errors (`VDBError`)

All cases conform to `LocalizedError` — show `error.errorDescription` to the
user.

| Error | Stage | Cause | Suggested recovery |
| --- | --- | --- | --- |
| `.bleUnauthorized` | Pre-scan | Bluetooth permission denied (fires only after `startScanning()`) | Open app Settings. |
| `.blePoweredOff` | Any | Bluetooth turned off mid-session | Ask user to enable Bluetooth. |
| `.bleUnsupported` | Any | Device has no Bluetooth support | — |
| `.bleUnknownState` | Any | BLE entered an unexpected state | Restart the app. |
| `.scanTimeout` | Scanning | No matching device within `scanDuration` | Power on the doorbell; rescan. |
| `.connectionFailed(Error?)` | Connecting | BLE connect failed (CoreBluetooth error attached when available) | Retry `selectDevice()`. |
| `.connectionLost` | WiFi fetch / provisioning | Peripheral disconnected mid-flow | `startScanning()` to restart. |
| `.wifiListFetchTimeout` | WiFi fetch | No scan-list response within `wifiListTimeout` | `refreshWifiList()` or restart. |
| `.wifiListParseFailed` | WiFi fetch | Malformed scan-list JSON | Retry. |
| `.provisioningTimeout` | Provisioning | No response within `provisioningTimeout` (also fires if the BLE write itself fails) | Check credentials; retry. |
| `.networkNotFound(ssid:)` | Provisioning | Device can't find the SSID | Check router; re-pick network. |
| `.authenticationFailed` | Provisioning | Wrong WiFi password | Re-enter password. |
| `.characteristicMissing` | Any command | Method called before a BLE connection is established | Wait for `didConnectDevice` / `sdkIsReadyForHotspot`. |
| `.localStreamFailed(reason:)` | Flow 2 | Device reported a local-stream failure (no IP address returned) | Check hotspot credentials; retry. |

## BLE protocol reference

What actually goes over the air — useful for firmware validation and debugging.
Commands are written to the device's *data* characteristic; responses arrive as
(possibly chunked) JSON notifications on the same characteristic, which the SDK
reassembles.

Auth handshake: after connecting, the SDK writes the key `"BLAZE"` to the
*auth* characteristic. All commands below are sent only after this write is
acknowledged.

### `ScanList` — request WiFi networks (Flow 1)

```jsonc
// SDK → device
{
  "cmd_type":  "ScanList",
  "scan_type": 2                // 2 = 2.4 GHz, 1 = 5 GHz  (from is2GHz)
}

// device → SDK
{
  "event_type": "ScanList",
  "data": { "<SSID-1>": "...", "<SSID-2>": "..." }   // SSIDs are the KEYS
}
```

`data` may also arrive as a JSON-encoded *string* of the same dictionary — the
SDK parses both forms.

### `WifiCred` — provision WiFi credentials (Flow 1)

```jsonc
// SDK → device  (built by selectWifi(ssid:password:))
{
  "cmd_type":  "WifiCred",
  "device_id": "<device_id>",
  "data": {
    "ssid":     "<selected SSID>",
    "passwd":   "<entered password>",
    "band":     2,                       // 2 = 2.4 GHz, 1 = 5 GHz
   // "url":      "<payload url>",
    //"scope_id": "<payload scope_id>"
  }
}

// device → SDK — success (any of these forms is accepted)
{ "event_type": "WifiCredAck" }
{ "event_type": "provision_ack" }
{ "eventType": "WifiCred", "status": "Connected" }
{ "wifi_status": "Connected" }

// device → SDK — failure
{ "wifi_status": "ApNotFound" }                          // → .networkNotFound
{ "eventType": "WifiCred", "status": "AP not found" }    // → .networkNotFound
{ "wifi_status": "AuthFailed" }                          // → .authenticationFailed
{ "eventType": "WifiCred", "status": "auth failed" }     // → .authenticationFailed
```

### `LocalStream` — start the local RTSP stream (Flow 2)

```jsonc
// SDK → device  (built by sendLocalStream(ssid:password:))
{
  "cmd_type": "LocalStream",
  "data": {
    "ssid":   "<hotspot SSID>",
    "passwd": "<hotspot password>",
    "band":   2                          // 2 = 2.4 GHz, 1 = 5 GHz
  }
}

// device → SDK — success: the device's IP on the hotspot network
{ "event_type": "LocalStream", "ip_address": "10.55.26.239" }
// → SDK builds  rtsp://10.55.26.239:8554/live/main
// → fires  sdk(_:didReceiveLocalStreamURL:)

// device → SDK — failure (no ip_address)
{ "event_type": "LocalStream", "status": "Failed", "error": "AP not found" }
// → .networkNotFound if the reason contains "AP not found",
//   otherwise .localStreamFailed(reason:)
```

Note the client payload is **not** merged into the `LocalStream` command — only
the three keys above are sent.

### `RtspClosed` — stop the local RTSP stream (Flow 2)

```jsonc
// SDK → device  (built by sendCloseStream())
{ "cmd_type": "RtspClosed", "state": "Closed" }

// device → SDK — acknowledgement
{ "event_type": "RtspClosed", "state": "Closed" }
// → fires  sdkDidCloseStream
```

## Onboarding API summary

| Method | Purpose |
| --- | --- |
| `startScanning(advertisingName:payload:)` | Step 1 — begin BLE scanning (waits for Bluetooth power-on automatically). |
| `selectDevice(_:)` | Step 2 — connect + authenticate; auto-continues per `sessionType`. |
| `selectWifi(ssid:password:)` | Flow 1 — send WiFi credentials (`WifiCred`). |
| `refreshWifiList()` | Flow 1 — re-request the WiFi list from the connected device. |
| `sendLocalStream(ssid:password:)` | Flow 2 — send hotspot credentials (`LocalStream`); RTSP URL comes back via delegate. |
| `sendCloseStream()` | Flow 2 — stop the device's RTSP server (`RtspClosed`). |
| `cancel()` | Any point — disconnect BLE, invalidate timers, reset to idle. No callbacks fire after it returns. |

## Do / Don't (onboarding)

**Do**

- Set `sessionType` (and the other configuration properties) **before**
  `startScanning()`.
- Retain the SDK instance for the whole flow — and in Flow 2, for the whole
  streaming session (you need the BLE link to send `RtspClosed`).
- Call `cancel()` on every user-initiated exit.

**Don't**

- Don't include `ssid`, `passwd`, `cmd_type`, or `band` in the payload — the
  SDK owns those keys.
- Don't construct `VDBDiscoveredDevice` yourself — only pass back instances the
  SDK gave you.
- Don't create your own `CBCentralManager` alongside the SDK's.

### Threading (onboarding)

Call the API from any thread — the SDK marshals onto its own internal BLE
queue. All delegate callbacks are delivered on the **main thread**.

---
---

# Part 2 — Cloud live streaming (`DoorbellSDKClient`)

`DoorbellSDKClient` streams the doorbell live over **AWS Kinesis Video Streams
(KVS) WebRTC**. It handles signaling, ICE/DTLS, H.265 video decoding and
rendering (with built-in pinch-to-zoom), and two-way audio (Talk / Listen) with
hardware echo cancellation and automatic loudspeaker routing — you give it
credentials and a view, it gives you a live stream.

There are two ways to use it:

| Flow | Use when | Entry point |
| --- | --- | --- |
| **A. CallKit call flow** | The doorbell *rings* the phone and the user answers a call | `prepareConnection` → `acceptCall` |
| **B. Direct live view** | The user opens a "View Live" screen from inside your app | `connectToStream` |

> **Streaming over the local network instead of the cloud?** That is
> `DoorbellLocalStreamClient` — see
> [Part 3](#part-3--local-rtsp-streaming-doorbelllocalstreamclient).

## Flow A — CallKit call flow (doorbell rings the phone)

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

## Flow B — Direct live view (no call, no CallKit)

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

## Audio behavior

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

## Snapshot, recording, fullscreen

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

The renderer carries its pinch-to-zoom with it, so zoom keeps working after the
fullscreen re-parent (see [Video zoom](#video-zoom)).

## Video zoom

Pinch-to-zoom on the live video is **built in and on by default** — no setup
required. The user pinches to zoom toward their fingers, drags to pan, and
double-taps to toggle zoom in/out. Panning is clamped to the video, so it never
exposes the black letterbox bars, and a small zoom-level pill ("2.3×") fades in
while zoomed.

It works in every flow, and because the zoom lives on the SDK's renderer view it
**survives fullscreen re-parenting**. **Snapshots and recordings are
unaffected** — they are captured from the decoded stream, upstream of the
display, so they always contain the full, un-zoomed frame at native resolution
regardless of what is on screen.

Everything below is optional; the defaults are already applied.

```swift
DoorbellSDKClient.shared.isVideoZoomEnabled = true    // default true
DoorbellSDKClient.shared.maxVideoZoomScale  = 4.0      // default 4.0

// Observe the zoom level, e.g. to drive your own indicator (main thread).
DoorbellSDKClient.shared.onVideoZoomChanged = { scale in
    print("zoom = \(scale)")
}

let scale = DoorbellSDKClient.shared.currentVideoZoomScale   // 1.0 = fit
DoorbellSDKClient.shared.resetVideoZoom()                    // animate back to 1×
```

- **Zoom limit.** `maxVideoZoomScale` defaults to **4×** — the useful ceiling for
  a 1080p / 2K doorbell stream; past that the image is only upscaled. Set it to
  `1.0`, or `isVideoZoomEnabled = false`, to turn zoom off.
- **Digital zoom.** This zooms the received video on-device — it is not an
  optical/camera zoom on the doorbell.
- **Automatic reset.** Zoom returns to 1× whenever the video surface changes —
  rotation, entering / leaving fullscreen, or a reconnect.
- **Overlays intercept gestures.** If you place an *interactive* view on top of
  the renderer (a tap-to-show-controls layer, a timestamp overlay, etc.), it will
  hit-test first and swallow the pinch. Set that view's
  `isUserInteractionEnabled = false`, or lay it out as a sibling beside the video
  rather than covering it.

## Teardown

```swift
DoorbellSDKClient.shared.disconnect()   // stop stream, release everything
```

`declineCall()` is an alias for `disconnect()` that reads better at a call
site. After `disconnect()` the client is reusable — the next
`connectToStream` / `prepareConnection` starts a fresh session.

## Credentials

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

## Events (`DoorbellEvent`)

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

## State flags

```swift
DoorbellSDKClient.shared.isConnected   // signaling connected
DoorbellSDKClient.shared.isStreaming   // media flowing
DoorbellSDKClient.shared.isPrepared    // warmed up, awaiting accept/decline
DoorbellSDKClient.version              // SDK version string
```

## API summary

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
| `isVideoZoomEnabled` | Enable / disable pinch-to-zoom (default on). | Both |
| `maxVideoZoomScale` | Max pinch zoom, default 4× (`1.0` disables). | Both |
| `currentVideoZoomScale` | Current zoom level (`1.0` = fit). | Both |
| `resetVideoZoom(animated:)` | Return to 1×. | Both |
| `onVideoZoomChanged` | Zoom-level change callback (main thread). | Both |
| `disconnect()` | Stop & release everything. | Both |
| `isConnected` / `isStreaming` / `isPrepared` | State flags. | Both |

## Do / Don't (cloud)

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

## Threading (cloud)

Call the SDK from the **main thread**. All events are delivered on the main
thread, so you can update UI directly inside the `onEvent` closure.

---
---

# Part 3 — Local RTSP streaming (`DoorbellLocalStreamClient`)

When the doorbell exposes a **direct RTSP stream on the local network** —
during hotspot provisioning / on-network setup testing, or any LAN-direct
viewing — use **`DoorbellLocalStreamClient`**.

It is a sibling to `DoorbellSDKClient` (cloud) and `DoorbellOnboardingSDK` (BLE
onboarding): **its own class, its own functions.** You give it an **RTSP URL**
and a view — no AWS credentials, no signaling, no CallKit. The SDK runs the full
native pipeline (RTSP control plane → RTP → H.265 / AAC decode → render), owns
the audio session, and auto-reconnects a dropped stream. Your app touches no
sockets, decoders, or `AVAudioSession` — exactly like the cloud client.

## Getting the RTSP URL

The URL comes from the **onboarding SDK's local stream flow**
([Part 1, Flow 2](#flow-2-local-stream-setup-fetch-the-rtsp-url)): connect to
the doorbell over BLE with `sessionType = .hotspotTesting`, send the hotspot
credentials with `sendLocalStream(ssid:password:)`, and receive the complete
URL in `sdk(_:didReceiveLocalStreamURL:)`:

```
rtsp://<device-ip>:8554/live/main        e.g. rtsp://10.55.26.239:8554/live/main
```

Pass it to `connect(rtspURL:renderIn:onEvent:)` unchanged — no URL construction
needed. When the user exits, disconnect this player **first**, then close the
device's RTSP server over BLE with `sendCloseStream()` (see the
[end-to-end example](#example-end-to-end-ble--rtsp-url--play)).

## Quick start (local)

```swift
final class LocalStreamVC: UIViewController {

    @IBOutlet private weak var videoView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()

        DoorbellLocalStreamClient.shared.connect(
            rtspURL: "rtsp://10.55.26.239:8554/live/main",   // from Part 1, Flow 2
            renderIn: videoView
        ) { [weak self] event in
            switch event {
            case .streamStarted:                 break            // RTSP PLAY succeeded
            case .firstFrameReceived:            self?.hideLoadingSpinner()
            case .reconnecting(let n, let max):  self?.showReconnecting(n, of: max)
            case .streamStopped:                 break            // you called disconnect()
            case .error(let e):                  self?.showError(e.message)
            default: break
            }
        }
    }

    @IBAction private func listenTapped(_ sender: UIButton) {
        DoorbellLocalStreamClient.shared.setListen(enabled: !sender.isSelected)
    }

    @IBAction private func talkTapped(_ sender: UIButton) {
        DoorbellLocalStreamClient.shared.setTalk(enabled: !sender.isSelected)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DoorbellLocalStreamClient.shared.disconnect()
    }
}
```

That's the whole integration — pass a URL, react to events, disconnect on the
way out.

## Behavior

- **Listen defaults ON, Talk defaults OFF.** The doorbell is audible as soon as
  frames flow. (This differs from the cloud client, where *both* default off.)
- **Audio is handled exactly like the cloud client** — automatic loudspeaker
  routing, hardware echo cancellation, and the same hardware-muted capture path
  during Listen (so the orange mic indicator may show even with Talk off; no
  audio leaves the device until Talk is on). See [Audio behavior](#audio-behavior).
  Never touch `AVAudioSession` yourself.
- **Auto-reconnect is built in.** A dropped stream retries automatically (a few
  attempts with backoff). You receive `.reconnecting(attempt:max:)` while it
  retries, then `.streamStarted` on recovery, or `.error(.localStreamFailed)` if
  it gives up.
- **Fullscreen** uses the same re-parenting pattern as the cloud client —
  re-parent `DoorbellLocalStreamClient.shared.videoView` into your fullscreen
  container (see the [`embedVideo` helper](#full-callkit-example)), and put it
  back on dismiss. The RTSP session keeps running throughout.

## Mutual exclusion with the cloud stream

The cloud (`DoorbellSDKClient`) and local (`DoorbellLocalStreamClient`) streams
are **mutually exclusive** — only one may own the audio session at a time. You
don't manage this: starting either one automatically tears the other down first
(`DoorbellLocalStreamClient.connect()` stops any cloud stream;
`DoorbellSDKClient.connectToStream()` / `prepareConnection()` stop any local
stream). In practice the two flows (hotspot testing vs. cloud calls) never
overlap.

## Events & errors (local)

The local client reports through the same `DoorbellEvent` / `DoorbellError`
types (delivered on the **main thread**). The subset it uses:

| Event | Meaning |
| --- | --- |
| `.streamStarted` | RTSP PLAY succeeded — media negotiated (also fires again after a successful reconnect). |
| `.firstFrameReceived` | First video frame decoded & rendered. Hide your spinner. |
| `.reconnecting(attempt:max:)` | Stream dropped; the SDK is auto-reconnecting. |
| `.streamStopped` | You called `disconnect()`. |
| `.listenStateChanged(isEnabled:)` / `.talkStateChanged(isEnabled:)` | Audio toggle state changed. |
| `.error(.localStreamFailed)` | Reconnect gave up, or the device reported a failure. |
| `.error(.notConnected)` | `setListen` / `setTalk` called with no active local stream. |

## Local API summary

| Member | Purpose |
| --- | --- |
| `connect(rtspURL:renderIn:onEvent:)` | Connect to the RTSP URL and render into the view. |
| `setListen(enabled:)` | Hear the doorbell (loudspeaker, automatic routing). Defaults **on**. |
| `setTalk(enabled:)` | Send mic audio (push-to-talk or toggle). Defaults **off**. |
| `videoView` | The SDK's live renderer view, for fullscreen re-parenting. |
| `disconnect()` | Stop the stream and release everything (incl. the audio session). |
| `isConnected` / `isStreaming` | State flags. |

## Do / Don't (local)

**Do**

- Request microphone permission before the first Talk/Listen use (same as the
  cloud client).
- Call `disconnect()` when the screen goes away.
- Keep the BLE session (`DoorbellOnboardingSDK`) alive while streaming so you
  can close the device's RTSP server with `sendCloseStream()` on exit.

**Don't**

- Don't call `AVAudioSession.setCategory` / `setActive` /
  `overrideOutputAudioPort` — the SDK owns the session end to end.
- Don't call the CallKit hooks (`startAudio` / `stopAudio` /
  `setCallKitSessionOwnership`) — those are on `DoorbellSDKClient` only.
- Don't drive the local stream through `DoorbellSDKClient` — the two are
  separate clients; use `DoorbellLocalStreamClient` for everything local.
- Don't build the RTSP URL yourself — always use the one delivered by
  `sdk(_:didReceiveLocalStreamURL:)`.
