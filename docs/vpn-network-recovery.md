# VPN network recovery

This change integrates the network-recovery contribution from
[charleypeng's original PR #11](https://github.com/flypigJ/Tailscale-OHOS/pull/11)
with the current application's background-task implementation.

The reported scenario is a phone on cellular data connecting to a computer on
Wi-Fi. The initial baseline established a direct IPv6 path. Later in the session,
the reported relay behavior was reproduced on the then-current Wi-Fi network.
Both sides reported destination-dependent NAT mapping; only the phone had usable
public IPv6. The application must recover after network changes while continuing
to report relays honestly when the physical networks cannot establish a direct path.

## Problems addressed

- The VPN process did not forward the system's default-network changes to the Go
  backend. In the sandbox, kernel route visibility is insufficient to reliably
  distinguish the active physical interface after a Wi-Fi/cellular handover.
- The existing peer-path query sent one discovery ping. Its early DERP answer
  could be cached for 25 seconds before UDP hole punching completed. The UI's
  2.5-second deadline was also shorter than the native status-plus-ping budget.
- PR #11 added a network bridge, but consumed events received while a native
  rebind was pending. It also replaced the local background-task logic with a
  version that could undo user cancellation and stop protection after one
  uncertain status read.

## Implementation

`VpnNetworkMonitor` lives in the VPN extension process. It registers default
network callbacks and reads `getDefaultNet()` plus connection properties and
capabilities. The official API excludes VPN networks. It verifies the default
network again after reading properties instead of selecting whichever interface
last emitted an event, or guessing from interface-name priority.

Events are coalesced, native calls are serialized and rate limited, and a revision
counter retains changes that arrive during awaited work. Failed registration or
refresh retries after five seconds. Disconnect/destruction removes listeners and
timers; stale asynchronous results cannot schedule work after shutdown. An empty
host route hint explicitly clears the previous route when offline.

The native bridge publishes the host route hint before resampling netmon, then
rebinds sockets and explicitly refreshes STUN. Tailscale 1.86's `DebugRebind` does
not itself request a new STUN sample. OpenHarmony behavior uses build tags because
the current Go port reports `runtime.GOOS` as `linux`. UDP prefers port 41641, as in
the original contribution. The PR's filtering of modem IMS, operator-anchor and
the app's own VPN interface keeps those addresses out of peer endpoint discovery.
Cached NAT diagnostics expose only UDP/IPv4/IPv6 availability, mapping variability
and the local UDP port. No interface addresses are added to diagnostic logs, and
reading status does not trigger network probes.

Peer discovery now allows up to six attempts within a shared ten-second budget,
stopping as soon as a direct endpoint answers. Relays remain valid results if no
direct endpoint answers. The UI waits twelve seconds and retains transient results
for three seconds. A disconnected VPN cannot return a cached direct path. Native
sent/received/loss counts reflect the actual attempts, and the displayed direct
latency comes from the direct response rather than an average including DERP.

The current background protection is retained: early foreground acquisition,
real traffic updates on the system live view, a bounded telemetry grace period,
serialized cleanup, retry backoff and respect for explicit user cancellation.
See [background VPN reliability](background-vpn-reliability.md).

This integration stays on the verified Tailscale 1.86.5 / Go 1.24.5 baseline.
PR #11's Go 1.26/Tailscale 1.102 port and API-20 UI changes are outside this bug-fix
scope. Its original commits remain in the PR history; they are not rewritten or
replaced by a cherry-picked copy. The merge resolution layers the selected,
corrected network contribution onto current main, preserving current UI features,
protocols, persisted state, build entry points and release metadata.

## Verification

- `node --test scripts/test-vpn-background-task.mjs scripts/test-vpn-network-monitor.mjs scripts/test-peer-path-cache.mjs`:
  24 deterministic tests passed. These cover changes during an in-flight rebind,
  stale network-property reads, same-interface network/address changes, offline
  recovery, retries, shutdown cleanup, transient relay caching and the existing
  background lifecycle/cancellation races.
- Repository Debug compilation, AArch64 Go/N-API HAP checks and the exported
  `TSBackendNetworkChanged` symbol passed. The integration patch passes forward
  validation against a pristine v1.86.5 index and reverse validation against the
  patched dependency tree.
- Existing real-device baseline: phone on cellular, computer on Wi-Fi; a direct
  IPv6 discovery response arrived in 85 ms before installing this fix.
- The Go `TestHarmonyProblematicInterfaces` test passed: modem/anchor/overlay
  interfaces are excluded while real cellular, Ethernet, Wi-Fi and tethering
  interfaces remain eligible.
- The phone's published endpoint list contained zero overlay or operator-anchor
  candidates after the final build. This was checked from the computer's cached
  network map without sending an additional peer probe.
- The final Debug HAP was installed successfully, preserving login and user data.
  It uses the phone's existing local-test code `100000004`; repository metadata
  `100000003` was restored byte for byte. No uninstall, Release build or upload.
- The final build logged cellular → Wi-Fi → cellular rebinds within the same VPN
  traffic session. Returning to Wi-Fi automatically restored direct connectivity
  in an 11 ms discovery response, without reconnecting VPN. Browser-generated TUN
  traffic passed on both networks: +142/+142 packets on Wi-Fi and +12/+20 on
  cellular; the identity-redacted TSMP probe was reachable.
- On the reproduced cellular/Wi-Fi path the phone reported UDP=true, IPv4=true,
  IPv6=true, MappingVaries=true, localPort=41641. The computer reported UDP=true,
  IPv4=true, IPv6=false, MappingVaries=true, and no UPnP/NAT-PMP/PCP mapping. Its
  Wi-Fi adapter had IPv6 enabled but only a link-local address. Six discovery
  responses used DERP. This is consistent with hard NAT at both ends and no shared
  public IPv6 path; it is not evidence that app code can make this pair direct.
- The uninterrupted 720-second cellular lock test was **not completed**. Two runs
  recorded sleeping-state samples through 279 and 309 seconds respectively, with
  the same UI/VPN processes and fresh heartbeats, then the screen woke. The system reported
  `PICKUP` for the second interruption. The user requested skipping the subsequent
  retry, which was stopped. These runs are not counted as a continuous-lock pass.
  All device work used USB/HDC with charging; battery-only idle is untested.

Tailscale documents these limits in [device connectivity](https://tailscale.com/docs/reference/device-connectivity)
and [IPv6 support](https://tailscale.com/docs/concepts/ipv6). A reachable UDP mapping
on one side, or usable public IPv6 at both ends, is needed to overcome this observed
network constraint. No router, firewall or system network policy was changed.

Raw device layouts and endpoint-bearing baseline output stay under ignored
`.codex/vpn-recovery-20260923/`; do not publish them. New diagnostic network events
contain only the bearer category and numeric error code.

## Official API reference

The official HarmonyOS Knowledge MCP documentation was consulted before using
these APIs: [Network connection](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-connection)
and [background tasks](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-resourceschedule-backgroundtaskmanager).
The selected APIs and normal `GET_NETWORK_INFO` permission fit the existing API 23
minimum and Stage phone/tablet/2in1 scope. No API-24-only link-validity fields are
required.
