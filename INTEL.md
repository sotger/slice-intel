# Slice on Intel (x86_64)

**Unofficial.** This is a source snapshot of [Slice](https://github.com/rit3zh/slice) 0.2.8
(upstream commit `bb7912f`) plus the minimal change needed to build and run it on an Intel Mac.
It is not affiliated with, endorsed by, or supported by the Slice author.

## Status

Built and launched on this machine:

- Intel Core i9-10850K (10 cores, 3.6 GHz), 32 GB RAM
- AMD Radeon RX 5700 XT, 8 GB, Metal 3
- macOS 26.7.2 (Tahoe)
- Xcode 26.6 (17F113, Universal) — the last Xcode that runs on Intel Macs
- **Hackintosh**: SMBIOS reports Mac Pro (`MacPro7,1`), but this is a custom desktop build,
  so treat it as a generic Intel Mac rather than a real Mac Pro.

Verified: the Release build succeeds, the app is a thin `x86_64` binary, `codesign --verify`
passes, and the app launches and draws its capture bar. Screen recording, camera capture and
export have not been exercised yet.

## What changed

Only one source line:

- `Sources/SliceCore/Rendering/Device3DTemplate+Lid.swift:57` — the local `triangles` array was
  shadowed by the call to `triangles(of:)` in its own initializer. Swift 6.3 (shipped with
  Xcode 26.6) rejects that with `cannot call value of non-function type`; qualifying the call as
  `Device3DTemplate.triangles(of:)` fixes it.

Everything else is untouched, including the upstream license and copyright notices. The local
signing configuration (`Config/Signing.local.xcconfig`) is git-ignored and not part of this repo.

## Build

Requirements: Xcode 26.6 Universal (Xcode 27 and later are Apple silicon only), XcodeGen, and
the Metal toolchain component that Xcode 26 downloads separately.

```sh
# once, after installing Xcode 26.6
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain

xcodegen generate

xcodebuild -project Slice.xcodeproj -scheme Slice -configuration Release \
  -derivedDataPath build \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  SLICE_ENTITLEMENTS=App/Slice-SelfSigned.entitlements \
  build
```

The upstream `Config/Signing.xcconfig` points at the author's development team, so a local build
must override the identity and team as shown above (or create `Config/Signing.local.xcconfig`).
The result is `build/Build/Products/Release/Slice.app`.

For a stable self-signed identity (so macOS keeps Screen Recording, Camera and Microphone
permissions across rebuilds), run `scripts/setup-local-signing.sh` once and drop the
`CODE_SIGN_IDENTITY=-` override.

## Runtime notes on Intel

- **Parakeet transcription** runs through Core ML, and Intel Macs have no Neural Engine, so it
  falls back to the CPU. It works, but expect it to be slow compared with Apple silicon.
- **Voice enhancement (DeepFilterNet)** ships an official `x86_64-apple-darwin` runtime binary, so
  it is unaffected.
- **Updates**: the upstream appcast marks releases as `arm64`-only, so Sparkle will not offer
  updates to an Intel build. Rebuild to update.
- `install.sh` from the project website refuses to run on non-arm64 machines; it is irrelevant if
  you build from source.

## License

Covered by the same [Slice Source-Available License](LICENSE) as upstream. This repository shares
the modified source code for free, marked as modified and unofficial, as section 5 of the license
allows. No compiled binaries are distributed here.
