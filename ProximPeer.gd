## ProximPeer — standalone control client for the Proxim /proxim WebSocket route.
##
## Handles session lifecycle (hello/welcome/peer_connected/peer_disconnected) and
## exposes set_peer_volume(). Use this alone for voice-only games, or as the
## dependency for ProximMultiplayerPeer when you also need the data pipe.
##
## Add as a child node so _process() runs automatically.
class_name ProximPeer extends Node

## Emitted after receiving "hello" from Proxim (version verified).
signal connected

## Emitted after Proxim assigns our integer ID and sends the current peer list.
## peers is an Array of Dictionaries: [{ "id": int, "name": String }, ...]
signal welcomed(your_id: int, peers: Array)

## Emitted when a peer's WebRTC connection becomes active (joined the Proxim call).
signal peer_joined_call(id: int, name: String)

## Emitted when a peer leaves the Proxim call.
signal peer_left_call(id: int)

## Emitted when a peer joins the game session.
signal peer_joined_game(id: int, name: String)

## Emitted when a peer leaves the game session (explicit leave or call disconnect).
signal peer_left_game(id: int)

## Our stable integer peer ID within this session (0 until welcomed).
var your_id: int = 0

const _URL := "ws://127.0.0.1:5656/proxim"
const _MAX_RECONNECT_DELAY := 30.0

var _ws := WebSocketPeer.new()
var _peer_names: Dictionary = {}     # int -> String
var _game_peers: Dictionary = {}     # int -> String (peers currently in the game session)
var _reconnect_timer: float = 0.0
var _reconnect_delay: float = 1.0
var _open: bool = false


func _ready() -> void:
	_connect_ws()


func _process(delta: float) -> void:
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_connect_ws()
		return
	_poll()


func _connect_ws() -> void:
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(_URL)
	if err != OK:
		print("[ProximPeer] connect_to_url failed (err=%d), will retry" % err)
		_schedule_reconnect()
	else:
		print("[ProximPeer] connecting to %s" % _URL)


## Drain buffered WebSocket frames and route control messages.
## Called automatically from _process(); also called by ProximMultiplayerPeer._poll().
func _poll() -> void:
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		while _ws.get_available_packet_count() > 0:
			var text := _ws.get_packet().get_string_from_utf8()
			_handle_message(text)

	elif state == WebSocketPeer.STATE_CLOSED:
		if _open:
			print("[ProximPeer] connection closed, will retry")
			_open = false
			your_id = 0
			_peer_names.clear()
			_game_peers.clear()
		_schedule_reconnect()


func _handle_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var msg: Variant = json.data
	if typeof(msg) != TYPE_DICTIONARY:
		return

	var msg_type: String = msg.get("type", "")
	print("[ProximPeer] recv: %s" % msg_type)
	match msg_type:
		"hello":
			var version: int = msg.get("version", 0)
			if version != 1:
				push_warning("ProximPeer: unsupported protocol version %d" % version)
			print("[ProximPeer] hello version=%d — sending get_state" % version)
			_open = true
			_ws.send_text(JSON.stringify({"type": "get_state"}))
			connected.emit()

		"state":
			your_id = msg.get("your_id", 0)
			var peers: Array = []
			for p: Variant in msg.get("peers", []):
				if typeof(p) != TYPE_DICTIONARY:
					continue
				var id: int = p.get("id", 0)
				var name: String = p.get("name", "")
				_peer_names[id] = name
				peers.append({"id": id, "name": name})
			for p: Variant in msg.get("game_peers", []):
				if typeof(p) != TYPE_DICTIONARY:
					continue
				var id: int = p.get("id", 0)
				var name: String = p.get("name", "")
				_game_peers[id] = name
				peer_joined_game.emit(id, name)
			print("[ProximPeer] state: your_id=%d peers=%s game_peers=%s" % [your_id, peers, _game_peers.keys()])
			welcomed.emit(your_id, peers)

		"peer_connected":
			var id: int = msg.get("id", 0)
			var name: String = msg.get("name", "")
			print("[ProximPeer] peer_connected: id=%d name=%s" % [id, name])
			_peer_names[id] = name
			peer_joined_call.emit(id, name)

		"peer_disconnected":
			var id: int = msg.get("id", 0)
			print("[ProximPeer] peer_disconnected: id=%d" % id)
			_peer_names.erase(id)
			peer_left_call.emit(id)
			if _game_peers.erase(id):
				peer_left_game.emit(id)

		"peer_joined_game":
			var id: int = msg.get("id", 0)
			var name: String = msg.get("name", "")
			print("[ProximPeer] peer_joined_game: id=%d name=%s" % [id, name])
			_game_peers[id] = name
			peer_joined_game.emit(id, name)

		"peer_left_game":
			var id: int = msg.get("id", 0)
			print("[ProximPeer] peer_left_game: id=%d" % id)
			if _game_peers.erase(id):
				peer_left_game.emit(id)

		_:
			print("[ProximPeer] unhandled message type: %s" % msg_type)


## Notify Proxim that this player has entered the game session.
## Proxim will broadcast peer_joined_game to all other call members.
func join_game() -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("[ProximPeer] join_game called but WS is not open")
		return
	print("[ProximPeer] send: join_game id=%d" % your_id)
	_ws.send_text(JSON.stringify({"type": "join_game", "id": your_id}))


## Notify Proxim that this player has left the game session.
func leave_game() -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("[ProximPeer] leave_game called but WS is not open")
		return
	print("[ProximPeer] send: leave_game id=%d" % your_id)
	_ws.send_text(JSON.stringify({"type": "leave_game", "id": your_id}))


## Returns a copy of the current id → name map for peers in the game session.
func get_game_peers() -> Dictionary:
	return _game_peers.duplicate()


## Send a volume multiplier for a specific peer to Proxim.
## multiplier 0.0 = silent, 1.0 = normal, > 1.0 = boosted.
func set_peer_volume(peer_id: int, multiplier: float) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("[ProximPeer] set_peer_volume called but WS is not open")
		return
	print("[ProximPeer] send: set_volume peer_id=%d multiplier=%f" % [peer_id, multiplier])
	_ws.send_text(JSON.stringify({
		"type": "set_volume",
		"peer_id": peer_id,
		"multiplier": multiplier,
	}))


## Returns a copy of the current id → name map for all known peers.
func get_peer_names() -> Dictionary:
	return _peer_names.duplicate()



## Close the WebSocket connection and stop reconnecting.
func close() -> void:
	_ws.close()
	_open = false
	_reconnect_timer = 0.0


func _schedule_reconnect() -> void:
	if _reconnect_timer <= 0.0:
		print("[ProximPeer] scheduling reconnect in %.1fs" % _reconnect_delay)
	_reconnect_timer = _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, _MAX_RECONNECT_DELAY)
