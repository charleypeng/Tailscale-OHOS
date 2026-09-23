#!/bin/bash
# macOS port of scripts/build-go.ps1:
# builds the Tailscale v1.86.5 engine as an OpenHarmony arm64 c-shared library.
#
# Note: GOROOT prefers ~/.ohos-go-build/ohos-go (internal APFS disk). Building or
# self-hosting the toolchain from the project volume (/Volumes/nvme11-...) hits
# SIGBUS when freshly written binaries are mmapped for execution, so the toolchain
# bootstrap and all caches live on the internal disk. The selected source trees
# receive the integration patches; the final .so and .h are copied back.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- locate the OHOS Go toolchain (internal-disk build first) ---
go_root="${OHOS_GO_ROOT:-$HOME/.ohos-go-build/ohos-go}"
go_bin="$go_root/bin/go"
if [[ -z "${OHOS_GO_ROOT:-}" && ! -x "$go_bin" ]]; then
  go_root="$project_root/third_party/ohos-go"
  go_bin="$go_root/bin/go"
fi

# --- locate DevEco Studio and its bundled native SDK ---
# (macOS app bundles have no product-info.json; the sdk directory is the marker)
if [[ -n "${DEVECO_STUDIO_HOME:-}" && -d "$DEVECO_STUDIO_HOME/sdk" ]]; then
  deveco_home="$DEVECO_STUDIO_HOME"
elif [[ -d "/Applications/DevEco-Studio.app/Contents/sdk" ]]; then
  deveco_home="/Applications/DevEco-Studio.app/Contents"
else
  echo "DevEco Studio was not found. Set DEVECO_STUDIO_HOME to its installation directory." >&2
  exit 1
fi

sdk_home="${DEVECO_SDK_HOME:-$deveco_home/sdk}"
native_sdk="$sdk_home/default/openharmony/native"
if [[ ! -d "$native_sdk" ]]; then
  echo "HarmonyOS Native SDK was not found at $native_sdk" >&2
  exit 1
fi
clang="$native_sdk/llvm/bin/clang"
clangxx="$native_sdk/llvm/bin/clang++"
sysroot="$native_sdk/sysroot"

output_dir="$project_root/native/go_bridge/dist/arm64-v8a"
hap_lib_dir="$project_root/entry/libs/arm64-v8a"
mkdir -p "$output_dir" "$hap_lib_dir"

if [[ ! -x "$go_bin" ]]; then
  echo "The OpenHarmony Go toolchain has not been built yet (missing $go_bin)." >&2
  echo "Bootstrap it first:  cd <ohos-go>/src && GOROOT_BOOTSTRAP=<go1.24.5> GOTOOLCHAIN=local ./make.bash" >&2
  exit 1
fi

# --- apply patches (idempotent, mirrors the PowerShell reverse-check) ---
apply_patch() {
  local repo="$1" patch="$2"
  if [[ ! -f "$patch" ]]; then
    echo "Missing patch: $patch" >&2
    exit 1
  fi
  if git -C "$repo" apply --reverse --check --ignore-space-change --ignore-whitespace "$patch" 2>/dev/null; then
    echo "Patch already applied: $patch"
  else
    git -C "$repo" apply --ignore-space-change --ignore-whitespace "$patch"
    echo "Applied patch: $patch"
  fi
}
apply_patch "$go_root" "$project_root/patches/ohos-go-interface-resources.patch"
apply_patch "$project_root/third_party/tailscale" "$project_root/patches/tailscale-ohos.patch"

# --- build the c-shared library ---
export GOROOT="$go_root"
export PATH="$go_root/bin:$PATH"
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
export GOTOOLCHAIN=local
# caches on the internal disk: fast, and safe for mmap-heavy go tooling
export GOCACHE="$HOME/.ohos-go-build/gocache-ohos"
export GOMODCACHE="$HOME/.ohos-go-build/gomodcache"
export GOPATH="$HOME/.ohos-go-build/gopath"
# goproxy.cn keeps module downloads working without a global proxy
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
export CC="\"$clang\" --target=aarch64-linux-ohos --sysroot=\"$sysroot\" -D__MUSL__"
export CXX="\"$clangxx\" --target=aarch64-linux-ohos --sysroot=\"$sysroot\" -D__MUSL__"

cd "$project_root/native/go_bridge"
go build -buildmode=c-shared -trimpath \
  -ldflags="-extldflags=-Wl,-soname,libtailscale_go.so -X tailscale.com/version.longStamp=1.86.5 -X tailscale.com/version.shortStamp=1.86.5" \
  -o "$output_dir/libtailscale_go.so" .

cp -f "$output_dir/libtailscale_go.so" "$hap_lib_dir/libtailscale_go.so"
cp -f "$output_dir/libtailscale_go.h" "$hap_lib_dir/libtailscale_go.h"
echo "Built: $output_dir/libtailscale_go.so"
