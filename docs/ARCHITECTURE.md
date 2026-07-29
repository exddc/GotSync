# Architecture and flows

## Runtime boundary

```mermaid
flowchart LR
    subgraph hostDevice ["Host iPhone"]
        hostUI["SwiftUI task UI"]
        hostReplica["Atomic CRDT archive + operation log"]
        hostKeys["ThisDeviceOnly Keychain"]
        hostLive["Ephemeral live channel"]
        hostMailbox["Stored-envelope cipher + poller"]
        hostUI -->|"Local mutation"| hostReplica
        hostReplica -->|"Immediate operations"| hostLive
        hostReplica -->|"Contiguous local operations"| hostMailbox
        hostKeys -->|"Pair root + device ID"| hostLive
        hostKeys -->|"Directional mailbox keys"| hostMailbox
    end

    subgraph relayProcess ["Python relay"]
        rooms["Volatile two-socket rooms"]
        mailbox["SQLite opaque envelopes + receipts"]
        counters["Aggregate counters"]
        rooms -->|"Counts only"| counters
        mailbox -->|"Counts only"| counters
    end

    subgraph joinerDevice ["Joiner iPhone"]
        joinerLive["Ephemeral live channel"]
        joinerMailbox["Stored-envelope cipher + poller"]
        joinerKeys["ThisDeviceOnly Keychain"]
        joinerReplica["Atomic CRDT archive + operation log"]
        joinerUI["SwiftUI task UI"]
        joinerLive -->|"Verified live operations"| joinerReplica
        joinerMailbox -->|"Persist, then ACK"| joinerReplica
        joinerKeys -->|"Pair root + device ID"| joinerLive
        joinerKeys -->|"Directional mailbox keys"| joinerMailbox
        joinerReplica -->|"Published state"| joinerUI
    end

    hostLive <-->|"Opaque WebSocket frames"| rooms
    rooms <-->|"Opaque WebSocket frames"| joinerLive
    hostMailbox -->|"PUT host-to-joiner ciphertext"| mailbox
    mailbox -->|"FETCH joiner inbound ciphertext"| joinerMailbox
    joinerMailbox -->|"ACK after durable apply"| mailbox
    joinerMailbox -->|"PUT joiner-to-host ciphertext"| mailbox
    mailbox -->|"FETCH host inbound ciphertext"| hostMailbox
    hostMailbox -->|"ACK after durable apply"| mailbox
```

The WebSocket route remains the lowest-latency path and never persists frames.
The mailbox is a separate directional store-and-forward path. It has no task
API and never receives decryption keys or plaintext. SQLite retains opaque
envelopes until the receiving replica durably applies and acknowledges them,
an authorized unlink/erase/cleanup forgets the route, or retention expires.

| Device-only | Relay-visible |
| --- | --- |
| Task titles and completion state | Source IP and connection timing |
| Device IDs and pair ID | Stable pseudonymous sync route |
| Pair root and traffic keys | Ciphertext byte counts |
| Operation contents and version vectors | Which two live sockets share a route |
| Mailbox encryption roots and message-ID keys | Directional routes and global cursors |
| Mailbox plaintext and AEAD keys | Request authorization (not persisted), upload, fetch, ACK, size, and expiry timing |

## Pairing

