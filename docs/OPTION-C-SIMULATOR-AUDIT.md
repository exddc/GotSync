# Option C simulator audit

**Date:** 2026-07-30  
**Branch:** current workspace (`agent/improve-sync-reliability` with multi-device work present)  
**Plan:** [MULTI-DEVICE-GROUP-SYNC.md](MULTI-DEVICE-GROUP-SYNC.md)  
**Tooling:** Codex `build-ios-apps` plugin → **XcodeBuildMCP** CLI (`simulator`, `ui-automation`) on three booted sims  

| Simulator | UDID | Role in run |
| --- | --- | --- |
| GotDone-Host-UX | `77AFBFB3-0AFB-4B8C-8346-7680689B8942` | Founding member |
| GotDone-Joiner-UX | `344FB375-42AD-4FFE-B73C-A4C06283E8F1` | First joiner; later **group invite issuer** |
| GotDone-Member3-UX | `54B5FA72-B1AF-4E3D-AFE0-FAD2E38ACA79` | Third member via any-member invite |

Screenshots: `docs/screenshots/option-c-audit/`.

---

## Verdict

**Option C vertical slice is largely implemented and matches the plan for the primary product story.**

| Plan goal | Simulator / test result |
| --- | --- |
| G1 · 2…N devices (cap 8) | Welcome: “Link up to **8** iPhones”; Manage Sync shows **3 of 8** after third join |
| G3 · Any member can invite | **Joiner** opened Manage Sync → **Invite another iPhone** → QR/phrase; Member3 joined |
| G8 · Manage Sync center | Menu item on linked phones; sheet has status, members, invite, leave |
| Founding 2-device pair | Host create + joiner phrase + safety `041480` → both dashboards |
| Unit coverage | **19/19** `GroupSyncTests` + `UXSurfaceTests` passed |

**Gaps / residuals** (not blockers for “does Manage Sync + multi-join exist?”, but not full plan Done):

- Live multi-peer crypto for N>2 still deferred (plan already says mailbox is source of truth).
- Some empty-state copy still says “the other iPhone” (singular).
- Env footgun: Debug build injects `ws://192.168.178.187:…`; relay must listen with `--allow-insecure-non-loopback` on that interface (loopback-only relay caused false “Can’t reach private sync”).

---

## Method

1. `xcodebuildmcp simulator build-and-run` on Host; install/launch on Joiner + Member3.  
2. Unit: `GroupSyncTests` + `UXSurfaceTests` (19 tests).  
3. UI automation: snapshot-ui / tap / type-text / wait-for-ui / screenshots.  
4. Relay: initially `127.0.0.1` only → app could not reach LAN URL; restarted with:

   ```bash
   .venv/bin/python run.py --host 0.0.0.0 --mailbox-host 0.0.0.0 \
     --allow-insecure-non-loopback
   ```

5. End-to-end: founding pair → any-member invite from **joiner** → third device.

---

## Acceptance scenarios (plan §6.3)

| # | Scenario | Result |
| --- | --- | ---: |
| 1 | Three-phone converge (join + shared group) | **Pass (join + roster)** — Host + Joiner + Member3 all reached task dashboard; Host and Member3 Manage Sync both show **3 of 8** and three member rows (membership gossip OK). Task edit fan-out not re-exercised after M3 join. |
| 2 | Any-member invite (B invites C; A never issued) | **Pass** — Invite issued from **Joiner** (not Host); Member3 joined via Joiner’s phrase. |
| 3 | Offline mailbox fan-out | **Not re-run** this session (unit tests cover fan-out routes). |
| 4 | Local merge Keep Both | **Not re-run** this session. |
| 5 | Capacity at 8 | **Unit pass** (`testGroupAtCapacityRejectsNinthMember`); UI copy present. |
| 6 | Leave keeps tasks | **UI present** (“Leave sync and keep tasks”); exercised earlier unlink path. |
| 7 | Issuer crash mid-join | **Not re-run** this session. |

---

## UI evidence vs plan

### Welcome (product boundary)

- Copy: **“Link up to 8 iPhones with a one-time QR code or phrase…”**  
- Matches `ProductSyncPolicy.multiDeviceBoundary` / plan G1.  
- Screenshot: `host-welcome-8phones.jpg`.

### Manage Sync (linked)

Observed on Host and Joiner after pair:

