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

## Emitted when a peer's WebRTC connection becomes active.
signal peer_joined(id: int, name: String)

## Emitted when a peer leaves the room.
signal peer_left(id: int)

## Our stable integer peer ID within this session (0 until welcomed).
var your_id: int = 0

const _URL := "ws://127.0.0.1:5656/proxim"
const _MAX_RECONNECT_DELAY := 30.0

var _ws := WebSocketPeer.new()
var _peer_names: Dictionary = {}     # int -> String
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
		_schedule_reconnect()


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
			_open = false
			your_id = 0
			_peer_names.clear()
		_schedule_reconnect()


func _handle_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var msg: Variant = json.data
	if typeof(msg) != TYPE_DICTIONARY:
		return

	match msg.get("type", ""):
		"hello":
			var version: int = msg.get("version", 0)
			if version != 1:
				push_warning("ProximPeer: unsupported protocol version %d" % version)
			_open = true
			connected.emit()

		"welcome":
			your_id = msg.get("your_id", 0)
			var peers: Array = []
			for p: Variant in msg.get("peers", []):
				if typeof(p) != TYPE_DICTIONARY:
					continue
				var id: int = p.get("id", 0)
				var name: String = p.get("name", "")
				_peer_names[id] = name
				peers.append({"id": id, "name": name})
			welcomed.emit(your_id, peers)

		"peer_connected":
			var id: int = msg.get("id", 0)
			var name: String = msg.get("name", "")
			_peer_names[id] = name
			peer_joined.emit(id, name)

		"peer_disconnected":
			var id: int = msg.get("id", 0)
			_peer_names.erase(id)
			peer_left.emit(id)


## Send a volume multiplier for a specific peer to Proxim.
## multiplier 0.0 = silent, 1.0 = normal, > 1.0 = boosted.
func set_peer_volume(peer_id: int, multiplier: float) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
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
	_reconnect_timer = _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, _MAX_RECONNECT_DELAY)
