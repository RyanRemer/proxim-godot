extends Node
class_name ProximWebRTC

## Optional helper that builds a Godot WebRTCMultiplayerPeer on top of
## ProximPeer's generic relay (relay_to / peer_message). Drop this node
## anywhere in your scene and call create_host or create_client — it
## talks to the ProximPeer autoload directly.

const _ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302"]}]

var _multiplayer_peer := WebRTCMultiplayerPeer.new()
var _peer_connections: Dictionary = {}  # game_id (int) -> WebRTCPeerConnection
var _my_game_id: int = 0
var _pending_messages: Array = []  # peer_message buffered before _my_game_id is set


func _log(msg: String) -> void:
	var t := Time.get_time_dict_from_system()
	var ms := Time.get_ticks_msec() % 1000
	print("%02d:%02d:%02d.%03d [ProximWebRTC] %s" % [t.hour, t.minute, t.second, ms, msg])


func _ready() -> void:
	ProximPeer.peer_joined.connect(_on_peer_joined)
	ProximPeer.peer_left.connect(_on_peer_left)
	ProximPeer.peer_message.connect(_on_peer_message)
	ProximPeer.proxim_disconnected.connect(_reset)
	_multiplayer_peer.peer_disconnected.connect(_on_mp_peer_disconnected)


## Connect to Proxim, verify no host exists, then claim the host role
## with gameId 1. Returns OK on success, ERR_ALREADY_IN_USE if a host
## exists, or ERR_CANT_CONNECT if the WebSocket connection failed.
func create_host() -> Error:
	_log("create_host: connecting to Proxim app...")
	if await ProximPeer.connect_to_app() != WebSocketPeer.STATE_OPEN:
		_log("create_host: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var result := await ProximPeer.get_call_peers()
	if result.error != OK:
		_log("create_host: get_call_peers failed — %s (err=%d)" % [error_string(result.error), result.error])
		return result.error
	for peer in result.peers:
		if peer.get("isHost", false):
			_log("create_host: ERR_ALREADY_IN_USE — host already exists")
			return ERR_ALREADY_IN_USE

	var err := _multiplayer_peer.create_server()
	if err != OK:
		_log("create_host: create_server() failed — %s (err=%d)" % [error_string(err), err])
		return err

	_my_game_id = 1
	ProximPeer.update_call_peer({"isHost": true, "gameId": 1})
	_log("create_host: OK — gameId=1")
	return OK


## Connect to Proxim, verify a host exists, assign a unique 5-digit
## gameId, then join as a WebRTC client. Returns OK on success,
## ERR_CANT_CONNECT if the WebSocket failed, or ERR_DOES_NOT_EXIST if
## no host is found.
func create_client() -> Error:
	_log("create_client: connecting to Proxim app...")
	if await ProximPeer.connect_to_app() != WebSocketPeer.STATE_OPEN:
		_log("create_client: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var result := await ProximPeer.get_call_peers()
	if result.error != OK:
		_log("create_client: get_call_peers failed — %s (err=%d)" % [error_string(result.error), result.error])
		return result.error
	var has_host := false
	var taken_ids := PackedInt32Array()
	for peer in result.peers:
		if peer.get("isHost", false):
			has_host = true
		taken_ids.append(int(peer.get("gameId", 0)))
	if not has_host:
		_log("create_client: ERR_DOES_NOT_EXIST — no host found")
		return ERR_DOES_NOT_EXIST

	var my_id: int
	while true:
		my_id = randi_range(10000, 99999)
		if my_id not in taken_ids:
			break

	var err := _multiplayer_peer.create_client(my_id)
	if err != OK:
		_log("create_client: create_client() failed — %s (err=%d)" % [error_string(err), err])
		return err

	_my_game_id = my_id
	ProximPeer.update_call_peer({"gameId": my_id})
	_log("create_client: OK — gameId=%d" % my_id)

	var buffered := _pending_messages.duplicate()
	_pending_messages.clear()
	for m in buffered:
		_dispatch(m.from, m.payload)
	return OK


func get_multiplayer_peer() -> WebRTCMultiplayerPeer:
	return _multiplayer_peer


# ── ProximPeer signal handlers ────────────────────────────────────────────────

func _on_peer_joined(game_id: int) -> void:
	_log("peer_joined: %d" % game_id)
	_start_peer(game_id)


func _on_peer_left(game_id: int) -> void:
	_log("peer_left: %d" % game_id)
	_peer_connections.erase(game_id)


func _on_peer_message(from: int, payload: Dictionary) -> void:
	if _my_game_id == 0:
		_pending_messages.append({"from": from, "payload": payload})
		return
	_dispatch(from, payload)


func _dispatch(from: int, payload: Dictionary) -> void:
	if from not in _peer_connections:
		_start_peer(from)
	var conn: WebRTCPeerConnection = _peer_connections.get(from)
	if conn == null:
		return
	var signal_type: String = payload.get("signalType", "")
	_log("signal received: from=%d type=%s" % [from, signal_type])
	match signal_type:
		"offer", "answer":
			conn.set_remote_description(signal_type, payload.get("sdp", ""))
		"ice":
			conn.add_ice_candidate(payload.get("media", ""), int(payload.get("index", 0)), payload.get("name", ""))


# ── WebRTC setup ──────────────────────────────────────────────────────────────

func _start_peer(peer_game_id: int) -> void:
	if peer_game_id == _my_game_id or peer_game_id in _peer_connections:
		return
	var offering := _my_game_id != 0 and _my_game_id < peer_game_id
	_log("start_peer: %d → %d (%s)" % [_my_game_id, peer_game_id, "offering" if offering else "waiting for offer"])
	var conn := WebRTCPeerConnection.new()
	var init_err := conn.initialize({"iceServers": _ICE_SERVERS})
	if init_err != OK:
		_log("start_peer: initialize failed — %s (err=%d) (WebRTC extension missing?)" % [error_string(init_err), init_err])
		return
	conn.session_description_created.connect(_on_session_description.bind(peer_game_id))
	conn.ice_candidate_created.connect(_on_ice_candidate.bind(peer_game_id))
	_peer_connections[peer_game_id] = conn
	var add_err := _multiplayer_peer.add_peer(conn, peer_game_id)
	if add_err != OK:
		_log("start_peer: add_peer failed — %s (err=%d)" % [error_string(add_err), add_err])
		_peer_connections.erase(peer_game_id)
		return
	if offering:
		conn.create_offer()


func _on_session_description(type: String, sdp: String, peer_game_id: int) -> void:
	_log("session_description: type=%s peer=%d" % [type, peer_game_id])
	var conn: WebRTCPeerConnection = _peer_connections.get(peer_game_id)
	if conn == null:
		return
	conn.set_local_description(type, sdp)
	ProximPeer.relay_to(peer_game_id, {"signalType": type, "sdp": sdp})


func _on_ice_candidate(media: String, index: int, candidate_name: String, peer_game_id: int) -> void:
	_log("ice_candidate: → %d media=%s index=%d" % [peer_game_id, media, index])
	ProximPeer.relay_to(peer_game_id, {"signalType": "ice", "media": media, "index": index, "name": candidate_name})


func _on_mp_peer_disconnected(peer_id: int) -> void:
	_log("mp_peer_disconnected: gameId=%d" % peer_id)
	_peer_connections.erase(peer_id)


func _reset() -> void:
	_peer_connections.clear()
	_my_game_id = 0
	_pending_messages.clear()


func _process(_delta: float) -> void:
	_multiplayer_peer.poll()