```mermaid
sequenceDiagram
    participant Host
    participant Live as Volatile relay
    participant Mailbox as Encrypted mailbox
    participant Joiner

    Host->>Live: Register derived pair route
    Joiner->>Live: Register derived pair route
    Live-->>Host: peerReady
    Live-->>Joiner: peerReady
    Host->>Joiner: AHello via volatile relay
    Joiner-->>Host: BHello + PSK confirmation
    Host->>Joiner: Host confirmation
    Joiner->>Joiner: Persist waiting-for-provision
    Host-->>Host: Approve matching safety code
    Host->>Host: Persist provision frontier
    Host->>Mailbox: PUT deterministic encrypted chunks
    Mailbox-->>Joiner: FETCH and authenticate chunks
    Joiner->>Joiner: Stage host archive
    alt Existing local replica differs
        Joiner->>Joiner: Persist awaiting-merge approval
        Joiner->>Joiner: Confirm Keep Both
        Joiner->>Joiner: Build and validate complete candidate
        Joiner->>Joiner: Persist protected prepared candidate
    end
    Joiner->>Joiner: Persist ready
    Joiner->>Mailbox: PUT deterministic ready
    Mailbox-->>Host: FETCH ready
    Host->>Host: Persist commit decision
    Host->>Mailbox: PUT deterministic commit
    Mailbox-->>Joiner: FETCH commit
    Joiner->>Joiner: Install prepared archive and active keys
    Joiner->>Joiner: Journal sealed receipt
    Joiner->>Mailbox: PUT deterministic receipt
    Mailbox-->>Host: FETCH receipt
    Host->>Host: Finish active link and cleanup
    Host->>Joiner: Authenticated active sync
    Joiner->>Joiner: Remove matching receipt journal entry
```

The QR and 17-word phrase encode the same random 128-bit invitation. They never
contain the long-term pair root. Pairing uses PSK-authenticated ephemeral X25519
and explicit HMAC confirmation before the host can approve provisioning.
Provisioning rejects an archive larger than 280 KiB.

Pairing completion version 2 is bound into the authenticated handshake, so an
older live-only completion peer fails before either side persists pairing
state. Provision, ready, commit, receipt, and precommit abort each use distinct
directional pairing-control keys. Every local state is persisted before the
corresponding PUT may have succeeded, and deterministic ciphertext makes an
ambiguous response safe to retry after a disconnect or restart.

A supported non-empty join or re-link enters
`provisionStagedAwaitingMergeApproval` before ready. On confirmation, the
joiner builds a detached complete candidate from the staged host frontier and
its untouched local replica. Tasks with the same stable ID, title, and
completion state are reused; local-only or conflicting visible tasks receive
deterministic IDs. The candidate must satisfy the complete task, operation, and
origin limits and is written to a protected prepared-merge file before ready
is persisted or sent. A failed preflight leaves the main replica unchanged and
pairing cancellable. This is a value-level Keep Both operation, not a merge of
two unrelated CRDT histories.

Both roles can cancel while still precommit: the joiner while waiting for
provision or merge approval, and the host while publishing provision. The
sealed abort is journaled before pending state is removed. The host checks a
joiner abort before accepting ready and again before commit publication; the
joiner checks a host abort before accepting commit. An observed precommit abort
therefore takes precedence. Cancellation is locked once the commit decision can
have been published.

Abort and receipt terminal actions live in a separate device-only Keychain
journal bounded to 32 entries and keyed by pair ID plus action kind. An entry
contains only the already sealed envelope and the minimum route, authorization,
pair/device, and message metadata required to resend it; it does not retain the
pair root. The app republishes entries immediately on launch or foreground,
uses bounded backoff after failure, and re-attempts successfully stored entries
hourly so an expired or purged relay copy is recreated on a later attempt. The
relay's authenticated PUT response distinguishes a live payload from an
acknowledged receipt tombstone. Either terminal action is retired after that
peer-ACK proof, followed by best-effort route deletion. A matching receipt can
also retire after the joiner establishes a normal authenticated active-sync
session with the expected credentials.

A damaged terminal journal is never silently discarded. When active joiner
credentials contain the pairing archive hash, the app reconstructs the
deterministic sealed receipt, quarantines the damaged bytes, and atomically
restores a usable journal. Otherwise it keeps the valid replica and credentials
but surfaces repair and refuses a new pairing until the user explicitly resets
Private Sync while keeping tasks, or performs full erase.

On upgrade, a legacy pending record beside active credentials is treated as an
ambiguous one-sided link. Current pair credentials and the pending record are
cleared, tasks and install identity remain intact, and the UI requires a fresh
link. Staging, prepared-merge, and backup files without a live pending record
are nonessential orphans: their cleanup is best effort and cannot invalidate an
otherwise healthy active pair or disable local editing. Current attempts use
pair-ID-scoped artifact filenames, so an undeletable legacy or prior-attempt
file cannot become the next attempt's staging input. Full erase enumerates
every exact legacy name and canonical pair-ID-suffixed artifact before it
reports completion.

