extends Node

const _PROXIM_URL := "ws://127.0.0.1:5656"
const _ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302"]}]

var _web_socket := WebSocketPeer.new()
var _multiplayer_peer := WebRTCMultiplayerPeer.new()
var _my_game_id: int = 0
var _peer_connections: Dictionary = {}  # game_id (int) -> WebRTCPeerConnection


func connect_to_app() -> WebSocketPeer.State:
	if _web_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return WebSocketPeer.STATE_OPEN
	_web_socket.connect_to_url(_PROXIM_URL)
	while _web_socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		await get_tree().process_frame
	return _web_socket.get_ready_state()


## Connect to the Proxim app, verify no host exists, then claim the host role
## with game_id 1. Returns OK on success, ERR_ALREADY_IN_USE if a host exists,
## or ERR_CANT_CONNECT if the WebSocket connection failed.
func create_host() -> Error:
	print("[ProximPeer] create_host: connecting to Proxim app...")
	if await connect_to_app() != WebSocketPeer.STATE_OPEN:
		print("[ProximPeer] create_host: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var peers := await get_call_peers()
	for peer in peers:
		if peer.get("is_host", false):
			print("[ProximPeer] create_host: ERR_ALREADY_IN_USE — host already exists")
			return ERR_ALREADY_IN_USE

	var err := _multiplayer_peer.create_server()
	if err != OK:
		print("[ProximPeer] create_host: _multiplayer_peer.create_server() failed — err=%d" % err)
		return err

	_my_game_id = 1
	update_peer({"is_host": true, "game_id": 1})
	print("[ProximPeer] create_host: OK — game_id=1")
	return OK


## Connect to the Proxim app, verify a host exists, assign a unique 5-digit
## game_id, then join as a WebRTC client. Returns OK on success,
## ERR_CANT_CONNECT if the WebSocket failed, or ERR_DOES_NOT_EXIST if no host
## is found.
func create_client() -> Error:
	print("[ProximPeer] create_client: connecting to Proxim app...")
	if await connect_to_app() != WebSocketPeer.STATE_OPEN:
		print("[ProximPeer] create_client: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var peers := await get_call_peers()
	var has_host := false
	var taken_ids := PackedInt32Array()
	for peer in peers:
		if peer.get("is_host", false):
			has_host = true
		taken_ids.append(peer.get("game_id", 0))
	if not has_host:
		print("[ProximPeer] create_client: ERR_DOES_NOT_EXIST — no host found")
		return ERR_DOES_NOT_EXIST

	var my_id: int
	while true:
		my_id = randi_range(10000, 99999)
		if my_id not in taken_ids:
			break

	var err := _multiplayer_peer.create_client(my_id)
	if err != OK:
		print("[ProximPeer] create_client: _multiplayer_peer.create_client() failed — err=%d" % err)
		return err

	_my_game_id = my_id
	update_peer({"game_id": my_id})
	print("[ProximPeer] create_client: OK — game_id=%d" % my_id)
	return OK


func get_multiplayer_peer() -> WebRTCMultiplayerPeer:
	return _multiplayer_peer


## Send a full peer update as a dictionary. Sent infrequently (state changes).
## Keys match Peer fields: uid, display_name, is_host, muted, gain,
## panner_enabled, deafened, coordinates ([x, y, z]).
func update_peer(data: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({"type": "update_peer", "data": data}))


## Relay a WebRTC signaling message to another peer through the Proxim app.
## type: "offer" | "answer" | "ice"
## For offer/answer: data should contain {"sdp": String}
## For ice:          data should contain {"media": String, "index": int, "name": String}
func send_signal(to: int, type: String, data: Dictionary) -> void:
	print("[ProximPeer] send_signal: → %d type=%s" % [to, type])
	var msg := {"type": "signal", "to": to, "signal_type": type}
	msg.merge(data)
	_web_socket.send_text(JSON.stringify(msg))


## Open a WebRTC connection to peer_game_id. The peer with the lower game_id
## creates the offer; the higher-id peer waits for it.
func start_peer(peer_game_id: int) -> void:
	if peer_game_id in _peer_connections:
		return
	var offering := _my_game_id != 0 and _my_game_id < peer_game_id
	print("[ProximPeer] start_peer: %d → %d (%s)" % [_my_game_id, peer_game_id, "offering" if offering else "waiting for offer"])
	var conn := WebRTCPeerConnection.new()
	conn.initialize({"iceServers": _ICE_SERVERS})
	conn.session_description_created.connect(_on_session_description.bind(peer_game_id))
	conn.ice_candidate_created.connect(_on_ice_candidate.bind(peer_game_id))
	_peer_connections[peer_game_id] = conn
	_multiplayer_peer.add_peer(conn, peer_game_id)
	if offering:
		conn.create_offer()


func _on_session_description(type: String, sdp: String, peer_game_id: int) -> void:
	print("[ProximPeer] session_description: type=%s peer=%d" % [type, peer_game_id])
	var conn: WebRTCPeerConnection = _peer_connections.get(peer_game_id)
	if not conn:
		return
	conn.set_local_description(type, sdp)
	send_signal(peer_game_id, type, {"sdp": sdp})


func _on_ice_candidate(media: String, index: int, candidate_name: String, peer_game_id: int) -> void:
	print("[ProximPeer] ice_candidate: → %d media=%s index=%d" % [peer_game_id, media, index])
	send_signal(peer_game_id, "ice", {"media": media, "index": index, "name": candidate_name})


## Send a compact 8-byte proximity update. Call every frame / physics tick.
## State changes (mute, panner) go through update_peer instead.
##
## Packet layout:
##   slot  uint8    1 byte  — peer slot index
##   x     float16  2 bytes — world position (bytes 1–2)
##   y     float16  2 bytes — (bytes 3–4)
##   z     float16  2 bytes — (bytes 5–6)
##   gain  uint8    1 byte  — 0–255 mapped to 0.0–1.0 (byte 7)
func update_proximity(slot: int, x: float, y: float, z: float, gain: float) -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf[0] = slot & 0xFF
	buf.encode_half(1, x)
	buf.encode_half(3, y)
	buf.encode_half(5, z)
	buf[7] = int(clampf(gain, 0.0, 1.0) * 255.0) & 0xFF
	_web_socket.send(buf)


## Request the current call peers from Proxim. Returns an Array of Dictionaries,
## each with at least a "display_name" key.
func get_call_peers() -> Array:
	_web_socket.send_text(JSON.stringify({"type": "get_call_peers"}))
	while true:
		await get_tree().process_frame
		_web_socket.poll()
		if _web_socket.get_available_packet_count() > 0:
			var msg: Variant = JSON.parse_string(_web_socket.get_packet().get_string_from_utf8())
			if msg is Dictionary and msg.get("type") == "call_peers":
				return msg.get("peers", [])
	return []


func _process(_delta: float) -> void:
	_web_socket.poll()
	_multiplayer_peer.poll()
	while _web_socket.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(_web_socket.get_packet().get_string_from_utf8())
		if not msg is Dictionary:
			continue
		match msg.get("type"):
			"player_joined":
				var peer_id: int = msg.get("game_id", 0)
				print("[ProximPeer] player_joined: game_id=%d — starting peer" % peer_id)
				start_peer(peer_id)
			"signal":
				_handle_signal(msg)


func _handle_signal(msg: Dictionary) -> void:
	var from: int = msg.get("from", 0)
	var signal_type: String = msg.get("signal_type", "")
	if from == 0:
		return
	print("[ProximPeer] signal received: from=%d type=%s" % [from, signal_type])
	# Lazily create a connection for the higher-id peer receiving the first offer.
	if from not in _peer_connections:
		start_peer(from)
	var conn: WebRTCPeerConnection = _peer_connections.get(from)
	if not conn:
		return
	match signal_type:
		"offer", "answer":
			conn.set_remote_description(signal_type, msg.get("sdp", ""))
		"ice":
			conn.add_ice_candidate(msg.get("media", ""), msg.get("index", 0), msg.get("name", ""))
