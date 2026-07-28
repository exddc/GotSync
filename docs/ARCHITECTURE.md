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
envelopes until the receiving replica durably applies and acknowledges them, or
until retention expires.

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
    participant Relay
    participant Joiner

    Host->>Relay: Register derived pair route
    Joiner->>Relay: Register derived pair route
    Relay-->>Host: peerReady
    Relay-->>Joiner: peerReady
    Host->>Joiner: AHello via relay
    Joiner-->>Host: BHello + PSK confirmation
    Host->>Joiner: Host confirmation
    Host-->>Host: Approve matching safety code
    Host->>Joiner: Encrypted replica archive
    Joiner-->>Host: Encrypted ready + device ID
    Host->>Joiner: Encrypted commit
    Joiner-->>Host: Encrypted receipt
```

The QR and 17-word phrase encode the same random 128-bit invitation. They never
contain the long-term pair root. Pairing uses PSK-authenticated ephemeral X25519
and explicit HMAC confirmation before the host can approve provisioning.
Provisioning rejects an archive larger than 280 KiB.

The pending record and staged joiner archive are rolled back on cancellation,
terminal pre-commit failure, or a later launch without active credentials.
This avoids silently activating an incomplete join, but it does not solve the
two-generals commit boundary: interruption after the host saves active
credentials and before the joiner does can require resetting and pairing both
devices again.

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
    state "Mailbox loop" as Mailbox {
        [*] --> Checking
        Checking --> Available: upload/fetch succeeds
        Available --> Checking: edit or 2s poll
        Checking --> Unavailable: request fails
        Unavailable --> Checking: bounded retry or foreground
    }
```
