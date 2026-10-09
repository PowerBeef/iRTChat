<div align="center">

# iRTChat

**Private, on-device AI chat for iPhone — powered by Gemma 4 and LiteRT-LM.**

No accounts. No API keys. No cloud. After a one-time model download, every conversation stays on your phone.

![iOS 27](https://img.shields.io/badge/iOS-27-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![LiteRT-LM 0.18.0](https://img.shields.io/badge/LiteRT--LM-0.18.0-4285F4)
![Gemma 4](https://img.shields.io/badge/Model-Gemma%204-8E75FF)
![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue)

</div>

---

## Contents

- [Highlights](#highlights)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Models](#models)
- [Architecture](#architecture)
- [Reliability](#reliability)
- [Performance](#performance)
- [Testing](#testing)
- [Project structure](#project-structure)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Vendored LiteRT-LM](#vendored-litert-lm)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Highlights

| | |
| --- | --- |
| **Fully on-device** | Gemma 4 runs locally on the GPU (Metal) with automatic CPU fallback. Works offline after the first download. |
| **Streaming replies** | Tokens stream live, with per-reply stats: time to first token, decode speed, and backend. |
| **Reasoning** | Optional thinking mode streams the model's reasoning into a collapsible card under each reply. |
| **Multimodal** | Attach photos (with adjustable image detail) and record voice messages up to 30 seconds. |
| **On-device tools** | The model can check the current date and time and evaluate arithmetic, without leaving the phone. |
| **Speculative decoding** | Multi-token prediction (MTP) speeds up decoding when the model file ships a drafter. |
| **Chat history** | Conversations persist locally with SwiftData; each chat keeps its own context. |
| **Native design** | SwiftUI with Liquid Glass surfaces, haptics, and accessibility identifiers throughout. |

## Requirements

| | |
| --- | --- |
| **Development** | Mac with Xcode 27 and the iOS 27 SDK |
| **Inference** | A physical iPhone on iOS 27 — the simulator has no Metal LLM path and runs a scripted mock engine instead |
| **Storage** | ~3 GB free for E2B, ~4 GB for E4B |
| **Signing** | An Apple Developer account with the **Extended Virtual Addressing** and **Increased Memory Limit** capabilities |
| **Network** | Only to download a model |

## Getting started

### Run on an iPhone

1. Open `iRTChat.xcodeproj`.
2. The project is configured for team `FK2D8X36G2` and bundle ID `com.patricedery.irtchat`. On another account, change both under **Signing & Capabilities**.
3. Select the `iRTChat` scheme and your iPhone, then run. Use the **Release** configuration for representative speed.
4. Open the **Models** tab and download **Gemma 4 E2B**. Keep the app in the foreground until the download finishes.
5. Start a chat from the **Chat** tab.

> [!NOTE]
> Automatic signing registers the required capabilities from `iRTChat/iRTChat.entitlements`. If signing fails with *"PLA Update available"*, accept the latest Program License Agreement at [developer.apple.com/account](https://developer.apple.com/account).

### Explore the UI in the simulator

Run the `iRTChat` scheme on any iPhone simulator with the `--mock-engine` launch argument (**Product → Scheme → Edit Scheme → Run → Arguments**). A scripted engine drives the full interface — chats, streaming bubbles, reasoning cards, and settings — without downloading a model.

## Models

| Model | Size | Use | Requires | License |
| --- | --- | --- | --- | --- |
| **Gemma 4 E2B** | 2.6 GB | Default. Text, vision, audio, reasoning. | Any supported iPhone | Apache 2.0 |
| **Gemma 4 E4B** | 3.7 GB | Higher quality. | App memory limit of at least 4.5 GB | Apache 2.0 |

Models are the multimodal `.litertlm` builds from Hugging Face ([`litert-community`](https://huggingface.co/litert-community)), downloaded at runtime without an account; they are not included in this repository. Downloads support pause and resume, are size- and HTTP-status-verified, check free space first, and are stored in Application Support, excluded from iCloud backup.

### Settings

| Section | Options |
| --- | --- |
| **Performance** | GPU or CPU backend · speculative decoding (MTP) · compact reasoning cache |
| **Reasoning & Memory** | Thinking on/off and token budget · automatic or manual KV-cache size |
| **Sampling** | Precise (temperature 0.2) · Balanced (0.7) · Creative (1.0) |
| **Voice & Vision** | Image and audio input · image detail (140 / 280 / 560 visual tokens) |
| **System Prompt** | Custom instructions for every conversation |
| **Benchmark** | 1,024-token prefill / 256-token decode run, comparable to Google's published numbers |
| **Tools** | Enable or disable on-device tools |

## Architecture

```text
┌────────────────────────────── SwiftUI ──────────────────────────────┐
│  ThreadListView ─▶ ChatView        ModelLibraryView     SettingsView │
└──────────────────────────────────┬──────────────────────────────────┘
                                   ▼
                     AppState  (@MainActor, @Observable)
       engine lifecycle queue · chat ↔ conversation binding · streaming
                │                                         │
                ▼                                         ▼
   LiteRTChatEngine  (actor)                   SwiftData  (ChatThread, ChatTurn)
   load ladder · validation · context budget
                │
                ▼
     LiteRT-LM  Engine + Conversation  ──▶  Metal GPU / CPU
```

| Component | Responsibility |
| --- | --- |
| `AppState` | Runs every engine operation — load, model switch, settings change, benchmark, delete — one at a time; binds the native conversation to the open chat; publishes streamed text at ~10 Hz. |
| `LiteRTChatEngine` | The single owner of a LiteRT-LM `Engine` and `Conversation`. Loads through a GPU → CPU, multimodal → text-only ladder, validates each engine, and keeps every request inside the KV cache. |
| `InferencePlanner` | Pure, tested resolution of user options and device memory into backend, KV-cache size, sampler, thinking budget, visual-token budget, and MTP. Decides when a settings change needs an engine rebuild. |
| `ContextBudget` | Pure, tested KV-cache arithmetic: token estimates, history trimming, and reply caps. |
| `ModelStore` | Model downloads, verification, and storage. |
| `DeviceProfile` | Device memory policy, based on the app's real memory limit. |

## Reliability

These safeguards come from failures reproduced on device by the test harness.

- **Context window** — Overflowing the KV cache corrupts LiteRT-LM's native heap and crashes the app. Every send measures the tokens already cached, estimates the new message (calibrated against exact runtime counts), trims older turns when needed — truncating the latest reply rather than dropping it — and caps the reply to the remaining room. Messages that can never fit are rejected with a clear explanation.
- **Engine validation** — LiteRT-LM can report a successful load after failing to map parts of the model file. Each new engine must complete a one-token generation before the app uses it.
- **Stop and resume** — A cancelled LiteRT-LM conversation rejects the next message. Stopped replies keep their partial text, and the chat's conversation is rebuilt from history before the next send.
- **Background** — iOS doesn't allow GPU work in the background. A reply in progress stops cleanly when the app leaves the foreground.
- **Memory** — The memory entitlements raise the app's limit from about 3.5 GB to about 6.4 GB on a 12 GB iPhone and prevent address-space exhaustion when engines are rebuilt.
- **Capability flags** — The model file's *thinking* and *function-calling* flags are not trusted; Gemma 4 E2B reports both as unsupported, yet reasons and calls tools on device.

## Performance

Measured on iPhone 17 Pro (12 GB, iOS 27) with Gemma 4 on the GPU and MTP enabled.

| Metric | Gemma 4 E2B | Gemma 4 E4B |
| --- | --- | --- |
| Load (warm, kernels cached) | 0.6 – 2 s | — |
| Load (first, after download) | ~7 s | ~9 s |
| Time to first token | 0.1 – 0.3 s | ~0.4 s |
| Decode, in chat | 40 – 80 tok/s | ~50 tok/s |
| Benchmark prefill (1,024 tokens) | 3,900 – 5,000 tok/s | — |
| Benchmark decode (256 tokens) | 25 – 62 tok/s, depending on device temperature | — |
| App memory footprint | 0.6 – 2.3 GB | ~1.1 GB after load |

For reference, Google reports 2,878 prefill and 56 decode tokens per second for E2B on the iPhone 17 Pro GPU.

## Testing

| Target | Runs on | Covers |
| --- | --- | --- |
| `iRTChatTests` | Simulator | Planner, context budgeting, device policy, calculator, catalog, downloads, and the app pipeline through the mock engine |
| `iRTChatDeviceTests` | iPhone | The real engine in-process: download, load, text, chat isolation, stop and continue, tools, thinking, image, audio, settings rebuilds, context limits, benchmark. E4B scenarios are opt-in. |
| `iRTChatUITests` | iPhone or simulator | Real taps: new chat, send, Stop, Home button mid-reply, leaving and returning mid-reply, rapid settings changes, Models tab |

**Unit tests (simulator)**

```sh
xcodebuild test -project iRTChat.xcodeproj -scheme iRTChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:iRTChatTests
```

**On-device harness** (connected, unlocked iPhone; downloads E2B if missing)

```sh
scripts/device-harness.sh inference   # engine scenarios
scripts/device-harness.sh ui          # real-tap UI flows
scripts/device-harness.sh e4b         # opt-in E4B scenarios (3.7 GB download)
scripts/device-harness.sh all         # inference, then UI

DEVICE_ID=<udid> scripts/device-harness.sh all   # another iPhone
```

Results are written to `build/device-harness/`: result bundles, per-scenario JSON metrics and screenshots, and `harness-report.json` pulled from the device. The app logs under the subsystem `com.patricedery.irtchat` with categories `engine`, `generation`, and `lifecycle`.

[MobileBuildMCP](https://github.com/getsentry/xcodebuildmcp.com) users get project defaults from `.mobilebuildmcp/config.yaml`, including a `device-tests` profile for `test_device`.

## Project structure

```text
iRTChat/
├── iRTChatApp.swift          App entry, SwiftData container, scene lifecycle
├── AppState.swift            Engine lifecycle, chat binding, generation pipeline
├── iRTChat.entitlements      Extended virtual addressing, increased memory limit
├── Inference/                Engine actor, planner, context budget, device policy, tools
├── Models/                   Model catalog and download store
├── Persistence/              SwiftData models
├── Views/                    Chat, chat list, models, settings, audio recorder
└── Support/                  Design tokens, haptics, image preparation, diagnostics
iRTChatTests/                 Unit tests
iRTChatDeviceTests/           On-device engine scenarios
iRTChatUITests/               UI flows
scripts/device-harness.sh     On-device test runner
Vendor/LiteRT-LM/             LiteRT-LM v0.18.0 Swift package
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Signing error *"PLA Update available"* | Accept the latest Program License Agreement at [developer.apple.com/account](https://developer.apple.com/account). |
| *"Failed to create a bundle instance … iRTChatDeviceTests.xctest"* | The iPhone has an install from before that target existed. Run `xcrun devicectl device uninstall app --device <udid> com.patricedery.irtchat` and retry. This also removes downloaded models. |
| Download stopped | Downloads run in the foreground only. Tap **Resume** in the **Models** tab; if the app was closed, the download starts over. |
| *"Older messages were dropped from the model's memory"* | Expected in long chats. Raise the KV-cache size under **Settings → Reasoning & Memory**, or start a new chat. |

## Known limitations

- Downloads run in the foreground only; keep the app open until they finish.
- Photos come from the library only; there is no in-app camera capture yet.
- When you switch chats, only text history is replayed to the model, not images or audio.
- Voice messages are not stored; they are marked in the chat.
- The simulator runs the UI with the mock engine only.
- LiteRT-LM's Swift API does not yet support saving and restoring KV sessions.

## Vendored LiteRT-LM

`Vendor/LiteRT-LM` contains the Swift package surface of [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) at v0.18.0. The upstream repository stores prebuilt binaries in Git LFS, whose endpoint intermittently fails during Swift Package Manager resolution. The iOS build uses only the checksummed release XCFramework, so vendoring the Swift sources changes no behavior.

To update to a newer release:

```sh
TAG=v0.19.0 ./Vendor/refresh-litert-lm.sh
```

Then update the tag in `Vendor/README.md` and run the test suites.

## Contributing

Work happens directly on `main`. Keep the unit tests and the on-device harness green, and keep the UI native.

## License

iRTChat is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution of the third-party components it uses and downloads:

| Component | Distribution | License |
| --- | --- | --- |
| iRTChat source code | This repository | Apache 2.0 |
| LiteRT-LM | Vendored in `Vendor/LiteRT-LM` | Apache 2.0 |
| Gemma 4 E2B / E4B | Downloaded at runtime | Apache 2.0 |

## Acknowledgements

- [LiteRT](https://github.com/google-ai-edge/litert) and [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) by Google (Apache 2.0)
- [LiteRT-LM Swift guide](https://developers.google.com/edge/litert-lm/swift)
- [Gemma 4 on LiteRT-LM](https://developers.google.com/edge/litert-lm/models/gemma-4)
- [Gemma 4](https://huggingface.co/google/gemma-4-E2B-it) by Google, with [E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) and [E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) LiteRT-LM builds by `litert-community` (Apache 2.0)
