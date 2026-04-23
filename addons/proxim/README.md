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
   [godot-webrtc-native](https://github.com/godotengine/webrtc-native/releases/tag/1.1.0-stable)
   GDExtension (not bundled — track its releases independently). For the
   audio-only path you do not need it. 
---

## Usage

Three usage paths, depending on which parts of Proxim you actually want.

### Multiplayer transport (WebRTC + voice, no spatial audio)

You want WebRTC signaling + voice chat; you do not want spatial audio.

Drop a `ProximWebRTC` node into your scene tree. That's it — none of the `*_gain_node` / `*_panner_node` / `hot_listener_node` APIs need to be called.

For testing locally - just hop in a proxim call by yourself and then trigger "create_host" in game. After basic testing you can have a friend join your call and then trigger "create_client" when you are ready to test multiplayer with them. To test local multiplayer (multiple debug instances) you'll need to either do local ENET or local WebRTC multiplayer peers for that.

#### Minimal Example
For the bare minimium for those familar with Godot, here is the minimal snippet of code.
```gdscript
extends Node

@onready var proxim_web_rtc: ProximWebRTC = $ProximWebRTC

func _ready() -> void:
    # Host:
    var err := await proxim_web_rtc.create_host()
    if err != OK: return
    multiplayer.multiplayer_peer = proxim_web_rtc.get_multiplayer_peer()

    # ...or Client:
    # var err := await proxim_web_rtc.create_client()
    # if err != OK: return
    # multiplayer.multiplayer_peer = proxim_web_rtc.get_multiplayer_peer()
```

#### Main.gd Example
For those new to multiplayer in Godot, here is what a main.gd file might look like
```
extends Node3D

# From the Proxim addon
@onready var proxim_web_rtc: ProximWebRTC = $ProximWebRTC

# A simple gui with some buttons and a label for errors
@onready var multiplayer_gui: CenterContainer = $CanvasLayer/MultiplayerGUI
@onready var connection_message: Label = $CanvasLayer/MultiplayerGUI/PanelContainer/VBoxContainer/ConnectionMessage

# A Node3D (spawnpoint) and player prefab
@onready var players: Node3D = $Players
const PLAYER = preload("uid://bcthojlfc5ira")
# Player prefab has a MultiplayerSynchronizer that syncs whatever properties you want.
# Player prefab also has set_physics_process(multiplayer.get_unique_id() == get_multiplayer_authority());
# which enables movement input for your character and disables movement input for other characters

func _on_host_button_pressed() -> void:
	connection_message.text = "Connecting to Proxim...";
	var err := await proxim_web_rtc.create_host()
	if err != OK: 
		connection_message.text = "Error connecting " + str(err)
		return
	multiplayer.multiplayer_peer = proxim_web_rtc.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer_gui.visible = false;
	connection_message.text = "";
	_on_connected_to_server();

func _on_join_button_pressed() -> void:
	connection_message.text = "Connecting to Proxim...";
	var err := await proxim_web_rtc.create_client()
	if err != OK: 
		connection_message.text = "Error connecting " + str(err)
		return
	multiplayer.multiplayer_peer = proxim_web_rtc.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer_gui.visible = false;
	connection_message.text = "";
	
func _on_peer_connected(peer_id):
	_spawn_player(peer_id);
	
func _on_connected_to_server():
	_spawn_player(multiplayer.get_unique_id())

func _on_peer_disconnected(peer_id):
	for child in players.get_children():
		if child.name == str(peer_id):
			child.queue_free();
	
func _spawn_player(peer_id):
	var player := PLAYER.instantiate()
	player.name = str(peer_id);
	player.set_multiplayer_authority(peer_id);
	players.add_child(player);	
```

### Proximity chat (bring your own multiplayer)

You already have multiplayer (ENet, Steam, Nakama, …) and just want Proxim
for spatial voice. Use the `ProximPeer` autoload directly and map your own
peer IDs onto Proxim `gameId`s.

Both proximity features start the same way (not needed if already using multiplayer):

```gdscript
func _ready() -> void:
    if await ProximPeer.connect_to_app() != WebSocketPeer.STATE_OPEN:
        return
    # Tell Proxim who you are — use your own multiplayer peer id as gameId.
    var my_id := multiplayer.get_unique_id()
    ProximPeer.update_call_peer({"gameId": my_id})
```

#### Update cadence

Proxim provides `hot_*` methods for updates that need to happen frequently. For proximity chat this is either player volume levels (if using the `gain` node) or player positions and orientations (if using the `panner` node). By default Proxim smooths these values so you don't need to update every frame. The default ramp is **0.1 seconds**. More frequent updates leads to smoother audio but a tradeoff of performance due to packet processing time. If you want a different cadence you can change it like so:

```gdscript
# Default behaviour — equivalent to not calling this at all.
ProximPeer.set_proximity_interpolation(true, 0.1)

# Snappier: 20 Hz updates, 0.05 s ramp.
ProximPeer.set_proximity_interpolation(true, 0.05)

# Disable interpolation for instant snaps (e.g. teleports).
ProximPeer.set_proximity_interpolation(false, 0.0)
```

The examples below use a 0.1 s `Timer` to match the default.

#### Gain

Distance-based volume falloff. Cheapest option — no HRTF, no listener pose. Also can be used in combination with panner for cases where the players locations are similar but shouldn't be able to hear each other.

```gdscript
@onready var _proxim_tick: Timer = $ProximTick  # Timer node, wait_time = 0.1, autostart = true

# Call ProximPeer.add_gain_node(peer_id) for each peer when you want to enable proximity chat

# Example implementation, but there are plenty of other ways to do this
func _on_proxim_tick_timeout() -> void: # Connected via node signals
	var my_id = multiplayer.get_unique_id();
	var my_player = null;
	for child in players.get_children():
		if child.get_multiplayer_authority() == my_id:
			my_player = child;
			break;
	
	if my_player == null:
		return;
		
	for player in players.get_children():
		if player is Player and player.get_multiplayer_authority() != my_id:
			var dist = my_player.position.distance_to(player.position)
			var gain = 1.0 - clampf(dist / MAX_DISTANCE, 0.0, 1.0)
			ProximPeer.hot_gain_node(player.get_multiplayer_authority(), gain);
```

#### Panner

Full 3D spatial audio — stereo panning, HRTF, distance models. Needs a
listener pose (from the local player's camera) plus a panner per remote
peer.

```gdscript
@onready var _proxim_tick: Timer = $ProximTick  # Timer node, wait_time = 0.1, autostart = true

func _on_peer_joined(peer_id: int) -> void:
    ProximPeer.add_panner_node(peer_id)

func _on_proxim_tick_timeout() -> void: # Connected via node signals
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
