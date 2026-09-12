# Tailscale for HarmonyOS NEXT

This repository is a working native HarmonyOS NEXT port of the Tailscale
userspace client. It is currently an engineering MVP, not a release-ready
consumer application.

## Current milestone

The project now provides a signed ArkTS application with this native stack:

```text
ArkTS UI / VpnExtensionAbility
  -> C++ Node-API bridge
  -> OpenHarmony arm64 Go c-shared library
  -> Tailscale v1.102.4 userspace engine
  -> HarmonyOS vpn-tun file descriptor
```

Verified on a HarmonyOS 6.1 phone:

- persistent browser login and restart without re-authentication;
- strict control-plane TLS, system roots, DNS, and TCP access;
- HarmonyOS VPN authorization and virtual-interface creation;
- an external `tun.Device` adapter feeding wireguard-go;
- backend state `Running` with `tun=true`;
- bidirectional system-browser packets through the TUN;
- an identity-redacted TSMP probe to an online tailnet peer;
- connect, disconnect, backend recovery, and reconnect without logging in again.
- stale VPN-state detection and persistent-backend recovery after a device reboot;
- VPN survival across screen-off and Wi-Fi loss/reassociation, with a live heartbeat;
- control-plane-approved subnet routes passed into the HarmonyOS VPN config,
  with `RouteAll` explicitly enabled to match Tailscale's mobile/Windows
  `--accept-routes` behavior on the OpenHarmony Go runtime;
- full behind-router subnet delivery through a temporary approved `/32`,
  verified by the injected-route count, HarmonyOS TUN deltas, anonymous
  Windows router peer deltas, and successful browser traffic; the temporary
  route and Windows forwarding changes were removed after the test;
- exit-node discovery and selection before connecting, with a safe empty state
  when the tailnet offers no eligible exit node;
- real public-IP traffic through an approved Windows exit node, verified from
  both the HarmonyOS TUN counters and anonymous Windows peer byte counters;
- exit-node choice restored across UI-to-Extension handoff and repeated signed
  HAP replacement installs without requiring the user to select it again.

MagicDNS support is currently disabled. The HarmonyOS VPN configuration does
not publish Tailscale DNS servers or search domains, and peer actions expose
Tailscale IP addresses only.

TODO(LiveView): add the opt-in Tailscale traffic LiveView only after the
application has received the official HarmonyOS LiveView entitlement and an
approved `event` scenario. The VPN Extension should own the start/update/stop
lifecycle, serialize updates at no more than 1 Hz, use the standalone Tailscale
nine-dot mark, and expose only current-session upload/download byte totals.
Until the entitlement is available, do not show a non-functional LiveView
switch in Settings.

The bilingual Chinese/English UI uses the SDK 23 HDS floating bottom navigation
with immersive system material. Home owns connection state, the single
`Connect` / `Disconnect` action, exit-node selection, the read-only peer view,
Settings owns persistent disconnected-state controls for subnet-route acceptance,
LAN access while using an exit node, the four-level
immersive-glow preference, and account management. Connected-state
network controls become read-only so changing VPN routes never produces a
partially updated live tunnel. A confirmation-guarded logout action is
available only while disconnected. Lower-level probes remain behind a
collapsed engineering-diagnostics control on the Settings page.
The destructive logout action is intentionally not exercised by automated
real-device regression checks.

This project intentionally does not request or implement application
auto-start. After a device reboot, the app rejects the previous session's stale
heartbeat and restores the authenticated backend safely when opened; the user
then reconnects the system VPN from the app.

The device service center also contains an on-demand Jellyfin, Emby, and Plex
probe plus a disabled-by-default HosPlayer handoff prototype. See
[`docs/hosplayer-integration-prototype.md`](docs/hosplayer-integration-prototype.md)
for the parameter contract, privacy rules, and server-free engineering test.

## Important port details

- The OpenHarmony Go port uses Linux build tags, but application processes
  cannot use tailscaled's Linux socket-mark/netns bypass. The bridge disables
  that path with `netns.SetEnabled(false)`.
- `tsnet.Server` has a small local patch allowing an externally owned
  `tun.Device`; netstack does not consume peer or subnet traffic in that mode.
