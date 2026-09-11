#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command_line_tools_home="${HUAWEI_COMMAND_LINE_TOOLS_HOME:-/Volumes/Doc/Library/Huawei/command-line-tools}"
deveco_home="${DEVECO_HOME:-${DEVECO_STUDIO_HOME:-}}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [[ -z "$deveco_home" ]]; then
  if [[ -d "/Volumes/Doc/Applications/DevEco-Studio.app/Contents" ]]; then
    deveco_home="/Volumes/Doc/Applications/DevEco-Studio.app/Contents"
  elif [[ -d "/Applications/DevEco-Studio.app/Contents" ]]; then
    deveco_home="/Applications/DevEco-Studio.app/Contents"
  fi
fi

sdk_home="${DEVECO_SDK_HOME:-}"
if [[ -z "$sdk_home" ]]; then
  if [[ -d "$command_line_tools_home/sdk/default/openharmony/native" ]]; then
    sdk_home="$command_line_tools_home/sdk"
  elif [[ -n "$deveco_home" && -d "$deveco_home/sdk/default/openharmony/native" ]]; then
    sdk_home="$deveco_home/sdk"
  fi
fi
[[ -n "$sdk_home" && -d "$sdk_home/default/openharmony/native" ]] || \
  fail "HarmonyOS SDK not found; set DEVECO_SDK_HOME or HUAWEI_COMMAND_LINE_TOOLS_HOME"

native_sdk="$sdk_home/default/openharmony/native"
clang="$native_sdk/llvm/bin/clang"
clangxx="$native_sdk/llvm/bin/clang++"
readelf="$native_sdk/llvm/bin/llvm-readelf"
sysroot="$native_sdk/sysroot"
[[ -x "$clang" && -x "$clangxx" && -d "$sysroot" ]] || fail "HarmonyOS Native SDK is incomplete at $native_sdk"

if [[ -f "$command_line_tools_home/hvigor/hvigor/bin/hvigor.js" ]]; then
  hvigor_home="$command_line_tools_home/hvigor/hvigor"
  ohos_plugin_home="$command_line_tools_home/hvigor/hvigor-ohos-plugin"
  node_bin="$command_line_tools_home/tool/node/bin/node"
elif [[ -n "$deveco_home" && -f "$deveco_home/tools/hvigor/hvigor/bin/hvigor.js" ]]; then
  hvigor_home="$deveco_home/tools/hvigor/hvigor"
  ohos_plugin_home="$deveco_home/tools/hvigor/hvigor-ohos-plugin"
  node_bin="$deveco_home/tools/node/bin/node"
else
  fail "Hvigor was not found; set HUAWEI_COMMAND_LINE_TOOLS_HOME or DEVECO_HOME"
fi
hvigor_js="$hvigor_home/bin/hvigor.js"
[[ -x "$node_bin" ]] || fail "Node.js was not found at $node_bin"
[[ -f "$ohos_plugin_home/package.json" ]] || fail "Hvigor OHOS plugin was not found at $ohos_plugin_home"

java_home="${JAVA_HOME:-}"
if [[ -z "$java_home" && -n "$deveco_home" ]]; then
  if [[ -d "$deveco_home/jbr/Contents/Home" ]]; then
    java_home="$deveco_home/jbr/Contents/Home"
  elif [[ -d "$deveco_home/jbr" ]]; then
    java_home="$deveco_home/jbr"
  fi
fi
if [[ -z "$java_home" && -x /usr/libexec/java_home ]]; then
  java_home="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
fi
[[ -n "$java_home" && -x "$java_home/bin/java" ]] || fail "JDK was not found; set JAVA_HOME"

apply_patch_if_needed() {
  local repository="$1"
  local patch_file="$2"
  if git -C "$repository" apply --reverse --check --ignore-space-change --ignore-whitespace "$patch_file" >/dev/null 2>&1; then
    return
  fi
  git -C "$repository" apply --check --ignore-space-change --ignore-whitespace "$patch_file" || \
    fail "Patch does not apply cleanly: $patch_file"
  git -C "$repository" apply "$patch_file" || fail "Failed to apply patch: $patch_file"
}

go_root="$project_root/third_party/ohos-go"
go_bin="$go_root/bin/go"
apply_patch_if_needed "$go_root" "$project_root/patches/ohos-go-openharmony.patch"
if [[ ! -x "$go_bin" ]]; then
  [[ -f "$go_root/src/make.bash" ]] || fail "third_party/ohos-go is missing"
  command -v go >/dev/null 2>&1 || fail "Host Go is required to bootstrap third_party/ohos-go"
  bootstrap_goroot="${GOROOT_BOOTSTRAP:-$(go env GOROOT)}"
  mkdir -p "$project_root/.tools/bootstrap-gocache"
  (
    cd "$go_root/src"
    GOROOT_BOOTSTRAP="$bootstrap_goroot" \
      GOTOOLCHAIN=local \
      GOCACHE="$project_root/.tools/bootstrap-gocache" \
      ./make.bash
  )