- Menu: **Manage Sync**, Sync status, Leave, Erase, Diagnostics (DEBUG).  
- Sheet actions: **Invite another iPhone**, **Leave sync and keep tasks**, Done.  
- After third join: Member3 and Host both **`3 of 8`**, three iPhone rows, Diagnostics **Members: 3**.  
- Screenshots: `host-manage-sync-linked.jpg`, `joiner-manage-sync-linked.jpg`, `member3-manage-sync.jpg`, `host-manage-after-m3.jpg`.

### Any-member invite QR

- Joiner Manage Sync → Invite → **invitation-phrase** visible.  
- Copy path uses group-invite presentation (`Invite another iPhone` / “join this sync”).  
- Screenshot: `joiner-group-invite-qr.jpg`.

### Founding + safety

- Host invitation phrase shown; joiner entered phrase; both showed safety code **041480**; Host **Codes Match — Approve**.  
- Screenshots: `host-invite-live.jpg`, `host-safety.jpg`, `joiner-safety.jpg`, `host-linked.jpg`, `joiner-linked.jpg`.

---

## Implementation map (code vs plan phases)

Aligned with plan status table in `MULTI-DEVICE-GROUP-SYNC.md`:

| Area | Evidence |
| --- | --- |
| `GroupCredentials` + pair bridge | `GroupCredentials.swift`, Keychain migration tests |
| `maxDevices = 8` | `ProductSyncPolicy`, welcome UI, **3 of 8** |
| `GroupMailbox` multi-recipient | `GroupMailbox.swift`, GroupSyncTests |
| Any-member `inviteToGroup()` | Simulator: joiner issued invite while linked |
| Manage Sync UI | `ManageSyncView.swift` |
| Relay N sockets (8) | `DEFAULT_MAX_SOCKETS_PER_ROUTE = 8` in `server.py` |
| Live N-crypto | Deferred (plan); N=2 live path still used for founding |

---

## Issues found during audit

### 1. Relay bind vs Debug endpoint (environment)

- Built app Info.plist: `GotDoneRelayURL = ws://192.168.178.187:8765/v1`.  
- Relay started as loopback-only → Create/Invite failed with **“Can’t reach private sync”** and cleared invitation UI via `pairingFailed`.  
- Fix for local multi-sim: bind `0.0.0.0` + `--allow-insecure-non-loopback`, **or** set Debug URLs to `127.0.0.1` (simulators can use host loopback).

### 2. Invitation UI vanishes on transport failure

- `inviteToGroup` / `createPrivateSync` write phrase then start `runHostPairing`.  
- On connect failure, `pairingFailed` clears `invitationPhrase` → user never sees a stable QR.  
- Prefer: keep invitation UI on screen with retry while TTL remains (product polish).

### 3. Residual singular copy

- Empty dashboard still said “the other iPhone” in one linked state.  
- Plan G8 wants multi-phone language consistently.

### 4. Manage Sync medium detent

- **Invite another iPhone** often requires expanding the sheet (drag) before the button is hittable.  
- Prefer large detent default or primary invite above the fold.

---

## Tests run

```text
GotDoneRelayTests/GroupSyncTests + UXSurfaceTests
✅ 19 tests passed, 0 failed (≈60s)
```

Includes capacity, credentials round-trip, mailbox fan-out routes, UX maxDevices=8.

---

## Conclusion

Against **Option C** as planned:

1. **Yes** — implementation is no longer two-device-only; product + credentials + Manage Sync + any-member invite are real.  
2. **Yes** — both founding host and later joiner can show invite QR while linked.  
3. **Yes** — a third simulator joined the same link via the joiner’s invite and reported **3 of 8**.  
4. **Partial** — full offline fan-out / task convergence / membership gossip on all three UIs should get one more focused pass; live N-peer remains deferred per plan.  
5. **Ops note** — multi-sim demos need relay reachable at the Debug `GOTDONE_RELAY_URL` host.

**Recommended next checks**

1. On all three linked sims, create a task on Member3 and confirm Host + Joiner receive it (mailbox open-to-sync).  
2. Open Manage Sync on Host after gossip delay; confirm **3 of 8** and three member rows.  
3. Leave from Member3; confirm Host/Joiner stay linked and counts drop after remove/gossip.  
4. Document Debug endpoint / relay bind in README so “Can’t reach private sync” is not mistaken for a product regression.
