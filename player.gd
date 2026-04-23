# From https://github.com/rbarongr/GodotFirstPersonController/blob/main/Player/player.gd

class_name Player extends CharacterBody3D

@export_range(1, 35, 1) var speed: float = 10 # m/s
@export_range(10, 400, 1) var acceleration: float = 100 # m/s^2
@export_range(0.1, 3.0, 0.1) var jump_height: float = 2 # m
@export_range(0.1, 3.0, 0.1, "or_greater") var camera_sens: float = 2

var jumping: bool = false
var mouse_captured: bool = false

@export_range(0.05, 0.3, 0.01) var coyote_time: float = 0.3 # seconds
var coyote_timer: float = 0.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var move_dir: Vector2 # Input direction for movement
var look_dir: Vector2 # Input direction for look/aim

var camera_pitch: float = 0.0 # Synced vertical look angle (radians)

var walk_vel: Vector3 # Walking velocity
var grav_vel: Vector3 # Gravity velocity
var jump_vel: Vector3 # Jumping velocity

var interact_target = null

@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	if not is_multiplayer_authority():
		$Camera3D.current = false
		set_physics_process(false)
		set_process_unhandled_input(false)
		return
	capture_mouse()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		look_dir = event.relative * 0.001
		if mouse_captured: _rotate_camera()
	if Input.is_action_just_pressed(&"tab"):
		if mouse_captured:
			release_mouse();
		else:
			capture_mouse();
	if Input.is_action_just_pressed(&"interact") and mouse_captured:
		if interact_target:
			interact_target.interact()

func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed(&"jump"): jumping = true
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		coyote_timer = max(coyote_timer - delta, 0.0)
	velocity = _walk(delta) + _gravity(delta) + _jump(delta)
	move_and_slide()

func _process(_delta: float) -> void:
	$Eyes.rotation.x = camera_pitch * 0.3
	if is_multiplayer_authority():
		_check_interact()

func _check_interact() -> void:
	var space = get_world_3d().direct_space_state
	var cam_pos = camera.global_position
	var cam_forward = -camera.global_transform.basis.z
	var query = PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_forward * 3.0, 0xFFFFFFFF, [get_rid()])
	var result = space.intersect_ray(query)
	if result and result.collider.is_in_group("interactable"):
		interact_target = result.collider
	else:
		interact_target = null

func capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	mouse_captured = true

func release_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	mouse_captured = false

func _rotate_camera(sens_mod: float = 1.0) -> void:
	rotation.y -= look_dir.x * camera_sens * sens_mod
	camera.rotation.x = clamp(camera.rotation.x - look_dir.y * camera_sens * sens_mod, -1.5, 1.5)
	camera_pitch = camera.rotation.x

func _walk(delta: float) -> Vector3:
	move_dir = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var _forward: Vector3 = camera.global_transform.basis * Vector3(move_dir.x, 0, move_dir.y)
	var walk_dir: Vector3 = Vector3(_forward.x, 0, _forward.z).normalized()
	walk_vel = walk_vel.move_toward(walk_dir * speed * move_dir.length(), acceleration * delta)
	return walk_vel

func _gravity(delta: float) -> Vector3:
	grav_vel = Vector3.ZERO if is_on_floor() else grav_vel.move_toward(Vector3(0, velocity.y - gravity, 0), gravity * delta)
	return grav_vel

func _jump(delta: float) -> Vector3:
	if jumping:
		if is_on_floor() or coyote_timer > 0.0:
			jump_vel = Vector3(0, sqrt(4 * jump_height * gravity), 0)
			coyote_timer = 0.0
		jumping = false
		return jump_vel
	jump_vel = Vector3.ZERO if is_on_floor() or is_on_ceiling_only() else jump_vel.move_toward(Vector3.ZERO, gravity * delta)
	return jump_vel
