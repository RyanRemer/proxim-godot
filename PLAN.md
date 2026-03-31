Proxim Multiplayer Example — Implementation Plan
Overview
Build a clean, minimal multiplayer example using ProximMultiplayerPeer (Path B). Every peer spawns player nodes for all connected peers deterministically, a MultiplayerSynchronizer inside each player scene handles position/rotation sync, and a proximity volume loop drives Proxim's voice volumes. Proximity chat toggles ON/OFF with V.

Files
1. player.tscn — Create (extract from main.tscn)
Extract the existing Players/Player subtree into a standalone scene via Right-click → Save Branch as Scene in the Godot editor.

Scene tree:


Player (CharacterBody3D) — player.gd
  CollisionShape3D
  Body (MeshInstance3D)
  Eyes (MeshInstance3D)
  ProximityRadius (MeshInstance3D)
  Camera3D
  MultiplayerSynchronizer   ← add this; sync position + rotation (unreliable)
Configure the MultiplayerSynchronizer's SceneReplicationConfig to replicate CharacterBody3D:position and CharacterBody3D:rotation (unreliable, always).

2. player.gd — Modify
Add multiplayer authority gating so only the owning peer runs physics and camera.


func _ready() -> void:
    if not is_multiplayer_authority():
        $Camera3D.current = false
        set_physics_process(false)
        set_process_unhandled_input(false)
        return
    capture_mouse()
Remove the exit action from _unhandled_input here — it moves to main.gd. Keep tab for mouse lock/unlock.

3. main.gd — Create (attach to Main node)
Full orchestration: Proxim setup, player spawn/despawn, proximity volume loop, toggle.


extends Node3D

var _proxim_peer: ProximPeer
var _mp: ProximMultiplayerPeer
var _players: Dictionary = {}          # peer_id (int) → Player node

@onready var _spawn_root: Node = $Players
@onready var _proximity_label: Label = $UI/ProximityLabel

var _proximity_enabled: bool = true
const PROXIMITY_MAX_DISTANCE := 20.0

func _ready() -> void:
    _setup_proxim()
    _update_proximity_label()

func _setup_proxim() -> void:
    _proxim_peer = ProximPeer.new()
    add_child(_proxim_peer)

    _mp = ProximMultiplayerPeer.new()
    _mp.proxim_peer = _proxim_peer
    multiplayer.multiplayer_peer = _mp

    multiplayer.peer_connected.connect(_on_peer_connected)
    multiplayer.peer_disconnected.connect(_on_peer_disconnected)
    _proxim_peer.welcomed.connect(_on_welcomed)

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_just_pressed(&"toggle_proximity"):
        _proximity_enabled = not _proximity_enabled
        _update_proximity_label()
        if not _proximity_enabled:
            _set_all_volumes_flat()
    if event.is_action_just_pressed(&"exit"):
        get_tree().quit()

func _on_welcomed(my_id: int, _peers: Array) -> void:
    # peer_connected fires for pre-existing peers via ProximMultiplayerPeer._on_welcomed.
    # Only need to spawn our own player here.
    _spawn_player(my_id)

func _on_peer_connected(peer_id: int) -> void:
    _spawn_player(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
    _despawn_player(peer_id)

func _spawn_player(peer_id: int) -> void:
    if _players.has(peer_id):
        return
    var player: Player = preload("res://player.tscn").instantiate()
    player.name = str(peer_id)           # must match peer_id for sync path agreement
    player.set_multiplayer_authority(peer_id)
    _spawn_root.add_child(player)
    _players[peer_id] = player

func _despawn_player(peer_id: int) -> void:
    if not _players.has(peer_id):
        return
    _players[peer_id].queue_free()
    _players.erase(peer_id)

func _process(_delta: float) -> void:
    if _proximity_enabled:
        _update_proximity_volumes()

## Runs every frame when proximity chat is ON.
## Computes distance to each remote player, maps to 0.0–1.0 volume.
func _update_proximity_volumes() -> void:
    var my_id := multiplayer.get_unique_id()
    var local_player := _players.get(my_id, null) as Node3D
    if local_player == null:
        return
    for peer_id: int in _players:
        if peer_id == my_id:
            continue
        var dist := local_player.global_position.distance_to(
            (_players[peer_id] as Node3D).global_position)
        _mp.set_peer_volume(peer_id, clampf(1.0 - dist / PROXIMITY_MAX_DISTANCE, 0.0, 1.0))

## Called once when toggled OFF. Resets all peers to full volume.
func _set_all_volumes_flat() -> void:
    var my_id := multiplayer.get_unique_id()
    for peer_id: int in _players:
        if peer_id == my_id:
            continue
        _mp.set_peer_volume(peer_id, 1.0)

func _update_proximity_label() -> void:
    _proximity_label.text = "Proximity Chat: %s  [V]" % ("ON" if _proximity_enabled else "OFF")
4. main.tscn — Modify
Change Players node type from MultiplayerSynchronizer → Node3D, detach players.gd
Delete the hard-coded Players/Player subtree (it becomes player.tscn)
Attach main.gd to Main
Add CanvasLayer → Label (ProximityLabel) anchored top-left

Main (Node3D) — main.gd
  Node (lighting/env — unchanged)
  Floor (StaticBody3D — unchanged)
  Box (StaticBody3D — unchanged)
  Players (Node3D)         ← was MultiplayerSynchronizer
  UI (CanvasLayer)         ← new
    ProximityLabel (Label) ← new
5. project.godot — Modify
Add toggle_proximity input action mapped to V via Project Settings → Input Map.

Proximity Chat Toggle — Complete Code Path

V pressed
  → main.gd._unhandled_input detects "toggle_proximity"
  → _proximity_enabled flipped
  → _update_proximity_label() updates HUD

  If now OFF:
    → _set_all_volumes_flat()
    → ProximMultiplayerPeer.set_peer_volume(peer_id, 1.0)  [all remotes]
    → ProximPeer.set_peer_volume(peer_id, 1.0)
    → sends {"type":"set_volume","peer_id":N,"multiplier":1.0} over /proxim WS
    → Proxim restores full audio

  If now ON (next frame):
    → _process → _update_proximity_volumes()
    → dist = local_player.global_position.distance_to(remote.global_position)
    → volume = clamp(1.0 - dist / 20.0, 0.0, 1.0)
    → ProximMultiplayerPeer.set_peer_volume → ProximPeer.set_peer_volume
    → sends {"type":"set_volume","peer_id":N,"multiplier":X} over /proxim WS
    → Proxim applies distance-based gain
Implementation Order
Extract player.tscn from main.tscn in the Godot editor
Add MultiplayerSynchronizer to player.tscn, configure sync properties
Modify player.gd — authority gating in _ready
Create main.gd
Restructure main.tscn — swap Players type, add UI, attach main.gd
Add toggle_proximity to project.godot
Key design notes:

No MultiplayerSpawner — every peer spawns deterministically by peer ID, so manual add_child with player.name = str(peer_id) is simpler and avoids server-only spawn authority edge cases
player.name = str(peer_id) is required for MultiplayerSynchronizer path agreement across all peers
_proxim_peer.welcomed only spawns the local player; multiplayer.peer_connected handles everyone else (including peers already in the room, because ProximMultiplayerPeer._on_welcomed emits peer_connected for each of them)