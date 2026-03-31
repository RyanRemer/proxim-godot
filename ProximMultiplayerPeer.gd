## ProximMultiplayerPeer — implements MultiplayerPeerExtension over Proxim's
## two-route WebSocket protocol.
##
## Depends on a ProximPeer instance for session state (peer IDs, names, volume).
## Adds the /godot binary data pipe and wires Godot's multiplayer interface.
##
## Usage:
##   var proxim_peer := ProximPeer.new()
##   add_child(proxim_peer)
##
##   var mp := ProximMultiplayerPeer.new()
##   mp.proxim_peer = proxim_peer
##   multiplayer.multiplayer_peer = mp
class_name ProximMultiplayerPeer extends MultiplayerPeerExtension

## Must be set before this object is used. Pass the same ProximPeer node that
## was added to the scene tree.
var proxim_peer: ProximPeer = null

const _URL := "ws://127.0.0.1:5656/godot"
const _MAX_RECONNECT_DELAY := 30.0

var _ws := WebSocketPeer.new()
var _reconnect_timer: float = 0.0
var _reconnect_delay: float = 1.0
var _ws_open: bool = false

# Packet queue: Array of { data: PackedByteArray, sender_id: int, channel: int }
var _incoming: Array = []
var _current: Dictionary = {}

var _target_peer: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _transfer_channel: int = 0


func _ready() -> void:
	if proxim_peer == null:
		push_error("ProximMultiplayerPeer: proxim_peer must be set before _ready()")
		return
	proxim_peer.welcomed.connect(_on_welcomed)
	proxim_peer.peer_joined.connect(_on_peer_joined)
	proxim_peer.peer_left.connect(_on_peer_left)
	_connect_godot()


func _connect_godot() -> void:
	_ws = WebSocketPeer.new()
	_ws.connect_to_url(_URL)


# --- MultiplayerPeerExtension overrides ---

func _poll() -> void:
	# Poll the control channel so ProximPeer signals fire even when the game
	# only calls multiplayer.poll() rather than processing ProximPeer separately.
	if proxim_peer != null:
		proxim_peer._poll()

	# Poll the /godot data pipe
	if _reconnect_timer > 0.0:
		return
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_open:
			_ws_open = true
		while _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet()
			if raw.size() >= 5:
				var sender_id := raw.decode_s32(0)
				var channel: int = raw[4]
				var payload := raw.slice(5)
				_incoming.append({
					"data": payload,
					"sender_id": sender_id,
					"channel": channel,
				})

	elif state == WebSocketPeer.STATE_CLOSED:
		if _ws_open:
			_ws_open = false
		_schedule_reconnect()


func _get_unique_id() -> int:
	return proxim_peer.your_id if proxim_peer != null else 0


func _is_server() -> bool:
	return _get_unique_id() == 1


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	_current = _incoming[0]
	_incoming.pop_front()
	return _current.get("data", PackedByteArray()) as PackedByteArray


func _get_packet_peer() -> int:
	return _current.get("sender_id", 0)


func _get_packet_channel() -> int:
	return _current.get("channel", 0)


func _get_packet_mode() -> int:
	if _current.get("channel", 0) == 0:
		return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _put_packet_script(data: PackedByteArray) -> Error:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE

	# Map transfer mode to channel index: 0 = unreliable, 1 = reliable
	var channel: int
	if (_transfer_mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE or
			_transfer_mode == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED):
		channel = 0
	else:
		channel = 1

	var envelope := PackedByteArray()
	envelope.resize(5)
	envelope.encode_s32(0, _target_peer)
	envelope[4] = channel
	envelope.append_array(data)
	_ws.send(envelope, WebSocketPeer.WRITE_MODE_BINARY)
	return OK


func _set_target_peer(peer_id: int) -> void:
	_target_peer = peer_id


func _get_transfer_mode() -> int:
	return _transfer_mode


func _set_transfer_mode(mode: int) -> void:
	_transfer_mode = mode


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_connection_status() -> int:
	if proxim_peer == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	if _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		return MultiplayerPeer.CONNECTION_CONNECTING
	if _ws_open and proxim_peer.your_id != 0:
		return MultiplayerPeer.CONNECTION_CONNECTED
	return MultiplayerPeer.CONNECTION_DISCONNECTED


func _close() -> void:
	_ws.close()
	_ws_open = false
	proxim_peer.close()
	_reconnect_timer = 0.0


func _disconnect_peer(_peer_id: int, _force: bool) -> void:
	pass  # no-op: Proxim manages connections; individual peer disconnect is not exposed


# --- ProximPeer signal handlers ---

func _on_welcomed(id: int, peers: Array) -> void:
	peer_connected.emit(id)          # emit our own ID as "connected"
	for p: Variant in peers:
		if typeof(p) == TYPE_DICTIONARY:
			peer_connected.emit(p.get("id", 0) as int)


func _on_peer_joined(id: int, _name: String) -> void:
	peer_connected.emit(id)


func _on_peer_left(id: int) -> void:
	peer_disconnected.emit(id)


# --- Proxied ProximPeer helpers ---

## Forward to ProximPeer.set_peer_volume() for convenience.
func set_peer_volume(peer_id: int, multiplier: float) -> void:
	proxim_peer.set_peer_volume(peer_id, multiplier)


## Forward to ProximPeer.get_peer_names() for convenience.
func get_peer_names() -> Dictionary:
	return proxim_peer.get_peer_names()


# --- Internal ---

func _schedule_reconnect() -> void:
	_reconnect_timer = _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, _MAX_RECONNECT_DELAY)
