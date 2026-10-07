# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of
https://github.com/google-ai-edge/LiteRT-LM at tag **v0.18.0**,
containing only what the Xcode build needs:

- `Package.swift` (pins the `CLiteRTLM.xcframework.zip` binary, checksummed)
- `swift/` (the `LiteRTLM` Swift wrapper sources)
- `LICENSE` (Apache 2.0, Google LLC)

## Why vendored instead of a remote SPM dependency?

The upstream repo stores ~GBs of prebuilt binaries in Git LFS, and GitHub's
LFS batch endpoint for that repo currently fails with HTTP 502, which makes
`xcodebuild` package resolution fail. The iOS build never touches those LFS
files (it uses the release-attached xcframework), so vendoring the 336 KB
Swift surface sidesteps the outage with zero behavior change.

## Refreshing

To move to a newer upstream tag, run:

```sh
TAG=v0.19.0 ./Vendor/refresh-litert-lm.sh
```

then update the tag in this file and verify the build.
