# Status

## 2026-09-18 - VPN background keep-alive and cellular direct-path fixes

- Replaced the `multiDeviceConnection` background mode with `dataTransfer` and gave `KEEP_BACKGROUND_RUNNING` a `reason` plus `usedScene`, matching Huawei's VPN keep-alive guidance. The VPN extension process is frozen or killed in the background while the app declares a distributed multi-device business it does not run.
- Rewrote `VpnBackgroundTaskManager` as a module-level singleton that only accepts a `UIAbilityContext`, is driven by `EntryAbility` (`onCreate`/`onBackground`/`onForeground`), refreshes the `dataTransfer` task every four minutes, observes `continuousTaskCancel`/`continuousTaskSuspend`/`continuousTaskActive`, and does not re-request the task within the session that the user or the system cancelled. The VPN extension no longer requests a continuous task at all, because a `VpnExtensionContext` cannot own one; its status file is the only channel it has.
- Bound `BridgeStatus.vpnStatus` to a `@Watch` handler so a session that starts while the UI is foregrounded also arms the keep-alive task, and added the bounded session probe that covers connecting and backgrounding the app in the same moment.
- Pinned the engine's UDP port to 41641 through `tsnet.Server.Port`, so the carrier NAT keeps a stable external mapping and magicsock can offer its `<public IP>:<local port>` hard-NAT candidate.
- Added the HarmonyOS netmon port: `UpdateLastKnownDefaultRouteInterface` with a `/proc/net/route` -> netlink -> host-hint fallback chain, a build-tag-driven `isHarmonyOS` constant (`runtime.GOOS` is `"linux"` under OpenHarmony, so the obvious runtime comparison is silently dead), and interface filtering for the IMS, operator-anchor, and virtual bearers. The VPN extension reports `ConnectionProperties.interfaceName` through a new `backendSetDefaultRouteInterface` NAPI call before it triggers a network-change notification, and `networkChanged()` routes through `tsnet.NotifyNetworkChange`, which resamples netmon before rebinding.
- Regenerated `patches/tailscale-ohos.patch` (10 files) so the build's reverse-check stays consistent with the tree.
- Verification: `scripts/build-macos.sh` completed successfully and produced the HAP plus the AArch64 Go library. The packaged `module.json` reports `backgroundModes: ["dataTransfer"]` and a `KEEP_BACKGROUND_RUNNING` entry carrying `reason`/`usedScene`; the CGO header exports `TSBackendSetDefaultRouteInterface`. On-device acceptance (long-task notification, multi-hour idle survival, cellular handover latency) still needs a debug profile for `io.github.tailscaleohos`.

## 2026-08-11 - Files immersive title-bar actions and toolbar spacing

- Kept Settings on the scroll-linked `HdsNavigationTitleMode.FREE` mode and moved the Files multi-select and search actions into the large Files HDS title bar.
- Added the official 6.1.0(23) `IMMERSIVE_GRADIENT_BLUR` plus adaptive `systemMaterialEffect`, bound the standalone Files navigation to its content scroller, and kept the active search/selection fields available below the title bar.
- Tightened the four normal bottom actions to a centered group with 6vp internal spacing and 30vp side insets; added the localized title-bar search action resource.
- Verification: `scripts/build.ps1` built the native Go library and reached ArkTS compilation, but the existing dirty worktree remains blocked by 17 missing `transfer_remote_*` resource names in `BridgeStatus.ets`; no error was reported at the new Files HDS configuration lines and no device install was performed.

## 2026-08-11 - Unified MeshSend file-transfer entry

- Replaced parallel device-detail entries with one “发送文件” action. It computes `tailsend`/`localSend` capabilities, reuses the persisted transport choice when possible, and opens a bottom sheet when both are available.
- Merged LocalSend-only peers into the same Transfer target list; the existing Taildrop file/media/text, receive inbox, progress, and history flow remains intact. Taildrive stays on the separate Files page.
- Added `mesh_arc_file_transfer` preference storage and a “more” action on dual-capability targets so users can switch channels without adding another device-card button.
- Verification: bilingual resource JSON parsing and scoped whitespace checks passed; `scripts/build.ps1 -Product default` completed successfully, produced a signed HAP, and passed the AArch64 Go/N-API artifact check. Existing ArkTS capability/exception warnings remain. LocalSend external launch still needs its official HarmonyOS bundle/Want contract and is not guessed.

## 2026-08-11 - Align Settings and Files title surfaces

