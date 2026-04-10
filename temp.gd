extends Node

const _PROXIM_URL := "ws://127.0.0.1:5656"

var _ws := WebSocketPeer.new()
var _multiplayer_peer := WebRTCMultiplayerPeer.new();


func connect_to_app() -> WebSocketPeer.State:
	_ws.connect_to_url(_PROXIM_URL)
	while _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		await get_tree().process_frame
	return _ws.get_ready_state()

func create_server() -> void:
	_multiplayer_peer.create_server();
	_multiplayer_peer.peer
	pass


func create_client() -> void:
	pass


func _process(_delta: float) -> void:
	_ws.poll()
