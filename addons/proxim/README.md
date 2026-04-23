# Proxim — Godot addon

Godot 4 addon that talks to the **Proxim companion app** over a local
WebSocket. Exposes three things:

- **Peer-to-peer relay** — a generic `relay_to` / `peer_message` channel you
  can build anything on top of.
- **WebRTC multiplayer transport** — optional helper node that turns the relay
  into a Godot `WebRTCMultiplayerPeer`.
- **Spatial audio controls** — gain / panner / listener updates that map 1:1
  to the Web Audio API.

---

## Install

1. Copy `addons/proxim/` into your project's `addons/` folder.
2. In Godot, open **Project → Project Settings → Plugins** and tick **Enable**
   next to "Proxim". The `ProximPeer` autoload appears automatically.
3. If you want WebRTC multiplayer transport, also install the
   [godot-webrtc-native](https://github.com/godotengine/webrtc-native)
   GDExtension (not bundled — track its releases independently). For the
   audio-only path you do not need it.

---

## Usage

Three usage paths, depending on which parts of Proxim you actually want.

### Multiplayer transport (WebRTC + voice, no spatial audio)

You want WebRTC signaling + voice chat; you do not want spatial audio.

```gdscript
extends Node

@onready var _webrtc: ProximWebRTC = $ProximWebRTC

func _ready() -> void:
    # Host:
    var err := await _webrtc.create_host()
    if err != OK: return
    multiplayer.multiplayer_peer = _webrtc.get_multiplayer_peer()

    # ...or Client:
    # var err := await _webrtc.create_client()
    # if err != OK: return
    # multiplayer.multiplayer_peer = _webrtc.get_multiplayer_peer()
```

Drop a `ProximWebRTC` node into your scene tree. That's it — none of the
`*_gain_node` / `*_panner_node` / `hot_listener_node` APIs need to be called.

### Proximity chat (bring your own multiplayer)

You already have multiplayer (ENet, Steam, Nakama, …) and just want Proxim
for spatial voice. Use the `ProximPeer` autoload directly and map your own
peer IDs onto Proxim `gameId`s.

Both flavors start the same way:

```gdscript
func _ready() -> void:
    if await ProximPeer.connect_to_app() != WebSocketPeer.STATE_OPEN:
        return
    # Tell Proxim who you are — use your own multiplayer peer id as gameId.
    var my_id := multiplayer.get_unique_id()
    ProximPeer.update_call_peer({"gameId": my_id})
```

#### Gain

Distance-based volume falloff. Cheapest option — no HRTF, no listener pose. Also can be used in combination with panner for cases where the players locations are similar but shouldn't be able to hear each other.

```gdscript
func _on_peer_joined(peer_id: int) -> void:
    ProximPeer.add_gain_node(peer_id)

func _process(_delta: float) -> void:
    for peer_id: int in _remote_peers:
        var dist := _my_pos.distance_to(_remote_peers[peer_id].global_position)
        var gain := 1.0 - clampf(dist / MAX_DISTANCE, 0.0, 1.0)
        ProximPeer.hot_gain_node(peer_id, gain)
```

#### Panner

Full 3D spatial audio — stereo panning, HRTF, distance models. Needs a
listener pose (from the local player's camera) plus a panner per remote
peer.

```gdscript
func _on_peer_joined(peer_id: int) -> void:
    ProximPeer.add_panner_node(peer_id)

func _process(_delta: float) -> void:
    var cam: Camera3D = $Camera3D
    var pos := cam.global_position
    var fwd := -cam.global_transform.basis.z
    var up := cam.global_transform.basis.y
    ProximPeer.hot_listener_node(pos.x, pos.y, pos.z, fwd.x, fwd.y, fwd.z, up.x, up.y, up.z)
    for peer_id: int in _remote_peers:
        var p: Vector3 = _remote_peers[peer_id].global_position
        ProximPeer.hot_panner_node(peer_id, p.x, p.y, p.z, 0.0, 0.0, 0.0)
```

### Multiplayer transport + spatial audio

Full stack: `ProximWebRTC` for multiplayer + `ProximPeer` audio calls for
spatial voice. The example `main.gd` is the canonical implementation — start
there and pattern-match.

---

## API reference

Full docstrings live in [`proxim_peer.gd`](proxim_peer.gd) and
[`proxim_webrtc.gd`](proxim_webrtc.gd). Summary:

**`ProximPeer` (autoload)**
- `connect_to_app()` — open the WebSocket to the companion app.
- `update_call_peer(data)` — set your `gameId` / `isHost`. Sent verbatim; use camelCase.
- `get_call_peers()` — current peer list (blocks up to 2 s).
- `relay_to(peer_game_id, payload)` — send an opaque Dictionary to a peer.
- `peer_joined` / `peer_left` / `peer_message` / `proxim_connected` / `proxim_disconnected` signals.
- **Gain** (`add_gain_node`, `remove_gain_node`, `update_gain_node`, `hot_gain_node`) — 1D falloff.
- **Panner** (`add_panner_node`, `remove_panner_node`, `update_panner_node`, `hot_panner_node`) — 3D spatial.
- **Listener** (`hot_listener_node`) — the local camera's pose.
- `set_proximity_interpolation(enabled, frequency)` — smoothing ramp.

**`ProximWebRTC` (node, optional)**
- `create_host()` / `create_client()` — bring up the WebRTC mesh.
- `get_multiplayer_peer()` — the `WebRTCMultiplayerPeer` to assign to `multiplayer.multiplayer_peer`.

---

## FAQ

**Do I need the WebRTC GDExtension?**
Only if you want the WebRTC transport — the proximity-chat-only path doesn't
touch `ProximWebRTC`. Grab the extension from the
[godot-webrtc-native releases](https://github.com/godotengine/webrtc-native/releases)
and drop it into your project. The Proxim addon deliberately does not bundle
it, so you can track its releases independently.

**Why camelCase in dictionary keys?**
`update_call_peer`, `add_panner_node`'s `config`, and the `relay_to` payload
are forwarded verbatim over the wire. Proxim's protocol is camelCase
end-to-end (`gameId`, `isHost`, `panningModel`, …), so matching it avoids an
unnecessary transformation step.

**Can I run ProximWebRTC without the Proxim app running?**
No — `create_host` / `create_client` return `ERR_CANT_CONNECT` if the
companion app's WebSocket (`ws://127.0.0.1:5656`) isn't reachable.