- Restored the Settings page's scroll-linked `HdsNavigationTitleMode.FREE` title behavior so its large title contracts while the page scrolls.
- Moved the Files page title into the same immersive HDS title bar used by Home, Transfer, and Settings, bound it to the file content scroller, and removed the duplicate in-content title/top safe-area offset.
- Verification: `scripts/build.ps1` reached ArkTS compilation but remains blocked by pre-existing unfinished Taildrive/navigation changes (`TaildriveBrowser.ets` untyped object literal and missing resource names, plus `BridgeStatus.ets` missing `saveNavigationPreferences`); no error was reported at the new title-mode or Files HDS title configuration lines.

## 2026-08-11 - Separate MeshSend transfer surfaces

- Split the Transfer page into a MeshSend/LocalSend discovery section and a MeshSend/Taildrop section backed by the existing Tailscale send, receive inbox, progress, and history flow.
- Added separate MeshSend (LocalSend) and MeshSend (Taildrop) service rows to the device-detail half-modal; each entry returns to the matching Transfer section and briefly highlights the selected device.
- Kept LocalSend copy explicit that the page reports discovered LocalSend services while LocalSend handles the actual send operation; no new transfer protocol or persistence format was introduced.
- Verification: bilingual resource JSON parsed successfully and scoped whitespace checks passed. `scripts/build.ps1 -Product default` reached ArkTS compilation but remains blocked by pre-existing navigation/Taildrive errors (`BridgeStatus.ets:712` missing `loadNavigationPreferences`, one untyped object literal in `TaildriveBrowser.ets`, and 16 missing Taildrive resource names); no error was reported at the new transfer-section or device-detail lines.

## 2026-08-11 - Remote files native long-press interaction pass

- Added touch haptics for breadcrumb navigation, multi-select actions, selection toggles, and the native long-press context menu; declared the required `ohos.permission.VIBRATE` permission.
- Replaced the file overflow dots and direct long-press selection with an ArkUI context menu that presents the selected item preview plus download, multi-select, move, rename, details, and delete actions as applicable.
- Replaced inline new-folder editing with a centered, keyboard-focused folder-name dialog whose suggested name is selected and whose cancel/confirm actions match the system file-manager flow.
- Changed successful in-app operation messages for upload, download, delete, create, rename, and move to disappear after five seconds; system notification behavior remains unchanged.
- Restored the individually frosted floating bottom controls: new folder, upload, a centered sort pill, and the list/grid arrangement button.
- Verification: `scripts/build.ps1` completed successfully and the signed default HAP passed the existing AArch64 Go/N-API artifact verification. Interactive acceptance remains assigned to the user.

## 2026-08-11 - Remote files compact desktop-style interaction pass

- Restored a runtime-derived top safe-area inset, reduced the breadcrumb/back/refresh footprint, and moved the Files page's horizontal spacing into the browser so full-width overlays are no longer clipped by the page container.
- Replaced the floating uneven controls with a four-column adaptive blurred toolbar for new folder, upload, sort, and layout; list/grid content now scrolls behind it with sufficient end offset instead of being truncated.
- Changed new-folder creation to an editable first item in the current list or grid, and replaced the file overflow button's inert details action with a native menu for details, download, rename, move, and delete.
- Tightened list rows and introduced a four-column lazy grid with group headers; the default is now modified-time descending with date grouping.
- Reworked the sort/group surface as a full-width in-page bottom panel without a full-screen dim layer, and made sort/group selection emphasis depend directly on observable draft state.
- Preserved the selected source timestamp in app-private staging and forwarded `Last-Modified` plus `X-OC-Mtime` on upload. The current Tailscale Windows WebDAV server may still ignore these headers because its protected `getlastmodified` property cannot be changed by clients.
- Verification: bilingual resource JSON parsed successfully; OpenHarmony Go formatting and cross-build succeeded; `scripts/build.ps1` completed successfully; the signed default HAP passed AArch64 Go/N-API artifact verification. Interactive acceptance is intentionally left to the user.

## 2026-08-11 - Remote files UI interaction corrections

- Corrected the standalone remote-files page so its content is top-aligned below the HDS title area instead of vertically centered.
- Added clickable Taildrive breadcrumb segments, a centered vector back button, and an app-level back request that moves up one remote directory; the root directory still allows the system to leave the app.
- Made sort/group choices apply immediately, added bottom safe-area padding to the sort/group half-modal, and kept sort direction plus type/date grouping available.
- Verification: bilingual resource JSON and new SVG assets parsed successfully; `scripts/build.ps1` completed successfully; the signed default HAP passed AArch64 Go/N-API artifact verification. Per the user's request, this correction was not re-installed to the device.

## 2026-08-11 - Show LocalSend in device connection status

