extends StaticBody3D

var is_animating: bool = false

func _ready() -> void:
	add_to_group("interactable")

func interact() -> void:
	if is_animating:
		return
	is_animating = true
	var tween = create_tween()
	tween.tween_property($ButtonCap, "position:y", 1.1, 0.08)
	tween.tween_property($ButtonCap, "position:y", 1.3, 0.15)
	tween.tween_callback(func(): is_animating = false)
