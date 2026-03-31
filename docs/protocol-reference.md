# Proxim Protocol Reference

Port 5656 exposes two WebSocket routes with distinct responsibilities.

---

## `ws://localhost:5656/proxim` — Control API

Session lifecycle and call manipulation. All frames are JSON text. Unknown message types are silently ignored on both sides — this is how the protocol extends without breaking existing adapters.

### Proxim → Client

On connect, Proxim immediately sends `hello`:

```json
{ "type": "hello", "version": 1 }
```

Once the local peer has a confirmed ID, Proxim sends `welcome`:

```json
{
  "type": "welcome",
  "your_id": 2,
  "peers": [
    { "id": 1, "name": "Ryan" },
    { "id": 3, "name": "Alice" }
  ]
}
```

`peers` contains only peers whose WebRTC connection is currently established.

When a peer's WebRTC connection reaches `connected`:

```json
{ "type": "peer_connected", "id": 4, "name": "Bob" }
```

When a peer leaves:

```json
{ "type": "peer_disconnected", "id": 4 }
```

### Client → Proxim

**`set_volume`** — set a gain multiplier for one peer's incoming audio.

```json
{ "type": "set_volume", "peer_id": 3, "multiplier": 0.5 }
```

| `multiplier` | Effect |
|---|---|
| `0.0` | Silent |
| `0.5` | Half volume |
| `1.0` | Normal (default) |
| `> 1.0` | Boosted (stacks with user's manual slider) |

---

## `ws://localhost:5656/godot` — Data Pipe

Pure binary game data forwarding. No JSON, no lifecycle messages — only binary frames using the fixed 5-byte envelope. The client must obtain peer IDs from `/proxim` before using this route.

### Client → Proxim

```
[4 bytes: target peer ID, LE i32] [1 byte: channel] [payload…]
```

| Target value | Meaning |
|---|---|
| `0` | Broadcast to all peers |
| positive `N` | Send only to peer N |
| negative `N` | Send to all peers except peer N |

### Proxim → Client

```
[4 bytes: sender peer ID, LE i32] [1 byte: channel] [payload…]
```

### Channels

| Index | Reliability | Godot transfer mode |
|---|---|---|
| `0` | Unreliable unordered | `TRANSFER_MODE_UNRELIABLE` |
| `1` | Reliable ordered | `TRANSFER_MODE_RELIABLE` |
| `2–127` | Reserved by Proxim | — |
| `128–255` | Reserved for game-defined use | — |

---

## Peer IDs

Proxim assigns stable integer IDs from the Firebase presence list. UIDs are delivered in lexicographic order; the first UID seen gets ID `1`, the next `2`, etc. New mid-session joiners take the next available slot — existing IDs never renumber. Firebase UIDs never appear in the protocol.

Peer `1` is the implicit server in Godot's `MultiplayerAPI` model (`is_server()` returns `true` for peer 1). This is the peer with the lexicographically lowest Firebase UID at session start.

---

## Versioning

The `hello` message carries a `version` field. Clients should check this and warn if the version is unexpected. Unknown message types are silently ignored in both directions, allowing the protocol to add fields and message types without breaking older adapters.