- Exposed the background LocalSend probe result through each backend peer summary, including `checking`, `available`, `unavailable`, and `offline` states plus the detected protocol, port, and version.
- Added a LocalSend row to the device Connection status panel so the Home device detail immediately distinguishes Tailscale reachability from an actual LocalSend service.
- Kept old persisted peer snapshots compatible by treating a missing LocalSend field as an unknown/checking state.
- Verification: Linux/amd64 Go test binaries compiled successfully; native `vpnroute` tests passed; bilingual resource JSON parsed successfully; `scripts/build.ps1 -Product default` completed successfully; the signed AArch64 Go/N-API HAP passed artifact verification.

## 2026-08-11 - LocalSend-aware MeshArc device synchronization

- Restricted MeshArc device publication to online Tailscale peers whose `53317` service answers the LocalSend v2 `/api/localsend/v2/register` discovery request.
- Probes travel through `tsnet.Server.Dial`, run concurrently with bounded per-peer timeouts, prefer HTTPS, fall back to HTTP, and require valid LocalSend `alias`, `version`, and `fingerprint` response fields before a device is published.
- Uses the probed protocol and LocalSend metadata in the MeshArc array while keeping the receiver's 10-second full-list heartbeat and 45-second expiry behavior.
- Verification: Linux/amd64 Go test binaries compiled successfully; native `vpnroute` tests passed; `scripts/build.ps1 -Product default` completed successfully; the signed AArch64 Go/N-API HAP passed artifact verification. Runtime probing against a real LocalSend peer remains pending.

## 2026-08-11 - MeshArc remote device synchronization

- Added a generation-bound Go worker that immediately and then every 10 seconds publishes the current online Tailscale peers to `http://127.0.0.1:53317/api/mesharc/devices` as the documented full JSON array.
- Mapped peer identity, Tailscale address, device type, fingerprint, and model to the MeshArc contract; the updated default model is `MeshArc`, and `alias` remains the peer's human-readable name without adding a receiver-specific marker.
- Stopped the worker on backend disconnect or VPN restart, filtered offline/expired peers, and kept transient status failures from replacing the receiver's last successful list prematurely.
- Added Go contract tests for filtering, defaults, metadata mapping, JSON POSTs, and non-success responses.
- Verification: Linux/amd64 Go test binaries compiled successfully; Windows cannot execute those Linux binaries, so runtime unit-test execution remains host-limited. `scripts/build.ps1 -Product default` completed successfully and `scripts/verify-artifacts.ps1` passed the signed AArch64 Go/N-API HAP check.

## 2026-08-10 - Dedicated remote files navigation page

- Moved the Taildrive browser out of the Transfer page into a dedicated Files page positioned between Transfer and Settings.
- Added matching Files navigation items for both the compact bottom bar and expanded vertical navigation, with a dedicated folder icon and localized label.
- Added an immersive Files navigation title surface and standalone Taildrive layout while preserving browsing, search, sorting, transfer, mutation, detail, retry, and notification behavior.
- Updated device-detail remote-file handoff to open Files directly and shifted all Settings-only cache polling/navigation logic from tab index 2 to index 3; Taildrop notification routes remain on Transfer at index 1.
- Verification: English/Chinese resources and the new SVG parsed successfully; `scripts/build.ps1` completed successfully; the signed default HAP passed AArch64 Go/N-API artifact verification.

## 2026-08-10 - Taildrive in-app file management baseline

- Added device-detail handoff into the matching Taildrive machine, while retaining the all-tailnet root as a safe fallback when the device has no visible share.
- Added current-folder search, directory-first sorting by name/modified time/size, modified timestamps, and WebDAV `Depth: 0` file/folder details including content type.
- Added cross-directory move within a share, guarded descendant destinations, rename/move/upload conflict prompts with explicit replacement, and retry actions for list, target lookup, transfer, and mutation failures.
- Added Taildrive transfer progress/completion/failure notifications through the app's existing notification permission, plus 24-hour best-effort cleanup for abandoned app-private staging directories.
- Extended the Go, C ABI, Node-API, and ArkTS bridge without changing existing request fields; overwrite is opt-in and uploads remain non-destructive by default.
- Verification: OpenHarmony Go arm64 cross-build succeeded; bilingual resource references and JSON passed validation; `scripts/build.ps1` completed successfully; the signed default HAP passed the existing AArch64 Go/N-API artifact verification. Runtime verification against a real Taildrive sharing node remains pending.

## 2026-08-10 — Device-first home interaction and UI

