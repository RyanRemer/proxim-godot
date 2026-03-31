# Godot Quickstart

## Requirements

- Godot 4.x
- Proxim running on the same machine as the game (system tray app)
- The `addons/proxim/` folder copied into your Godot project

---

## Path A — Voice Only (`ProximPeer`)

Use this when your game only needs voice chat and optional per-peer volume control.

```gdscript
extends Node

var proxim: ProximPeer

func _ready() -> void:
    proxim = ProximPeer.new()
    add_child(proxim)

    proxim.welcomed.connect(_on_welcomed)
    proxim.peer_joined.connect(_on_peer_joined)
    proxim.peer_left.connect(_on_peer_left)

func _on_welcomed(my_id: int, peers: Array) -> void:
    print("Connected as peer %d" % my_id)
    for p in peers:
        print("  peer %d: %s" % [p.id, p.name])

func _on_peer_joined(id: int, name: String) -> void:
    print("%s joined (id %d)" % [name, id])

func _on_peer_left(id: int) -> void:
    print("peer %d left" % id)

# Call this whenever your game calculates a new volume for a peer
func update_proximity_volume(peer_id: int, distance: float) -> void:
    var multiplier := clampf(1.0 - distance / 50.0, 0.0, 1.0)
    proxim.set_peer_volume(peer_id, multiplier)
```

`ProximPeer` reconnects automatically with exponential backoff if Proxim is not running yet or restarts.

---

## Path B — Voice + Multiplayer (`ProximMultiplayerPeer`)

Use this when you want Godot's high-level multiplayer API (`@rpc`, `MultiplayerSpawner`, etc.) to run over Proxim.

### Setup

```gdscript
extends Node

var proxim_peer: ProximPeer
var mp: ProximMultiplayerPeer

func _ready() -> void:
    # ProximPeer must be a scene tree node so _process() runs
    proxim_peer = ProximPeer.new()
    add_child(proxim_peer)

    mp = ProximMultiplayerPeer.new()
    mp.proxim_peer = proxim_peer
    multiplayer.multiplayer_peer = mp
```

After this, Godot's multiplayer system drives everything:

- `multiplayer.get_unique_id()` → your Proxim peer ID (1–N)
- `multiplayer.is_server()` → `true` for peer ID 1
- `peer_connected` / `peer_disconnected` signals work normally
- `@rpc` calls and `MultiplayerSpawner` work as expected

### Volume control (proxied)

```gdscript
mp.set_peer_volume(peer_id, 0.5)    # same as proxim_peer.set_peer_volume(...)
mp.get_peer_names()                  # Dictionary: int -> String
```

### Who is the server?

Peer `1` is always the server. This is the player with the lexicographically lowest Firebase UID — the first person in the room, roughly. Proxim assigns IDs deterministically, so all clients agree without coordination.

If your game logic requires a chosen host, you can ignore `is_server()` and designate authority yourself via an RPC after everyone is connected.

---

## Signals Reference

### ProximPeer

| Signal | Arguments | When |
|---|---|---|
| `connected` | — | After `hello` received (WebSocket open, version verified) |
| `welcomed` | `your_id: int, peers: Array` | After `welcome` received (IDs assigned) |
| `peer_joined` | `id: int, name: String` | Peer's WebRTC connection became active |
| `peer_left` | `id: int` | Peer left the room |

### ProximMultiplayerPeer (via MultiplayerPeer)

| Signal | When |
|---|---|
| `peer_connected(id)` | Peer joined (forwarded from ProximPeer) |
| `peer_disconnected(id)` | Peer left (forwarded from ProximPeer) |

---

## Peer ID Mapping

If you need to look up names from IDs:

```gdscript
var names := proxim_peer.get_peer_names()  # { 1: "Ryan", 2: "Alice", ... }
var name: String = names.get(some_id, "Unknown")
```
