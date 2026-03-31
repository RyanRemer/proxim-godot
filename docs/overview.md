# Proxim — Overview

Proxim is a desktop companion app (system tray) that provides WebRTC voice chat and game data relay for small groups (4–8 players). Games integrate via a local WebSocket server on port 5656.

---

## Two-Route Architecture

Port 5656 exposes two separate WebSocket routes:

| Route | Purpose | Frame format |
|---|---|---|
| `/proxim` | Session lifecycle, volume control | JSON text |
| `/godot` | Game data forwarding | Binary (5-byte envelope) |

This separation keeps the data path simple: `/godot` is a pure binary pipe with no JSON parsing overhead. Non-Godot callers (Unity, custom engines) can use `/proxim` alone for voice-only use cases without speaking the binary protocol.

---

## Choosing the Right Class (Godot)

### Voice only — use `ProximPeer`

```gdscript
var proxim := ProximPeer.new()
add_child(proxim)

proxim.welcomed.connect(func(id, peers): print("I am peer", id))
proxim.peer_joined.connect(func(id, name): print(name, "joined"))
proxim.peer_left.connect(func(id): print("peer", id, "left"))
```

`ProximPeer` connects to `/proxim`, handles the session lifecycle, and exposes `set_peer_volume()`. No game data is sent or received.

### Voice + multiplayer — use `ProximMultiplayerPeer`

```gdscript
var proxim_peer := ProximPeer.new()
add_child(proxim_peer)       # must be in the scene tree

var mp := ProximMultiplayerPeer.new()
mp.proxim_peer = proxim_peer
multiplayer.multiplayer_peer = mp
```

`ProximMultiplayerPeer` wraps `ProximPeer`, adds the `/godot` data pipe, and implements `MultiplayerPeerExtension`. All `ProximPeer` methods (`set_peer_volume`, `get_peer_names`) are proxied on `ProximMultiplayerPeer` so the game only needs one object after setup.

---

## Peer ID Assignment

Proxim assigns stable integer IDs deterministically:

1. Firebase UIDs are delivered in lexicographic order as peers join a room.
2. The first UID seen gets ID `1`, the next `2`, and so on.
3. Mid-session joiners receive the next available slot; existing IDs never change.
4. Firebase UIDs never appear in the protocol — only integer IDs are used.

Peer `1` is the implicit server (`multiplayer.is_server()` returns `true`). This is the peer with the lexicographically lowest Firebase UID at session start, not a deliberate choice.

---

## Volume Control

Games set per-peer volume multipliers via `set_peer_volume(peer_id, multiplier)`:

- `0.0` = silent, `1.0` = normal, `> 1.0` = boosted
- The multiplier stacks on top of the user's manual volume slider in the Proxim UI
- Proxim applies the gain — the game never touches the audio pipeline

This is the entire spatial audio API. Proximity calculations, fade curves, and occlusion logic belong in the game.

---

## Full-Mesh Topology

Every peer connects directly to every other peer (N×(N−1)/2 WebRTC connections). There is no media relay server. This keeps infrastructure costs near zero and works well for 4–8 players.
