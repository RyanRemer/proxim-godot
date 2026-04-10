extends Node3D

var _players: Dictionary = {}          # peer_id (int) → Player node

@onready var _spawn_root: Node = $Players
@onready var _proximity_label: Label = $UI/ProximityLabel
@onready var _modal: Control = $UI/Modal

var _proximity_enabled: bool = false
const PROXIMITY_MAX_DISTANCE := 20.0
var _proximity_update_timer: float = 0.0
const PROXIMITY_UPDATE_INTERVAL := 1.0

func _ready() -> void:
	$UI/Modal/Margin/VBox/ENetPanel/ENetMargin/ENetVBox/ENetHostButton.pressed.connect(_on_enet_host_pressed)
	$UI/Modal/Margin/VBox/ENetPanel/ENetMargin/ENetVBox/ENetJoinButton.pressed.connect(_on_enet_join_pressed)
	$UI/Modal/Margin/VBox/ProximPanel/ProximMargin/ProximVBox/ProximHostButton.pressed.connect(_on_proxim_host_pressed)
	$UI/Modal/Margin/VBox/ProximPanel/ProximMargin/ProximVBox/ProximJoinButton.pressed.connect(_on_proxim_join_pressed)
	_update_proximity_label()

func _on_enet_host_pressed() -> void:
	_setup_enet(true)
	_modal.hide()

func _on_enet_join_pressed() -> void:
	_setup_enet(false)
	_modal.hide()

func _on_proxim_host_pressed() -> void:
	_modal.hide()
	var err: Error = await $ProximPeer.create_host()
	if err != OK:
		print("[main] proxim host failed: %d" % err)
		_modal.show()
		return
	multiplayer.multiplayer_peer = $ProximPeer.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_spawn_player(multiplayer.get_unique_id())

func _on_proxim_join_pressed() -> void:
	_modal.hide()
	var err: Error = await $ProximPeer.create_client()
	if err != OK:
		print("[main] proxim join failed: %d" % err)
		_modal.show()
		return
	multiplayer.multiplayer_peer = $ProximPeer.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_proxim_connected_to_server)

func _on_proxim_connected_to_server() -> void:
	_spawn_player(multiplayer.get_unique_id())

func _setup_enet(is_host: bool) -> void:
	var enet := ENetMultiplayerPeer.new()
	if is_host:
		enet.create_server(7777)
		multiplayer.multiplayer_peer = enet
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_spawn_player(multiplayer.get_unique_id())
	else:
		var ip_edit : LineEdit = $UI/Modal/Margin/VBox/ENetPanel/ENetMargin/ENetVBox/ENetIPEdit
		var ip = ip_edit.text
		if ip.is_empty():
			ip = "127.0.0.1"
		enet.create_client(ip, 7777)
		multiplayer.multiplayer_peer = enet
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.connected_to_server.connect(_on_enet_connected_to_server)

func _on_enet_connected_to_server() -> void:
	_spawn_player(multiplayer.get_unique_id())

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed(&"toggle_proximity"):
		_proximity_enabled = not _proximity_enabled
		_update_proximity_label()
	if Input.is_action_just_pressed(&"exit"):
		get_tree().quit()

func _on_peer_connected(peer_id: int) -> void:
	print("[main] peer_connected: id=%d" % peer_id)
	_spawn_player(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	print("[main] peer_disconnected: id=%d" % peer_id)
	_despawn_player(peer_id)

func _spawn_player(peer_id: int) -> void:
	if _players.has(peer_id):
		return
	print("[main] spawning player id=%d" % peer_id)
	var player: Player = preload("res://player.tscn").instantiate()
	player.name = str(peer_id)
	player.set_multiplayer_authority(peer_id)
	_spawn_root.add_child(player)
	_players[peer_id] = player

func _despawn_player(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	print("[main] despawning player id=%d" % peer_id)
	_players[peer_id].queue_free()
	_players.erase(peer_id)

func _process(delta: float) -> void:
	if _proximity_enabled:
		_proximity_update_timer += delta
		if _proximity_update_timer >= PROXIMITY_UPDATE_INTERVAL:
			_proximity_update_timer = 0.0
			_log_proximity_distances()

## Logs distance to each remote player (placeholder for future proximity audio).
func _log_proximity_distances() -> void:
	var my_id := multiplayer.get_unique_id()
	var local_player := _players.get(my_id, null) as Node3D
	if local_player == null:
		return
	for peer_id: int in _players:
		if peer_id == my_id:
			continue
		var dist := local_player.global_position.distance_to(
			(_players[peer_id] as Node3D).global_position)
		print("[proximity] peer %d distance: %.1f" % [peer_id, dist])

func _update_proximity_label() -> void:
	_proximity_label.text = "Proximity: %s  [V]" % ("ON" if _proximity_enabled else "OFF")
