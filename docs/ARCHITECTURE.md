# Architecture and flows

## Runtime boundary

```mermaid
flowchart LR
    subgraph hostDevice ["Host iPhone"]
        hostUI["SwiftUI task UI"]
        hostReplica["Atomic CRDT archive + operation log"]
        hostKeys["ThisDeviceOnly Keychain"]
        hostChannel["X25519 + ChaChaPoly channel"]
        hostUI -->|"Local mutation"| hostReplica
        hostReplica -->|"Missing operations"| hostChannel
        hostKeys -->|"Pair root + device ID"| hostChannel
    end

    subgraph relayProcess ["Python relay"]
        rooms["Volatile two-socket rooms"]
        counters["Aggregate in-memory counters"]
        rooms -->|"Counts only"| counters
    end

    subgraph joinerDevice ["Joiner iPhone"]
        joinerChannel["X25519 + ChaChaPoly channel"]
        joinerKeys["ThisDeviceOnly Keychain"]
        joinerReplica["Atomic CRDT archive + operation log"]
        joinerUI["SwiftUI task UI"]
        joinerChannel -->|"Verified operations"| joinerReplica
        joinerKeys -->|"Pair root + device ID"| joinerChannel
        joinerReplica -->|"Published state"| joinerUI
    end

    hostChannel <-->|"Opaque binary WebSocket frames"| rooms
    rooms <-->|"Opaque binary WebSocket frames"| joinerChannel
```

The relay has no datastore, mailbox, device registry, or task API. Each device
is its own durable mailbox. If both replicas are offline, no delivery is
possible. The POC relay bounds process state to 256 live sockets and 128 rooms
by default, and expires a route with one waiting peer after two minutes.

| Device-only | Relay-visible |
| --- | --- |
| Task titles and completion state | Source IP and connection timing |
| Device IDs and pair ID | Stable pseudonymous sync route |
| Pair root and traffic keys | Ciphertext byte counts |
| Operation contents and version vectors | Which two live sockets share a route |

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

## Foreground state

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
```
