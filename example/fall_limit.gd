extends Area3D

func _on_body_entered(body: Node3D) -> void:
	print(body.name)
	if body is Player:
		body.global_position = Vector3(0, 50, 0);
