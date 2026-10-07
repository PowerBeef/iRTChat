# iRTChat

A native iPhone chat app that runs **Gemma 4** entirely on-device via Google's **LiteRT-LM** — with GPU acceleration, streaming replies, reasoning view, image + voice input, and offline tools. No accounts, no API keys, no cloud.

## Features

- **Fully on-device** — models download once, then everything runs offline
- **Gemma 4 E2B** (~2.6 GB multimodal) by default, **E4B** (~3.7 GB) on roomy devices
- **Streaming replies** with per-message stats (TTFT, prefill/decode tok/s, backend)
- **Thinking mode** — reasoning streams into a collapsible card under each reply
- **Multimodal** — attach photos, record voice notes, adjust image detail
- **On-device tools** — the assistant can check the time and calculate
- **Liquid Glass UI** — native SwiftUI with refined glass surfaces and haptics
- **Chat history** persisted locally with SwiftData

## Requirements

- Mac with Xcode 27+ and an iOS 27 simulator
- A physical iPhone on iOS 27 for real inference (the simulator has no Metal LLM path)
- ~3 GB free for E2B, ~4 GB for E4B
- Network only for the first launch (model download) — chat itself is offline

## Getting started

### Smoke-test the UI without a model (simulator)

```sh
open iRTChat.xcodeproj
```

Select the `iRTChat` scheme and an iPhone simulator, then Run with the `--mock-engine` launch argument (Scheme → Run → Arguments). The scripted mock engine drives the full UI: threads, streaming bubbles, reasoning cards, settings.

> Never double-click the built `.app` in Finder — simulator builds only run inside the iOS Simulator or via `xcodebuild`.

### Real inference (physical iPhone)

1. Open `iRTChat.xcodeproj`, set your Development Team and a unique bundle id.
2. Run the `iRTChat` scheme on your iPhone (use Release for best speed).
3. In the **Models** tab, download **Gemma 4 E2B** (keep the app open while downloading).
4. Chat. Try **Thinking**, attach a photo, or record a voice note.

Models come from Hugging Face (`litert-community`, ungated, Apache-2.0) with pause/resume and size verification, and live in Application Support.

### Tests

Run the `iRTChat` scheme tests. The committed XCTest suite (34 tests) covers the inference planner, device gating, calculator tool, stream accumulator, model catalog (URLs + verified byte sizes), and the download store.

## Performance

- **Speculative decoding (MTP)** — up to ~2x faster decode, enabled only when the model file ships a drafter
- **Model introspection** — thinking, vision/audio, visual-token budget, and KV limits are clamped to each file's stated capabilities
- **Persistent GPU cache** so compiled kernels survive restarts and warm starts stay fast
- **Optional reasoning-cache compaction** for longer effective context (Settings → Performance)
- **On-device benchmark** (Settings → Benchmark, 1024 prefill / 256 decode) to compare against Google's published numbers
- GPU (Metal) first with automatic CPU fallback; vision/audio executors on CPU per Google's iOS guidance

## Architecture

```text
ChatView → AppState (@MainActor) → LiteRTChatEngine (actor) → LiteRTLM Engine
                                                       ↓
SwiftData threads/turns ← streaming ChatChunk deltas + GenerationStats
```

- `ChatEngine.swift` is the **sole** importer of `LiteRTLM` — one actor owns one `Engine` + `Conversation`
- `InferencePlanner` (pure, tested) resolves user options + device RAM into backend, KV-cache size, sampler, thinking budget, visual-token budget, and MTP
- Per-reply stats come from the runtime benchmark API with client-side timing as fallback

## Project structure

| Path | Contents |
| --- | --- |
| `iRTChat/` | App sources — views, engine, model store, SwiftData |
| `iRTChat/Views/` | SwiftUI screens (`ChatView`, `ThreadListView`, `ModelLibraryView`, `SettingsView`) |
| `iRTChat/Inference/` | Engine actor, planner, device profile, tools |
| `iRTChat/Support/` | Design tokens, haptics, image preparation |
| `iRTChatTests/` | Committed XCTest suite |
| `Vendor/LiteRT-LM/` | Pruned LiteRT-LM v0.18.0 Swift package (see below) |

## Known limitations

- Downloads are foreground-only with resume — keep the app open while downloading
- Photo attach is library-only (no in-app camera capture yet)
- E4B is not advised on devices with less than ~7 GB RAM
- The simulator runs the UI + mock engine only; real inference needs a physical iPhone
- KV session save/restore across chats is not yet in LiteRT-LM's Swift API

## Why is LiteRT-LM vendored?

`Vendor/LiteRT-LM` is the upstream Swift package surface (336 KB) at v0.18.0. The upstream repo keeps prebuilt binaries in Git LFS, whose GitHub batch endpoint intermittently fails, breaking remote SPM resolution. The iOS build never touches those LFS files (it uses the checksummed release xcframework), so vendoring is behavior-neutral. Refresh with `TAG=vX.Y.Z ./Vendor/refresh-litert-lm.sh` — see `Vendor/README.md`.

## Contributing

We work directly on `main`. Keep the test suite green and the UI native.

## Sources

- <https://github.com/google-ai-edge/litert>
- <https://github.com/google-ai-edge/LiteRT-LM>
- <https://developers.google.com/edge/litert-lm/swift>
- <https://developers.google.com/edge/litert-lm/models/gemma-4>
- <https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm>
