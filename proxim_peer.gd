extends Node

const _PROXIM_URL := "ws://127.0.0.1:5656"
const _ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302"]}]

var _web_socket := WebSocketPeer.new()
var _multiplayer_peer := WebRTCMultiplayerPeer.new()
var _my_game_id: int = 0
var _peer_connections: Dictionary = {}  # game_id (int) -> WebRTCPeerConnection
var _gain_hot_buf := PackedByteArray()
var _panner_hot_buf := PackedByteArray()
var _listener_hot_buf := PackedByteArray()
var _pending_call_peers: Variant = null  # null = waiting, Array = received
var _pending_signals: Array = []         # signals buffered before _my_game_id is set


func _log(msg: String) -> void:
	var t := Time.get_time_dict_from_system()
	var ms := Time.get_ticks_msec() % 1000
	print("%02d:%02d:%02d.%03d [ProximPeer] %s" % [t.hour, t.minute, t.second, ms, msg])


func _ready() -> void:
	_gain_hot_buf.resize(5)
	_panner_hot_buf.resize(16)
	_listener_hot_buf.resize(18)
	_multiplayer_peer.peer_disconnected.connect(_on_peer_disconnected)


func connect_to_app() -> WebSocketPeer.State:
	if _web_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return WebSocketPeer.STATE_OPEN
	_web_socket.connect_to_url(_PROXIM_URL)
	var deadline := Time.get_ticks_msec() + 2000
	while _web_socket.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		if Time.get_ticks_msec() >= deadline:
			_log("connect_to_app: timed out")
			_web_socket.close()
			return WebSocketPeer.STATE_CLOSED
		await get_tree().process_frame
	return _web_socket.get_ready_state()


