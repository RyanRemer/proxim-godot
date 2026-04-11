extends StaticBody3D

signal proximity_mode_changed(mode: String)

const MODES := ["off", "gain", "panner"]
var _mode_index: int = 0
var is_animating: bool = false

func _ready() -> void:
	add_to_group("interactable")
	_update_label()

func interact() -> void:
	if is_animating:
		return
	is_animating = true
	_mode_index = (_mode_index + 1) % MODES.size()
	proximity_mode_changed.emit(MODES[_mode_index])
	_update_label()
	var tween = create_tween()
	tween.tween_property($ButtonCap, "position:y", 1.1, 0.08)
	tween.tween_property($ButtonCap, "position:y", 1.3, 0.15)
	tween.tween_callback(func(): is_animating = false)

func _update_label() -> void:
	$HintLabel.text = "[E] %s" % MODES[_mode_index].to_upper()
