extends Node
## Autoload Singleton

## Connects to the Proxim companion app over WebSocket and exposes:
##   • A generic peer-to-peer relay (relay_to / peer_message)
##   • Spatial audio controls that map 1:1 to the Web Audio API
##
## Wire protocol is camelCase end-to-end. Dict keys you pass through
## `update_call_peer`, `add_panner_node` config, etc. are sent verbatim —
## use camelCase (gameId, isHost, panningModel, ...).

const _PROXIM_URL := "ws://127.0.0.1:5656"

## Emitted when Proxim leaves its voice call (intentional leave, kick, or network drop).
## Listen to this to clean up any voice-dependent state.
signal proxim_disconnected()

## Emitted when Proxim joins a voice call and is ready to receive peer state.
## The addon automatically resends the last update_call_peer data before emitting this,
## so gameId and isHost are already restored. Use this signal to resend any
## audio settings (add_gain_node, add_panner_node, etc.).
signal proxim_connected()

## Emitted when another game client joins the Proxim call. Use this to open
## a game-specific connection (WebRTC, etc.) to the peer.
signal peer_joined(game_id: int)

## Emitted when another game client leaves the Proxim call.
signal peer_left(game_id: int)

## Emitted when another game client relays a message to us via `relay_to`.
## `payload` is the exact Dictionary the sender passed — opaque to Proxim.
signal peer_message(from_game_id: int, payload: Dictionary)

var _web_socket := WebSocketPeer.new()
var _gain_hot_buf := PackedByteArray()
var _panner_hot_buf := PackedByteArray()
var _listener_hot_buf := PackedByteArray()
var _pending_call_peers: Variant = null  # null = waiting, Array = received
var _last_peer_data: Dictionary = {}     # last data sent via update_call_peer — resent on proxim_connected


func _log(msg: String) -> void:
	var t := Time.get_time_dict_from_system()
	var ms := Time.get_ticks_msec() % 1000
	print("%02d:%02d:%02d.%03d [ProximPeer] %s" % [t.hour, t.minute, t.second, ms, msg])


func _ready() -> void:
	_gain_hot_buf.resize(5)
	_panner_hot_buf.resize(16)
	_listener_hot_buf.resize(18)


## Open (or reuse) the WebSocket connection to the Proxim app.
## Returns the final ready state — STATE_OPEN on success.
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


# ── Peers ─────────────────────────────────────────────────────────────────────

## Send a full peer update as a dictionary. Sent infrequently (state changes).
## Common keys: gameId (int), isHost (bool).
func update_call_peer(data: Dictionary) -> void:
	_last_peer_data.merge(data, true)
	_web_socket.send_text(JSON.stringify({"type": "updateCallPeer", "data": data}))


## Request the current call peers from Proxim.
## Returns {"error": Error, "peers": Array}:
##   error == OK on success, ERR_TIMEOUT if proxim doesn't respond within 2 s.
##   peers is empty on error.
## Each peer entry includes: uid, displayName, isHost, muted, gain, deafened,
## gainNodeActive, pannerNodeActive, coordinates, gameId, legacyAudio.
func get_call_peers() -> Dictionary:
	_pending_call_peers = null
	_web_socket.send_text(JSON.stringify({"type": "getCallPeers"}))
	var deadline := Time.get_ticks_msec() + 2000
	while _pending_call_peers == null:
		if Time.get_ticks_msec() >= deadline:
			push_error("[ProximPeer] get_call_peers: timed out after 2s — proxim app did not respond")
			_log("get_call_peers: timed out")
			return {"error": ERR_TIMEOUT, "peers": []}
		await get_tree().process_frame
	var result: Array = _pending_call_peers
	_pending_call_peers = null
	return {"error": OK, "peers": result}


## Relay an opaque Dictionary to another game client (by gameId) through
## Proxim. The receiving peer gets it as a `peer_message` signal.
## Use this to build your own game protocol on top of Proxim — WebRTC
## signaling, state sync, chat, etc.
func relay_to(peer_game_id: int, payload: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "relayTo", "to": peer_game_id, "payload": payload
	}))


# ── Gain node ─────────────────────────────────────────────────────────────────

## Wire a relative gain node into the audio graph for peer_game_id.
## Call update_gain_node or hot_gain_node to drive its value.
## initial_gain: starting gain value (default 1.0).
func add_gain_node(peer_game_id: int, initial_gain: float = 1.0) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "addGainNode", "gameId": peer_game_id,
		"data": {"gain": initial_gain}
	}))


## Remove the relative gain node for peer_game_id and reset to unity gain.
func remove_gain_node(peer_game_id: int) -> void:
	_web_socket.send_text(JSON.stringify({"type": "removeGainNode", "gameId": peer_game_id}))


## Infrequent gain update. Use hot_gain_node for per-frame updates.
func update_gain_node(peer_game_id: int, gain: float) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "updateGainNode", "gameId": peer_game_id,
		"data": {"gain": gain}
	}))