Abort consumption also has a durable receiver state. The recipient saves the
abort cursor and sender identity before ACK, can reconstruct the exact sealed
abort after restart, and clears pending state only after a PUT proves the relay
holds its acknowledged tombstone.

## Reconnect and reconciliation

```mermaid
sequenceDiagram
    participant Host
    participant Relay
    participant Joiner

    Host->>Relay: Register derived sync route
    Joiner->>Relay: Register derived sync route
    Host->>Joiner: Fresh ephemeral AHello
    Joiner-->>Host: Fresh BHello + confirmation
    Host->>Joiner: Host confirmation
    Host->>Joiner: Encrypted version vector
    Joiner->>Host: Encrypted version vector
    Host->>Joiner: Missing durable operations
    Joiner->>Host: Missing durable operations
    Host-->>Joiner: Persisted-vector acknowledgement
    Joiner-->>Host: Persisted-vector acknowledgement
```

No wall clock decides a merge. Each origin has a contiguous sequence, each
field uses a Lamport/device-ID last-writer-wins register, and deletion is a
permanent tombstone. Live edits are applied locally first and sent immediately
after the reconciliation barrier through one connection-scoped ordered drain.
A stale drain can close only the socket generation it captured. Catch-up uses
byte-aware batches bounded by both 256 operations and 256 KiB of canonical
operation data. A remote field
update that arrives before its task's create is retained as a hidden partial
record; it becomes visible only after a create is retained and both fields
exist.

## Offline store-and-forward

```mermaid
sequenceDiagram
    participant Host
    participant Mailbox as Encrypted mailbox
    participant Joiner

    Note over Joiner: App is closed
    Host->>Host: Atomically persist local operation
    Host->>Host: Derive per-operation key and envelope
    Host->>Mailbox: PUT deterministic ciphertext
    Mailbox-->>Host: Durable cursor
    Host->>Host: Save uploaded sequence checkpoint
    Note over Host: App may now close
    Note over Joiner: App launches later
    Joiner->>Mailbox: FETCH inbound route
    Mailbox-->>Joiner: Opaque envelope + cursor
    Joiner->>Joiner: Authenticate, decrypt, validate
    Joiner->>Joiner: Atomically persist replica update
    Joiner->>Mailbox: ACK through cursor
    Mailbox->>Mailbox: Remove ciphertext, keep dedupe receipt
```

The sender does not equate a successful upload with peer delivery. Its
checkpoint means only that the relay durably accepted the ciphertext. The
receiver's replica persistence happens before ACK. If either HTTP response is
lost, deterministic envelopes and idempotent replica operations make retry
safe. Host-to-joiner and joiner-to-host use separate routes so a normal client
cannot consume its own outbound queue.

The active app polls every two seconds and also starts a cycle immediately on
launch, foregrounding, and local edit. Failure uses bounded backoff. Background
entry asks iOS for enough time to finish one best-effort cycle; no background
wake or force-quit guarantee is claimed.

## Connection and mailbox state

```mermaid
stateDiagram-v2
    [*] --> Unpaired
    Unpaired --> Pairing
    Pairing --> Connecting
    Connecting --> Reconciling
    Reconciling --> Synced
    Synced --> Offline: peer leaves or relay stops
    Offline --> Connecting: backoff with jitter
    Synced --> Offline: app enters background
    Offline --> Connecting: app becomes active
    Synced --> LocalOnly: unlink and keep tasks
    LocalOnly --> LocalOnly: edit tasks locally
    LocalOnly --> Pairing: create or join private sync
    LocalOnly --> Unpaired: erase local tasks
    state "Mailbox loop" as Mailbox {
        [*] --> Checking
        Checking --> Available: upload/fetch succeeds
        Available --> Checking: edit or 2s poll
        Checking --> Retrying: transient request fails
        Retrying --> Checking: bounded retry or foreground
        Checking --> Repair: authentication, sequence, or crypto failure
        Repair --> [*]: keep tasks and reset or replace private sync
    }
```
