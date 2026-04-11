extends Node
## Local WebRTC — uses a loopback TCP socket on SIGNAL_PORT for in-process
## signaling. Validates that the WebRTC GDExtension is installed and working
## without requiring the Proxim app or any external service.
##
## Host: starts TCPServer, waits for client "hello", creates WebRTC offer.
## Client: connects via TCP, announces peer ID, receives offer, responds.

const SIGNAL_PORT := 7778
const _ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302"]}]

var _peer := WebRTCMultiplayerPeer.new()
var _conn: WebRTCPeerConnection

var _is_host := false
var _my_id: int = 0
var _tcp_server := TCPServer.new()
var _tcp_stream: StreamPeerTCP
var _buf := ""
var _hello_sent := false


func _log(msg: String) -> void:
	var t := Time.get_time_dict_from_system()
	var ms := Time.get_ticks_msec() % 1000
	print("%02d:%02d:%02d.%03d [LocalWebRTC] %s" % [t.hour, t.minute, t.second, ms, msg])


func create_host() -> Error:
	_is_host = true
	_my_id = 1
	var err := _peer.create_server()
	if err != OK:
		_log("create_server failed — WebRTC extension missing? err=%d" % err)
		return err
	err = _tcp_server.listen(SIGNAL_PORT)
	if err != OK:
		_log("TCPServer.listen(%d) failed: err=%d" % [SIGNAL_PORT, err])
		return err
	_log("host ready, signaling on :%d" % SIGNAL_PORT)
	return OK


func create_client() -> Error:
	_is_host = false
	_my_id = randi_range(10000, 99999)
	var err := _peer.create_client(_my_id)
	if err != OK:
		_log("create_client failed — WebRTC extension missing? err=%d" % err)
		return err
	var stream := StreamPeerTCP.new()
	err = stream.connect_to_host("127.0.0.1", SIGNAL_PORT)
	if err != OK:
		_log("connect_to_host failed: err=%d" % err)
		return err
	_tcp_stream = stream
	_log("client: connecting, my_id=%d" % _my_id)
	return OK


func get_multiplayer_peer() -> WebRTCMultiplayerPeer:
	return _peer


func _process(_delta: float) -> void:
	_peer.poll()
	if _is_host:
		if _tcp_stream == null and _tcp_server.is_connection_available():
			_tcp_stream = _tcp_server.take_connection()
			_log("host: signaling client connected")
		if _tcp_stream:
			_poll_lines()
	else:
		if _tcp_stream:
			_tcp_stream.poll()
			if not _hello_sent and _tcp_stream.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				_hello_sent = true
				_send_json({"type": "hello", "id": _my_id})
				_log("client: sent hello id=%d" % _my_id)
			_poll_lines()


func _poll_lines() -> void:
	while _tcp_stream and _tcp_stream.get_available_bytes() > 0:
		_buf += _tcp_stream.get_utf8_string(_tcp_stream.get_available_bytes())
	while "\n" in _buf:
		var nl := _buf.find("\n")
		var line := _buf.left(nl).strip_edges()
		_buf = _buf.substr(nl + 1)
		if line.is_empty():
			continue
		var msg: Variant = JSON.parse_string(line)
		if msg is Dictionary:
			_handle_msg(msg)


func _handle_msg(msg: Dictionary) -> void:
	match msg.get("type", ""):
		"hello":
			# Host: client announced its peer ID — create connection and offer
			var client_id: int = msg.get("id", 0)
			_log("host: hello from client id=%d — creating offer" % client_id)
			_start_conn(client_id, true)
		"signal":
			var signal_type: String = msg.get("signal_type", "")
			_log("signal: type=%s" % signal_type)
			# Client: lazily create connection on first incoming offer
			if not _conn and signal_type == "offer":
				_start_conn(1, false)
			if not _conn:
				return
			match signal_type:
				"offer", "answer":
					_conn.set_remote_description(signal_type, msg.get("sdp", ""))
				"ice":
					_conn.add_ice_candidate(
						msg.get("media", ""), msg.get("index", 0), msg.get("name", ""))


func _start_conn(peer_id: int, make_offer: bool) -> void:
	_conn = WebRTCPeerConnection.new()
	var err := _conn.initialize({"iceServers": _ICE_SERVERS})
	if err != OK:
		_log("initialize failed — WebRTC extension missing? err=%d" % err)
		return
	_conn.session_description_created.connect(_on_sdp)
	_conn.ice_candidate_created.connect(_on_ice)
	_peer.add_peer(_conn, peer_id)
	if make_offer:
		_conn.create_offer()


func _on_sdp(type: String, sdp: String) -> void:
	_log("sdp: type=%s" % type)
	_conn.set_local_description(type, sdp)
	_send_json({"type": "signal", "signal_type": type, "sdp": sdp})


func _on_ice(media: String, index: int, name: String) -> void:
	_log("ice: media=%s index=%d" % [media, index])
	_send_json({"type": "signal", "signal_type": "ice", "media": media, "index": index, "name": name})


func _send_json(data: Dictionary) -> void:
	if _tcp_stream == null:
		return
	_tcp_stream.put_data((JSON.stringify(data) + "\n").to_utf8_buffer())