## Send a compact 5-byte relative gain update. Call every frame / physics tick.
##
## Packet layout:
##   gameId  uint32 LE  4 bytes — peer gameId
##   gain    uint8      1 byte  — 0–255 mapped to 0.0–1.0
func hot_gain_node(peer_game_id: int, gain: float) -> void:
	_gain_hot_buf.encode_u32(0, peer_game_id)
	_gain_hot_buf[4] = int(clampf(gain, 0.0, 1.0) * 255.0) & 0xFF
	_web_socket.send(_gain_hot_buf)


# ── Panner node ───────────────────────────────────────────────────────────────

## Wire a 3D panner node into the audio graph for peer_game_id.
## `config` holds the non-rampable PannerNode attributes (set once at creation):
##   panningModel ('equalpower' | 'HRTF')
##   distanceModel ('linear' | 'inverse' | 'exponential')
##   refDistance, maxDistance, rolloffFactor
##   coneInnerAngle, coneOuterAngle, coneOuterGain
##
## Position and orientation are controlled by hot_panner_node (every frame).
func add_panner_node(peer_game_id: int, config: Dictionary = {}) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "addPannerNode", "gameId": peer_game_id, "config": config
	}))


## Remove the panner node for peer_game_id.
func remove_panner_node(peer_game_id: int) -> void:
	_web_socket.send_text(JSON.stringify({"type": "removePannerNode", "gameId": peer_game_id}))


## Change a PannerNode's non-rampable attributes (distance model, cone, etc.).
## Spatial updates go through hot_panner_node.
func update_panner_node(peer_game_id: int, config: Dictionary) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "updatePannerNode", "gameId": peer_game_id, "config": config
	}))


## Send a compact 16-byte panner update. Call every frame / physics tick.
##
## Packet layout:
##   gameId        uint32 LE  4 bytes — peer gameId (bytes 0–3)
##   positionX     float16    2 bytes — (bytes 4–5)
##   positionY     float16    2 bytes — (bytes 6–7)
##   positionZ     float16    2 bytes — (bytes 8–9)
##   orientationX  float16    2 bytes — (bytes 10–11)
##   orientationY  float16    2 bytes — (bytes 12–13)
##   orientationZ  float16    2 bytes — (bytes 14–15)
func hot_panner_node(peer_game_id: int, position_x: float, position_y: float, position_z: float,
		orientation_x: float, orientation_y: float, orientation_z: float) -> void:
	_panner_hot_buf.encode_u32(0,  peer_game_id)
	_panner_hot_buf.encode_half(4,  position_x)
	_panner_hot_buf.encode_half(6,  position_y)
	_panner_hot_buf.encode_half(8,  position_z)
	_panner_hot_buf.encode_half(10, orientation_x)
	_panner_hot_buf.encode_half(12, orientation_y)
	_panner_hot_buf.encode_half(14, orientation_z)
	_web_socket.send(_panner_hot_buf)


# ── Listener ──────────────────────────────────────────────────────────────────

## Send a compact 18-byte listener update. Call every frame / physics tick.
## Drives the single global AudioListener on the Proxim audio context.
##
## Packet layout:
##   positionX float16  2 bytes — (bytes 0–1)
##   positionY float16  2 bytes — (bytes 2–3)
##   positionZ float16  2 bytes — (bytes 4–5)
##   forwardX  float16  2 bytes — (bytes 6–7)
##   forwardY  float16  2 bytes — (bytes 8–9)
##   forwardZ  float16  2 bytes — (bytes 10–11)
##   upX       float16  2 bytes — (bytes 12–13)
##   upY       float16  2 bytes — (bytes 14–15)
##   upZ       float16  2 bytes — (bytes 16–17)
func hot_listener_node(position_x: float, position_y: float, position_z: float,
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


# ── Proximity ─────────────────────────────────────────────────────────────────

## Configure the linear ramp applied to hot_panner_node / hot_listener_node
## updates. `frequency` is the ramp duration in seconds (e.g. 0.1).
## Disable interpolation for instant-snap positional updates.
func set_proximity_interpolation(enabled: bool, frequency: float) -> void:
	_web_socket.send_text(JSON.stringify({
		"type": "setProximityInterpolation", "enabled": enabled, "frequency": frequency
	}))


# ── Internal ──────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	_web_socket.poll()
	while _web_socket.get_available_packet_count() > 0:
		var packet := _web_socket.get_packet()
		if not _web_socket.was_string_packet():
			continue
		var msg: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if not msg is Dictionary:
			continue
		match msg.get("type"):
			"callPeers":
				_pending_call_peers = msg.get("peers", [])
			"peerJoined":
				peer_joined.emit(int(msg.get("gameId", 0)))
			"peerLeft":
				peer_left.emit(int(msg.get("gameId", 0)))
			"peerMessage":
				var from_id := int(msg.get("from", 0))
				var payload: Dictionary = msg.get("payload", {}) if msg.get("payload") is Dictionary else {}
				peer_message.emit(from_id, payload)
			"proximConnected":
				_log("proxim_connected — resending peer state")
				if not _last_peer_data.is_empty():
					_web_socket.send_text(JSON.stringify({"type": "updateCallPeer", "data": _last_peer_data}))
				proxim_connected.emit()
			"proximDisconnected":
				_log("proxim_disconnected")
				proxim_disconnected.emit()