- Reworked the Home tab into a device directory: renamed it to Devices, separated this device, online peers, and offline peers, removed home-row IP addresses, capability badges, and inline service expansion, and kept the list height content-driven.
- Added a large device-detail surface with progressive service discovery, neutral task rows for Sunshine/Moonlight and detected media services, a Taildrive handoff to Transfer, and separate network/device information sections. No unimplemented FlowBoat Files partnership entry is presented as available.
- Simplified the connected network card to tailnet identity, live download/upload rates, and the active exit-node summary. Moved the local address, traffic totals, LAN setting state, and disconnect action into the Network sheet.
- Verification: targeted diff whitespace checks and UTF-8 resource JSON parsing passed. The normal non-Release `scripts/build.ps1` run stopped during the pre-existing OpenHarmony Go step because `native/go_bridge/taildrive.go` references the unfinished `marshalTaildriveStat`; ArkTS/Hvigor compilation was therefore not reached, and the unrelated Taildrive implementation was left unchanged as requested.

## 2026-08-10 — Native Taildrive remote file access

- Connected Tailscale's in-process `DriveForLocal` WebDAV filesystem to the existing external-TUN `tsnet.Server`; Taildrive traffic stays inside the Go/Tailscale core and does not re-enter HarmonyOS system VPN routing.
- Added native WebDAV list, download, upload, create-folder, rename/move, delete, progress, timeout, and cancellation operations. Remote paths and app-private staging paths are validated, downloads use atomic `.part` files, incomplete payloads are rejected, and uploads do not silently overwrite an existing remote item.
- Added asynchronous C/Node-API exports plus an ArkTS gateway that stages picker files without carrying file bytes through JSON or N-API.
- Added the Taildrive browser to the Transfer screen with tailnet/device/share navigation, file sizes, upload/download picker flows, mutation actions inside writable shares, progress display, cancellation, and localized errors.
- Verification: Tailscale patch reverse-application check passed; OpenHarmony Go cross-compilation succeeded; UTF-8 resource JSON validation passed; `scripts/build.ps1` completed successfully; the signed default HAP passed the existing AArch64 Go/N-API artifact verification.

## 2026-08-10 - Centralized release changelog workflow

- Moved release-note versions, dates, and bilingual change items into the single editable entry at `entry/src/main/ets/services/ReleaseChangelog.ets`.
- Added `scripts/verify-release-changelog.ps1`; `scripts/build.ps1 -Product release` now blocks before building when the first entry is empty or does not match `AppScope/app.json5`.
- Recorded the mandatory reminder-and-confirmation rule in the project `AGENTS.md` instructions.

## 2026-08-10 - First-open update changelog

- Added a large half-modal release-notes surface to the app shell, with a version timeline, current release details, scrollable change list, close action, and "Don't show again" action.
- The surface is checked after `BundleInfo` loads and is shown once per `versionName:versionCode`; the marker is stored in the app's private files directory so upgrades show a new release again without touching existing user data.
- Kept the existing first-run welcome dialog sequenced behind the release notes to avoid competing modal surfaces.
- Verification: direct Hvigor `assembleHap` completed successfully, and `scripts/verify-artifacts.ps1` passed the AArch64 Go/N-API HAP check. The wrapper `scripts/build.ps1` remains blocked before Hvigor because the existing Tailscale integration patch does not apply cleanly to the local third-party checkout.

## 2026-08-10 — Enable HosPlayer server import

- Replaced the disabled HosPlayer protocol prototype with the published `hosplayer://server/import` Deep Link.
- The link now sends only `protocolVersion`, `type`, `endpoint`, and `name`; server credentials remain excluded.
- Device media actions now call `UIAbilityContext.openLink(..., { appLinkingOnly: false })` directly instead of showing the prototype dialog.
- Updated the offline contract check, engineering copy action, and integration documentation for `/server/import` and `endpoint=`.
- Verification: the default signed HAP built successfully; `scripts/verify-artifacts.ps1` passed the AArch64 Go/N-API check. Existing ArkTS warnings remain unchanged.

## 2026-08-04 — Release 0.9.10

- Built and signed the Release APP with `versionCode` `99000003` and `versionName` `0.9.10`.
- Release output passed the existing AArch64 Go/N-API HAP verification and contains `releaseType: Release` for API 23.
- Full visual review was skipped at the user's request; Hvigor emitted warnings only.

## 2026-08-04 — Restore system-browser login handoff

- Restored `UIAbilityContext.openLink` as the primary Tailscale login browser handoff.
- Kept the explicit `ohos.want.action.viewData` browser Want as a compatibility fallback.
- Removed the Release-sensitive custom `startAbilityByType` callback wrapper from the login path.
- Verification: `scripts/build.ps1` completed successfully and produced the signed default HAP.
- Host-side Go tests cannot run the HarmonyOS-specific `unix` implementation; `vpnroute` tests pass and the OpenHarmony cross-build succeeds.