## Connect to the Proxim app, verify no host exists, then claim the host role
## with game_id 1. Returns OK on success, ERR_ALREADY_IN_USE if a host exists,
## or ERR_CANT_CONNECT if the WebSocket connection failed.
func create_host() -> Error:
	_log("create_host: connecting to Proxim app...")
	if await connect_to_app() != WebSocketPeer.STATE_OPEN:
		_log("create_host: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var peers := await get_call_peers()
	for peer in peers:
		if peer.get("is_host", false):
			_log("create_host: ERR_ALREADY_IN_USE — host already exists")
			return ERR_ALREADY_IN_USE

	var err := _multiplayer_peer.create_server()
	if err != OK:
		_log("create_host: _multiplayer_peer.create_server() failed — err=%d" % err)
		return err

	_my_game_id = 1
	update_peer({"is_host": true, "game_id": 1})
	_log("create_host: OK — game_id=1")
	return OK


## Connect to the Proxim app, verify a host exists, assign a unique 5-digit
## game_id, then join as a WebRTC client. Returns OK on success,
## ERR_CANT_CONNECT if the WebSocket failed, or ERR_DOES_NOT_EXIST if no host
## is found.
func create_client() -> Error:
	_log("create_client: connecting to Proxim app...")
	if await connect_to_app() != WebSocketPeer.STATE_OPEN:
		_log("create_client: ERR_CANT_CONNECT")
		return ERR_CANT_CONNECT

	var peers := await get_call_peers()
	var has_host := false
	var taken_ids := PackedInt32Array()
	for peer in peers:
		if peer.get("is_host", false):
			has_host = true
		taken_ids.append(peer.get("game_id", 0))
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
		_log("create_client: _multiplayer_peer.create_client() failed — err=%d" % err)
		return err

	_my_game_id = my_id
	# Replay any signals that arrived before we were fully initialized.
	var buffered := _pending_signals.duplicate()
	_pending_signals.clear()
	for msg in buffered:
		_handle_signal(msg)
	update_peer({"game_id": my_id})
	_log("create_client: OK — game_id=%d" % my_id)
	return OK


func get_multiplayer_peer() -> WebRTCMultiplayerPeer:
	return _multiplayer_peer


## Send a full peer update as a dictionary. Sent infrequently (state changes).
## Keys match Peer fields: uid, display_name, is_host, muted, gain,
## panner_enabled, deafened, coordinates ([x, y, z]).
func update_peer(data: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({"type": "update_peer", "data": data}))


## Relay a WebRTC signaling message to another peer through the Proxim app.
## signal_type: "offer" | "answer" | "ice"
## For offer/answer: data should contain {"sdp": String}
## For ice:          data should contain {"media": String, "index": int, "name": String}
func send_signal(to: int, signal_type: String, data: Dictionary) -> void:
	_log("send_signal: → %d type=%s" % [to, signal_type])
	var msg := {"type": "signal", "to": to, "signal_type": signal_type}
	msg.merge(data)
	_web_socket.send_text(JSON.stringify(msg))


## Open a WebRTC connection to peer_game_id. The peer with the lower game_id
## creates the offer; the higher-id peer waits for it.
func start_peer(peer_game_id: int) -> void:
	if peer_game_id in _peer_connections:
		return
	var offering := _my_game_id != 0 and _my_game_id < peer_game_id
	_log("start_peer: %d → %d (%s)" % [_my_game_id, peer_game_id, "offering" if offering else "waiting for offer"])
	var conn := WebRTCPeerConnection.new()
	var init_err := conn.initialize({"iceServers": _ICE_SERVERS})
	if init_err != OK:
		_log("start_peer: initialize failed — err=%d (WebRTC extension missing?)" % init_err)
		return
	conn.session_description_created.connect(_on_session_description.bind(peer_game_id))
	conn.ice_candidate_created.connect(_on_ice_candidate.bind(peer_game_id))
	_peer_connections[peer_game_id] = conn
	var add_err := _multiplayer_peer.add_peer(conn, peer_game_id)
	if add_err != OK:
		_log("start_peer: add_peer failed — err=%d" % add_err)
		_peer_connections.erase(peer_game_id)
		return
	if offering:
		conn.create_offer()


func _on_session_description(type: String, sdp: String, peer_game_id: int) -> void:
	_log("session_description: type=%s peer=%d" % [type, peer_game_id])
	var conn: WebRTCPeerConnection = _peer_connections.get(peer_game_id)
	if not conn:
		return
	conn.set_local_description(type, sdp)
	send_signal(peer_game_id, type, {"sdp": sdp})


func _on_ice_candidate(media: String, index: int, candidate_name: String, peer_game_id: int) -> void:
	_log("ice_candidate: → %d media=%s index=%d" % [peer_game_id, media, index])
	send_signal(peer_game_id, "ice", {"media": media, "index": index, "name": candidate_name})


## Send a compact 5-byte relative gain update. Call every frame / physics tick.
##
## Packet layout:
##   game_id  uint32 LE  4 bytes — peer game_id
##   gain     uint8      1 byte  — 0–255 mapped to 0.0–1.0
func update_gain_hot(game_id: int, gain: float) -> void:
	_gain_hot_buf.encode_u32(0, game_id)
	_gain_hot_buf[4] = int(clampf(gain, 0.0, 1.0) * 255.0) & 0xFF
	_web_socket.send(_gain_hot_buf)


## Send a compact 16-byte hot panner update. Call every frame / physics tick for
## peers whose position or orientation changes frequently.
## Use update_panner_props for model types, distances, cone angles, etc.
##
## Packet layout:
##   game_id       uint32 LE  4 bytes — peer game_id (bytes 0–3)
##   position_x    float16    2 bytes — (bytes 4–5)
##   position_y    float16    2 bytes — (bytes 6–7)
##   position_z    float16    2 bytes — (bytes 8–9)
##   orientation_x float16    2 bytes — (bytes 10–11)
##   orientation_y float16    2 bytes — (bytes 12–13)
##   orientation_z float16    2 bytes — (bytes 14–15)
func update_panner_hot(game_id: int, position_x: float, position_y: float, position_z: float,
		orientation_x: float, orientation_y: float, orientation_z: float) -> void:
	_panner_hot_buf.encode_u32(0,  game_id)
	_panner_hot_buf.encode_half(4,  position_x)
	_panner_hot_buf.encode_half(6,  position_y)
	_panner_hot_buf.encode_half(8,  position_z)
	_panner_hot_buf.encode_half(10, orientation_x)
	_panner_hot_buf.encode_half(12, orientation_y)
	_panner_hot_buf.encode_half(14, orientation_z)
	_web_socket.send(_panner_hot_buf)


## Send full PannerProps for a peer as JSON. Use for infrequent changes such as
## panning/distance model, ref_distance, max_distance, rolloff_factor, and cone angles.
## game_id: peer game_id
## data: Dictionary with any subset of PannerProps keys (snake_case).
func update_panner_props(game_id: int, data: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({"type": "update_panner_props", "game_id": game_id, "data": data}))


## Send a compact 18-byte hot listener update. Call every frame / physics tick
## when the listener position or orientation changes frequently.
## Use update_listener_props for a one-shot full update instead.
##
## Packet layout:
##   position_x float16  2 bytes — (bytes 0–1)
##   position_y float16  2 bytes — (bytes 2–3)
##   position_z float16  2 bytes — (bytes 4–5)
##   forward_x  float16  2 bytes — (bytes 6–7)
##   forward_y  float16  2 bytes — (bytes 8–9)
##   forward_z  float16  2 bytes — (bytes 10–11)
##   up_x       float16  2 bytes — (bytes 12–13)
##   up_y       float16  2 bytes — (bytes 14–15)
##   up_z       float16  2 bytes — (bytes 16–17)
func update_listener_hot(position_x: float, position_y: float, position_z: float,
		forward_x: float, forward_y: float, forward_z: float,
		up_x: float, up_y: float, up_z: float) -> void:
	_listener_hot_buf.encode_half(0,  position_x)
	_listener_hot_buf.encode_half(2,  position_y)
	_listener_hot_buf.encode_half(4,  position_z)
	_listener_hot_buf.encode_half(6,  forward_x)
	_listener_hot_buf.encode_half(8,  forward_y)
	_listener_hot_buf.encode_half(10, forward_z)
	_listener_hot_buf.encode_half(12, up_x)
	_listener_hot_buf.encode_half(14, up_y)
	_listener_hot_buf.encode_half(16, up_z)
	_web_socket.send(_listener_hot_buf)


## Send full ListenerProps as JSON. Use for infrequent / one-shot updates where
## binary precision isn't a concern, or when you only need to set a subset of fields.
## data: Dictionary with any subset of ListenerProps keys (snake_case).
func update_listener_props(data: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({"type": "update_listener_props", "data": data}))


## Reset all audio state in the Proxim app to defaults: gain, relative gain,
## deafened, panner, and listener props for all peers, plus legacyAudio for self.
func reset_audio() -> void:
	_web_socket.send_text(JSON.stringify({"type": "reset_audio"}))


## Update position interpolation settings. Both parameters are optional — pass
## null to leave a setting unchanged.
##   position_interpolation: bool — whether to smooth position/orientation
##     ramps between updates (default true).
##   position_frequency: float — ramp duration in seconds, should match your
##     update interval (default 0.1).
func update_proximity_settings(position_interpolation: Variant = null, position_frequency: Variant = null) -> void:
	var msg := {"type": "update_proximity_settings"}
	if position_interpolation != null:
		msg["position_interpolation"] = position_interpolation
	if position_frequency != null:
		msg["position_frequency"] = position_frequency
	_web_socket.send_text(JSON.stringify(msg))


## Request the current call peers from Proxim. Returns an Array of Dictionaries,
## each with at least a "display_name" key. Returns [] on timeout (2 s).
func get_call_peers() -> Array:
	_pending_call_peers = null
	_web_socket.send_text(JSON.stringify({"type": "get_call_peers"}))
	var deadline := Time.get_ticks_msec() + 2000
	while _pending_call_peers == null:
		if Time.get_ticks_msec() >= deadline:
			_log("get_call_peers: timed out")
			return []
		await get_tree().process_frame
	var result: Array = _pending_call_peers
	_pending_call_peers = null
	return result


func _on_peer_disconnected(peer_id: int) -> void:
	_log("peer_disconnected: game_id=%d" % peer_id)
	_peer_connections.erase(peer_id)


func _process(_delta: float) -> void:
	_web_socket.poll()
	_multiplayer_peer.poll()
	while _web_socket.get_available_packet_count() > 0:
		var packet := _web_socket.get_packet()
		if not _web_socket.was_string_packet():
			continue
		var msg: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if not msg is Dictionary:
			continue
		match msg.get("type"):
			"call_peers":
				_pending_call_peers = msg.get("peers", [])
			"connection_request":
				var peer_id: int = msg.get("game_id", 0)
				_log("connection_request: game_id=%d — starting peer" % peer_id)
				start_peer(peer_id)
			"signal":
				_handle_signal(msg)


func _handle_signal(msg: Dictionary) -> void:
	if _my_game_id == 0:
		_pending_signals.append(msg)
		return
	var from: int = msg.get("from", 0)
	var signal_type: String = msg.get("signal_type", "")
	if from == 0:
		return
	_log("signal received: from=%d type=%s" % [from, signal_type])
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