fi
[[ -x "$go_bin" ]] || fail "OpenHarmony Go bootstrap failed"

apply_patch_if_needed "$project_root/third_party/tailscale" "$project_root/patches/tailscale-ohos.patch"

output_dir="$project_root/native/go_bridge/dist/arm64-v8a"
hap_lib_dir="$project_root/entry/libs/arm64-v8a"
tailscale_version="$(/usr/bin/awk '$1 == "tailscale.com" { version = $2 } $1 == "require" && $2 == "tailscale.com" { version = $3 } END { sub(/^v/, "", version); print version }' "$project_root/native/go_bridge/go.mod")"
[[ -n "$tailscale_version" ]] || fail "Tailscale version is missing from native/go_bridge/go.mod"
mkdir -p "$output_dir" "$hap_lib_dir"

export GOROOT="$go_root"
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
export GOTOOLCHAIN=local
export GOCACHE="$project_root/.tools/gocache-ohos"
export GOMODCACHE="$project_root/.tools/gomodcache"
export GOPATH="$project_root/.tools/gopath"
export CC="$clang --target=aarch64-linux-ohos --sysroot=$sysroot -D__MUSL__"
export CXX="$clangxx --target=aarch64-linux-ohos --sysroot=$sysroot -D__MUSL__"
mkdir -p "$GOCACHE" "$GOMODCACHE" "$GOPATH"

(
  cd "$project_root/native/go_bridge"
  "$go_bin" build -buildmode=c-shared -trimpath \
    "-ldflags=-extldflags=-Wl,-soname,libtailscale_go.so -X tailscale.com/version.longStamp=$tailscale_version -X tailscale.com/version.shortStamp=$tailscale_version" \
    -o "$output_dir/libtailscale_go.so" .
)
cp -f "$output_dir/libtailscale_go.so" "$hap_lib_dir/libtailscale_go.so"
cp -f "$output_dir/libtailscale_go.h" "$hap_lib_dir/libtailscale_go.h"

ohpm="$command_line_tools_home/ohpm/bin/ohpm"
[[ -x "$ohpm" ]] || ohpm="$(command -v ohpm || true)"
[[ -n "$ohpm" && -x "$ohpm" ]] || fail "ohpm was not found"
if [[ ! -d "$project_root/entry/oh_modules/@tailscale/common" ]]; then
  (
    cd "$project_root/entry"
    DEVECO_SDK_HOME="$sdk_home" OHOS_SDK_HOME="$sdk_home" "$ohpm" install --all
  )
fi

[[ -f "$project_root/build-profile.json5" ]] || \
  fail "build-profile.json5 is missing; copy build-profile.example.json5 first"

tooling_scope="$project_root/.tooling/node_modules/@ohos"
mkdir -p "$tooling_scope"
ln -sfn "$hvigor_home" "$tooling_scope/hvigor"
ln -sfn "$ohos_plugin_home" "$tooling_scope/hvigor-ohos-plugin"

export JAVA_HOME="$java_home"
export DEVECO_SDK_HOME="$sdk_home"
export OHOS_SDK_HOME="$sdk_home"
export HVIGOR_USER_HOME="$project_root/.hvigor-user"
export NODE_PATH="$hvigor_home:$hvigor_home/node_modules:$ohos_plugin_home/node_modules:$project_root/.tooling/node_modules"
export PATH="$java_home/bin:$command_line_tools_home/bin:$command_line_tools_home/ohpm/bin:$command_line_tools_home/tool/node/bin:$PATH"

"$node_bin" "$hvigor_js" --mode module -p module=entry@default -p product=default assembleHap --no-daemon

hap="$project_root/entry/build/default/outputs/default/entry-default-unsigned.hap"
[[ -f "$hap" ]] || fail "Hvigor completed but the unsigned HAP was not found"

header="$($readelf -h "$output_dir/libtailscale_go.so")"
printf '%s\n' "$header" | /usr/bin/grep -Eq 'Machine:.*AArch64' || fail "Go library is not AArch64"
printf '%s\n' "$header" | /usr/bin/grep -Eq 'Type:.*DYN' || fail "Go library is not an ELF shared object"
dynamic="$($readelf -d "$output_dir/libtailscale_go.so")"
printf '%s\n' "$dynamic" | /usr/bin/grep -Eq 'SONAME.*libtailscale_go\.so' || fail "Go library has no expected SONAME"

hap_entries="$(/usr/bin/unzip -l "$hap")"
for required_entry in \
  'libs/arm64-v8a/libtailscale_go.so' \
  'libs/arm64-v8a/libtailscale_ohos.so' \
  'ets/modules.abc' \
  'module.json'; do
  printf '%s\n' "$hap_entries" | /usr/bin/grep -Fq "$required_entry" || fail "HAP is missing $required_entry"
done

printf 'Built and verified unsigned HarmonyOS HAP on macOS:\n%s\n' "$hap"
printf 'Go library:\n%s\n' "$output_dir/libtailscale_go.so"
