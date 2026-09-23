# Building on macOS

`scripts/build.sh` builds the default Debug product on macOS: bootstrap checks
→ Go c-shared core → hvigor `assembleHap`. It uses the IDE's Hvigor wrapper when
available, matching the Windows flow without injecting a second Hvigor engine.

## Prerequisites

- DevEco Studio for Mac (HarmonyOS SDK embedded; the native SDK with
  `aarch64-linux-ohos` clang/sysroot lives inside the app bundle).
- A host Go toolchain ≥ 1.22.6 to bootstrap the OpenHarmony Go fork
  (official `go1.24.5.darwin-arm64.tar.gz` works well).
- Node.js is taken from DevEco's bundled runtime.
- Git checkouts of the OpenHarmony Go fork and Tailscale. The scripts verify the
  complete patches with Git; unrelated local edits do not count as applied patches.

## One-time: build the GOOS=openharmony toolchain

The Gitee mirror of `ohos_golang_go` only carries the old go1.22-based master.
The maintained go1.24 line lives on GitCode:

```bash
git clone --depth 1 -b release-branch.go1.24 \
  https://gitcode.com/openharmony-sig/ohos_golang_go.git third_party/ohos-go
git -C third_party/ohos-go apply ../../patches/ohos-go-interface-resources.patch
cd third_party/ohos-go/src
GOROOT_BOOTSTRAP=/path/to/go1.24.5.darwin-arm64 GOTOOLCHAIN=local ./make.bash
cd ../../..
git clone --depth 1 -b v1.86.5 https://github.com/tailscale/tailscale.git third_party/tailscale
```

## Build

```bash
cp build-profile.example.json5 build-profile.json5
# Configure the installed SDK and run ohpm install --all in the project root.
./scripts/build.sh            # default product, buildMode=debug, debuggable=true
```

For a signed Debug HAP, configure local debug signing in DevEco
(File > Project Structure > Signing Configs) and re-run the script; the
artifact lands in `entry/build/default/outputs/default/`.

This macOS entry rejects `release` and unknown products before starting a build.
Production Release continues to use the verified Windows entry
`scripts/build.ps1 -Product release`, after release-review and changelog
confirmation. Do not use debug signing for a Release package.

## Gotchas

- **Keep the toolchain and Go caches off network/exFAT-style volumes.** Self-hosting
  (`make.bash`) writes binaries and immediately mmaps them for execution; on
  volumes that don't serve freshly written executables reliably this fails with
  `signal: bus error`. `scripts/build-go.sh` therefore prefers
  `~/.ohos-go-build/ohos-go` as GOROOT and keeps `GOCACHE`/`GOMODCACHE`/`GOPATH`
  on the internal disk. The final `.so` and generated `.h` are copied back to
  the project directory.
- Set `OHOS_GO_ROOT` to select an explicit toolchain Git checkout. Both the `.so`
  and generated `.h` are copied into the project. Patches may update the selected
  source checkouts; partial or conflicting patches stop the build.
- Module downloads use `GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct`
  by default; override `GOPROXY` if you have another preferred proxy.
