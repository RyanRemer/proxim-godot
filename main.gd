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
	if Input.is_action_just_pressed(&"toggle_proximity"):
		_proximity_enabled = not _proximity_enabled
		_update_proximity_label()
		if not _proximity_enabled:
			_set_all_volumes_flat()
	if Input.is_action_just_pressed(&"exit"):
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