- HarmonyOS owns interface and route creation. The route interface name must be
  the platform-defined `vpn-tun`, as documented by the
  [OpenHarmony VPN Extension guide](https://gitee.com/openharmony/docs/blob/08986484ea997e1da01ac9221d20dbb0a54b4922/en/application-dev/network/net-vpnExtension.md).
- The VPN Extension restores the persistent backend inside its own process,
  then restarts the engine with the HarmonyOS TUN descriptor.
- Status and test results deliberately omit auth URLs, node identities,
  tailnet addresses, keys, and signing information.
- The control-plane machine name is derived from HarmonyOS `marketName` (with
  `productModel` as fallback), and build metadata reports Tailscale `1.102.4`
  with `Linux HongMeng Kernel Build 1.12.0` as the OS build line.

## Build and real-device checks

Host regression checks for network-change scheduling and VPN lifecycle logic:

```bash
node --test scripts/test-vpn-lifecycle.cjs
```

The tests use DevEco Studio's TypeScript compiler on macOS. Set
`TYPESCRIPT_PATH` to your installed `typescript.js` on other setups. They execute
the ArkTS service and VPN Extension methods with a simulated clock and mocked
platform APIs; they do not replace an ArkTS/HAP build or physical-device tests.

Network changes are coalesced for 750 ms with a 3-second maximum debounce wait,
serialized with a minimum 3-second start interval, and retried at most three
times after failure without a new network event. Events received during native
work remain pending until it finishes. Shutdown cancels pending work.
The UIAbility owns continuous-task requests; the VPN Extension does not call
the UIAbility-only background-task API. This is not a guarantee that destroying
the UI process preserves the VPN process; verify the OS VPN lifecycle on device.

The Extension polls requests and incoming notifications every second, and
refreshes its full snapshot and independent heartbeat every five seconds.
Readers share freshness limits, including a longer cold-start heartbeat
confirmation window. These changes reduce scheduled polling work, but measured
standby battery savings and cellular reliability still require device testing:

- Repeat Wi-Fi to cellular and cellular to Wi-Fi switches during traffic;
  include airplane-mode recovery and a network that requires DERP relay.
- Repeat with the screen off for 30 minutes, then overnight; check outbound
  and inbound application traffic and recovery latency after waking.
- Check background-task grant/cancellation and separately test swiping away
  the UI; a persisted `Running` string alone is not proof of a live tunnel.
- Compare equal-duration unplugged standby runs with VPN off/on under similar
  signal strength. Record battery change, CPU time, wakeups and traffic volume;
  avoid continuous pings during the power measurement.

The application baseline is HarmonyOS 6.1 / SDK 23 for both compatible and
target SDK versions. Run from PowerShell with one USB phone connected:

```powershell
scripts\build.ps1
scripts\device-engine-probe.ps1
scripts\device-backend-probe.ps1
```

After `Connect Tailscale` reports a running tunnel, validate real application
traffic and the optional online-peer probe:

```powershell
scripts\device-vpn-data-probe.ps1
scripts\device-exit-node-probe.ps1
scripts\device-user-ui-probe.ps1 -SkipInstall
```

The UI probe rejects a locked device explicitly, visits Home and Settings,
checks the home Exit Node section, all three glow choices and the engineering
menu, validates that the three connection controls remain on Home and are
editable only while disconnected, and never activates the logout action.

The scripts discover DevEco Studio from `DEVECO_STUDIO_HOME`, `DEVECO_HOME`, or
its standard Windows install location. The OpenHarmony SIG Go source tree and
bootstrap tools are generated local dependencies and are excluded from Git.
The real `build-profile.json5` is also local-only so signing paths and material
cannot be committed accidentally; `build-profile.example.json5` documents the
non-sensitive project shape. Configure local HarmonyOS signing before running
the signed-HAP and HDC workflow.

On macOS, the same HarmonyOS project can be built with the downloaded Command
Line Tools. `scripts/build-macos.sh` discovers the SDK, Hvigor, Node.js, JDK,
OpenHarmony Go toolchain, and local `@tailscale/common` module, then builds and
verifies an arm64 unsigned HAP:

```bash
scripts/build-macos.sh
```

The default Command Line Tools location is
`/Volumes/Doc/Library/Huawei/command-line-tools`; override it with
`HUAWEI_COMMAND_LINE_TOOLS_HOME` or set `DEVECO_SDK_HOME` explicitly. This is a
HarmonyOS HAP built on a Mac, not a macOS `.app`. Add local signing configuration
to the ignored `build-profile.json5` before installing it on a device.

The Tailscale userspace engine is updated to the latest upstream release
`v1.102.4`. Its module requires Go `1.26.6`, so this repository uses the
OpenHarmony SIG `release-branch.go1.26` source plus the tracked
`patches/ohos-go-openharmony.patch` port.

To update the Tailscale userspace engine, fetch a new upstream tag, temporarily
reverse the current HarmonyOS patch, check out the new tag, apply and rebase the
patch, then update the `tailscale.com` version in
`native/go_bridge/go.mod`. Regenerate the tracked patch after resolving any
conflicts:

```bash
git -C third_party/tailscale fetch --tags origin
git -C third_party/tailscale apply --reverse ../../patches/tailscale-ohos.patch
git -C third_party/tailscale switch --detach vX.Y.Z
git -C third_party/tailscale apply ../../patches/tailscale-ohos.patch
git -C third_party/tailscale diff --binary > patches/tailscale-ohos.patch
```

Before building a release that raises Tailscale's Go requirement, use a
matching OpenHarmony Go branch, apply `patches/ohos-go-openharmony.patch`, and
regenerate that patch from the clean branch. The Go bridge build embeds the
version from `native/go_bridge/go.mod`. The HarmonyOS patches are platform
code, not upstream release artifacts, so every version update must be
compiled and tested again.

## Roadmap to a distributable client

1. Extend lifecycle and network-transition soak tests from minutes to hours.
2. Review state-file protection, privacy disclosures, logging, resource use,
   signing, and AppGallery policy requirements.
3. Rebase the minimal Tailscale changes onto an upstreamable platform layer and
   add CI for Go, C++, ArkTS, packaging, and physical-device regression tests.
