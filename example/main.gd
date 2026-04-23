extends Node3D

var _players: Dictionary = {}          # peer_id (int) → Player node

@onready var _spawn_root: Node = $Players
@onready var _proximity_label: Label = $UI/ProximityLabel
@onready var _modal: Control = $UI/Modal
@onready var _button_station = $Platforms/ButtonStation

var _proximity_mode: String = "off"
var _using_proxim: bool = false

const PROXIMITY_MAX_DISTANCE := 20.0
const PROXIMITY_UPDATE_INTERVAL := 0.1  # seconds between proximity audio updates
var _proximity_timer: float = 0.0

func _ready() -> void:
	%WebRTCHostButton.pressed.connect(_on_local_webrtc_host_pressed)
	%WebRTCJoinButton.pressed.connect(_on_local_webrtc_join_pressed)
	%ProximHostButton.pressed.connect(_on_proxim_host_pressed)
	%ProximJoinButton.pressed.connect(_on_proxim_join_pressed)
	_button_station.proximity_mode_changed.connect(_on_proximity_mode_changed)
	_update_proximity_label()

func _on_proximity_mode_changed(mode: String) -> void:
	_proximity_mode = mode
	_update_proximity_label()
	if not _using_proxim:
		return
	var my_id := multiplayer.get_unique_id()
	for peer_id: int in _players:
		if peer_id == my_id:
			continue
		_teardown_peer_audio(peer_id)
		_setup_peer_audio(peer_id)
	if mode != "off":
		_update_proximity_audio()

func _on_local_webrtc_host_pressed() -> void:
	var err = $LocalWebRTCPeer.create_host()
	if err != OK:
		print("[main] local webrtc host failed: %d" % err)
		return
	multiplayer.multiplayer_peer = $LocalWebRTCPeer.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_spawn_player(multiplayer.get_unique_id())
	_modal.hide()

func _on_local_webrtc_join_pressed() -> void:
	var err = $LocalWebRTCPeer.create_client()
	if err != OK:
		print("[main] local webrtc join failed: %d" % err)
		return
	multiplayer.multiplayer_peer = $LocalWebRTCPeer.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_local_webrtc_connected_to_server)
	_modal.hide()

func _on_local_webrtc_connected_to_server() -> void:
	_spawn_player(multiplayer.get_unique_id())

func _on_proxim_host_pressed() -> void:
	_modal.hide()
	var err: Error = await $ProximWebRTC.create_host()
	if err != OK:
		print("[main] proxim host failed: %d" % err)
		_modal.show()
		return
	multiplayer.multiplayer_peer = $ProximWebRTC.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	ProximPeer.proxim_connected.connect(_on_proxim_reconnected)
	_using_proxim = true
	_spawn_player(multiplayer.get_unique_id())

func _on_proxim_join_pressed() -> void:
	_modal.hide()
	var err: Error = await $ProximWebRTC.create_client()
	if err != OK:
		print("[main] proxim join failed: %d" % err)
		_modal.show()
		return
	multiplayer.multiplayer_peer = $ProximWebRTC.get_multiplayer_peer()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_proxim_connected_to_server)
	ProximPeer.proxim_connected.connect(_on_proxim_reconnected)
	_using_proxim = true

func _on_proxim_connected_to_server() -> void:
	_spawn_player(multiplayer.get_unique_id())

func _on_proxim_reconnected() -> void:
	if _proximity_mode == "off":
		return
	var my_id := multiplayer.get_unique_id()
	for peer_id: int in _players:
		if peer_id == my_id:
			continue
		_setup_peer_audio(peer_id)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed(&"exit"):
		get_tree().quit()

func _on_peer_connected(peer_id: int) -> void:
	print("[main] peer_connected: id=%d" % peer_id)
	_spawn_player(peer_id)
	if _using_proxim and _proximity_mode != "off":
		_setup_peer_audio(peer_id)

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

func _setup_peer_audio(peer_id: int) -> void:
	match _proximity_mode:
		"gain":
			ProximPeer.add_gain_node(peer_id)
		"panner":
			ProximPeer.add_panner_node(peer_id)

func _teardown_peer_audio(peer_id: int) -> void:
	ProximPeer.remove_gain_node(peer_id)
	ProximPeer.remove_panner_node(peer_id)

func _process(delta: float) -> void:
	if _proximity_mode != "off" and _using_proxim:
		_proximity_timer += delta
		if _proximity_timer >= PROXIMITY_UPDATE_INTERVAL:
			_proximity_timer = 0.0
			_update_proximity_audio()

func _update_proximity_audio() -> void:
	var my_id := multiplayer.get_unique_id()
	var local_player := _players.get(my_id, null) as Player
	if local_player == null:
		return

	if _proximity_mode == "panner":
		var cam := local_player.camera
		var fwd := -cam.global_transform.basis.z
		var up := cam.global_transform.basis.y
		var pos := local_player.global_position
		ProximPeer.hot_listener_node(pos.x, pos.y, pos.z, fwd.x, fwd.y, fwd.z, up.x, up.y, up.z)

	for peer_id: int in _players:
		if peer_id == my_id:
			continue
		var peer_player := _players[peer_id] as Node3D
		var peer_pos := peer_player.global_position
		match _proximity_mode:
			"gain":
				var dist := local_player.global_position.distance_to(peer_pos)
				var gain := 1.0 - clampf(dist / PROXIMITY_MAX_DISTANCE, 0.0, 1.0)
				ProximPeer.hot_gain_node(peer_id, gain)
			"panner":
				ProximPeer.hot_panner_node(peer_id, peer_pos.x, peer_pos.y, peer_pos.z, 0.0, 0.0, 0.0)

func _update_proximity_label() -> void:
	_proximity_label.text = "Proximity: %s" % _proximity_mode.to_upper()
