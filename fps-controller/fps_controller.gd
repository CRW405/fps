extends CharacterBody3D
class_name PlayerController

## TODO:
# Leaning

@export_group("Look")
@export var mouse_sensitivity := 0.006

@export_group("Jump")
@export var jump_velocity := 5.0
@export var auto_bunny_hop := true
@export var extra_jumps := 0
## Jump presses are remembered for this long so a press on the exact frame of
## wall/ledge contact (which is only reported one frame later) still counts
## towards a wall bounce or ledge grab.
@export var jump_buffer_window := 0.1

@export_group("Ground Movement")
@export var walk_speed := 8.0
@export var sprint_speed := 20.0
@export var ground_acceleration := 15.0
@export var ground_deceleration := 10.0
@export var ground_friction := 10.0

@export_group("Dash")
@export var enable_dash := true
@export var dash_count := 2
@export var dash_speed := 200.0
@export var dash_cooldown := 1.0

@export_group("Crouch & Slide")
@export var enable_crouch_slide := true
@export var crouch_height := 1.2
@export var crouch_speed := 4.0
@export var crouch_transition_speed := 12.0
@export var slide_enter_speed := 12.0
@export var slide_exit_speed := 7.0
@export var slide_speed := 24.0
@export var slide_boost_acceleration := 35.0
@export var slide_friction := 2.0

@export_group("Mantle & Ledge Hang")
@export var enable_mantle := true
@export var mantle_height := 2.0
@export var hang_launch_speed := 12.0
## Baseline vertical launch speed - used as-is when the ledge is shallow
## enough to clear with it. Taller ledges automatically get boosted past this
## (see hang_climb_clearance) so climbing up never falls just short.
@export var hang_launch_velocity := 8.0
## Extra height, on top of the ledge surface, the climb boost aims to clear -
## guarantees the player actually lands on the platform instead of just
## barely reaching the edge and sliding back off.
@export var hang_climb_clearance := 0.5
## Jump is ignored for this long after grabbing a ledge, so the same press (or
## an early follow-up press) that grabbed it can't immediately launch you back off.
@export var hang_launch_delay := 0.2

@export_group("Air Movement")
@export var air_speed_cap := 2.0
@export var air_acceleration := 800.0
@export var air_move_speed := 500.0

@export_group("Wall Bounce")
@export var enable_wall_bounce := true
## Absolute floor on the outward kick speed, regardless of angle - guarantees
## a bounce even when barely moving.
@export var wall_bounce_min_force := 1.0
## The angle (measured from the wall surface) a bounce comes out at when
## running parallel to the wall with no speed driving into it. 0° would slide
## along the wall with no kick; 90° would launch straight out from it.
@export_range(0.0, 89.0, 0.5) var wall_bounce_parallel_angle := 35.0
## Multiplier applied to the speed you were driving into the wall with, added
## on top of the angle/force floor - the harder you hit, the harder the kick.
@export var wall_bounce_restitution := 1.01
## Vertical speed granted on every successful bounce, on top of any upward speed already held.
@export var wall_bounce_vertical_boost := 5.0
## Bouncing off a wall within this many degrees of the last wall bounced off is
## rejected as "the same wall" so mashing jump can't climb a single flat wall.
## Two parallel walls face opposite directions and are always seen as different.
@export var wall_bounce_same_wall_angle := 45.0

@export_group("Noclip")
@export var enable_noclip := true
@export var noclip_speed_multiplier := 2.5

const MAX_STEP_HEIGHT := 0.5
const HANG_CLEARANCE := 0.4

var wish_dir := Vector3.ZERO
var cam_aligned_wish_dir := Vector3.ZERO
var noclip := false

var dashes_remaining := 0
var jumps_remaining := 0

var snapped_to_stairs_last_frame := false
var last_floor_physics_frame := -INF

var crouch_amount := 0.0
var sliding := false
var standing_capsule_shape : CapsuleShape3D
var standing_height := 0.0
var standing_center_y := 0.0
var crouch_center_y := 0.0
var crouch_eye_offset := 0.0

var hanging := false
var hang_surface_y := 0.0
var hang_timer := 0.0

var velocity_before_last_move := Vector3.ZERO
var jump_buffer_time := 0.0
var wall_bounce_chain_normal := Vector3.ZERO
var wall_bounce_chain_active := false


func _ready() -> void:
	dashes_remaining = dash_count
	jumps_remaining = extra_jumps

	standing_capsule_shape = ($CollisionShape3D.shape as CapsuleShape3D).duplicate()
	standing_height = standing_capsule_shape.height
	standing_center_y = $CollisionShape3D.position.y
	crouch_center_y = standing_center_y - (standing_height - crouch_height) * 0.5
	var head_y : float = %Camera3D.global_position.y
	crouch_eye_offset = (crouch_center_y + crouch_height * 0.5) - head_y - 0.15

	for child in %WorldModel.find_children("*", "VisualInstance3d"):
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		%Camera3D.rotate_x(-event.relative.y * mouse_sensitivity)
		%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90))


func _physics_process(delta: float) -> void:
	if is_on_floor():
		last_floor_physics_frame = Engine.get_physics_frames()

	_update_jump_buffer(delta)

	var input_dir := Input.get_vector("left", "right", "up", "down").normalized()
	wish_dir = global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	cam_aligned_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)

	_update_crouch_slide(delta)
	_update_dash()

	if is_on_floor():
		dashes_remaining = dash_count

	if _handle_noclip(delta):
		return

	if hanging:
		_handle_hanging(delta)
		return

	if _try_grab():
		return

	if is_on_floor() or snapped_to_stairs_last_frame:
		if Input.is_action_just_pressed("jump") or (auto_bunny_hop and Input.is_action_pressed("jump")):
			velocity.y = jump_velocity
		_handle_ground_physics(delta)
	else:
		_handle_air_physics(delta)

	if not _snap_up_to_stairs_check(delta):
		velocity_before_last_move = velocity
		move_and_slide()
		_snap_down_to_stairs_check()


func get_move_speed() -> float:
	if sliding: return slide_speed
	if crouch_amount > 0.5: return crouch_speed
	return sprint_speed if Input.is_action_pressed("sprint") else walk_speed


func get_movement_state_name() -> String:
	if noclip: return "Noclip"
	if hanging: return "Hanging"
	if sliding: return "Sliding"
	if crouch_amount > 0.5: return "Crouching"
	if not is_on_floor(): return "Airborne"
	return "Sprinting" if Input.is_action_pressed("sprint") else "Walking"


func get_debug_state() -> Dictionary:
	return {
		"movement_state": get_movement_state_name(),
		"position": global_position,
		"velocity": velocity,
		"horizontal_speed": Vector3(velocity.x, 0, velocity.z).length(),
		"is_on_floor": is_on_floor(),
		"is_on_wall": is_on_wall(),
		"wall_bounce_chain_active": wall_bounce_chain_active,
		"motion_mode": "Floating" if motion_mode == CharacterBody3D.MOTION_MODE_FLOATING else "Grounded",
		"noclip": noclip,
		"hanging": hanging,
		"sliding": sliding,
		"crouch_amount": crouch_amount,
		"dashes_remaining": dashes_remaining,
		"dash_count": dash_count,
		"jumps_remaining": jumps_remaining,
		"extra_jumps": extra_jumps,
		"snapped_to_stairs": snapped_to_stairs_last_frame,
	}


func _update_jump_buffer(delta: float) -> void:
	if Input.is_action_just_pressed("jump"):
		jump_buffer_time = jump_buffer_window
	else:
		jump_buffer_time = max(jump_buffer_time - delta, 0.0)


func _update_dash() -> void:
	if not enable_dash or hanging: return
	if not Input.is_action_just_pressed("dash") or dashes_remaining <= 0: return

	dashes_remaining -= 1
	var dash_dir := wish_dir
	dash_dir.y = 0
	dash_dir = dash_dir.normalized()

	var original_velocity := velocity
	velocity = dash_dir * dash_speed
	move_and_slide()
	velocity = original_velocity


func _update_crouch_slide(delta: float) -> void:
	if not enable_crouch_slide:
		sliding = false
		return

	var crouch_pressed := Input.is_action_pressed("crouch")
	var horizontal_speed := Vector3(velocity.x, 0, velocity.z).length()

	if not noclip and crouch_pressed:
		if not sliding and is_on_floor() and horizontal_speed >= slide_enter_speed:
			sliding = true
	else:
		sliding = false
	if sliding and is_on_floor() and horizontal_speed < slide_exit_speed:
		sliding = false

	if crouch_pressed or sliding:
		crouch_amount = min(crouch_amount + crouch_transition_speed * delta, 1.0)
	elif crouch_amount > 0.0 and _has_headroom():
		crouch_amount = max(crouch_amount - crouch_transition_speed * delta, 0.0)

	var shape := $CollisionShape3D.shape as CapsuleShape3D
	shape.height = lerp(standing_height, crouch_height, crouch_amount)
	$CollisionShape3D.position.y = lerp(standing_center_y, crouch_center_y, crouch_amount)
	%Camera3D.position.y = lerp(0.0, crouch_eye_offset, crouch_amount)


func _has_headroom() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = standing_capsule_shape
	query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0, standing_center_y, 0))
	query.collision_mask = collision_mask
	query.exclude = [self]
	return get_world_3d().direct_space_state.intersect_shape(query, 4).is_empty()


func _try_grab() -> bool:
	if not enable_mantle: return false
	if is_on_floor() or snapped_to_stairs_last_frame: return false
	if jump_buffer_time <= 0.0: return false

	var surface_y := _find_ledge_top()
	if surface_y == -INF: return false

	var climb : float = surface_y - (global_position.y - _feet_offset())
	if climb <= MAX_STEP_HEIGHT + 0.05: return false

	hang_surface_y = surface_y
	hanging = true
	hang_timer = 0.0
	snapped_to_stairs_last_frame = false
	global_position.y = _hang_position_y()
	velocity = Vector3.ZERO
	jump_buffer_time = 0.0
	return true


func _find_ledge_top() -> float:
	if not %MantleRayCast3D.is_colliding(): return -INF

	var hit : Vector3 = %MantleRayCast3D.get_collision_point()
	var forward : Vector3 = %MantleRayCast3D.global_transform.basis * Vector3(0.0, 0.55, -0.55)
	forward.y = 0.0
	if forward.length() < 0.001: return -INF
	forward = forward.normalized()

	var probe : Vector3 = hit + forward * 0.2 + Vector3.UP * 0.4
	var params := PhysicsRayQueryParameters3D.create(probe, probe + Vector3.DOWN * mantle_height)
	var result := get_world_3d().direct_space_state.intersect_ray(params)
	if result.is_empty(): return -INF
	if is_surface_too_steep(result.normal): return -INF
	return result.position.y


func _handle_hanging(delta: float) -> void:
	velocity = Vector3.ZERO
	hang_timer += delta

	if hang_timer >= hang_launch_delay and Input.is_action_just_pressed("jump"):
		_launch_from_hang()
	elif Input.is_action_just_pressed("crouch"):
		hanging = false
	else:
		global_position.y = _hang_position_y()


func _launch_from_hang() -> void:
	hanging = false
	var forward : Vector3 = -%Camera3D.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	velocity = forward * hang_launch_speed
	velocity.y = _hang_climb_velocity()


func _hang_climb_velocity() -> float:
	var needed_rise := hang_surface_y - (global_position.y + _feet_offset()) + hang_climb_clearance
	var gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var velocity_to_clear : float = sqrt(max(2.0 * gravity * needed_rise, 0.0))
	return max(hang_launch_velocity, velocity_to_clear)


func _hang_position_y() -> float:
	var shape := $CollisionShape3D.shape as CapsuleShape3D
	return hang_surface_y - HANG_CLEARANCE - _feet_offset() - shape.height


func _feet_offset() -> float:
	var shape := $CollisionShape3D.shape as CapsuleShape3D
	return $CollisionShape3D.position.y - shape.height * 0.5


func _snap_down_to_stairs_check() -> void:
	var floor_below : bool = %StairsBelowRayCast3D.is_colliding() and not is_surface_too_steep(%StairsBelowRayCast3D.get_collision_normal())
	var was_on_floor_last_frame := Engine.get_physics_frames() == last_floor_physics_frame

	var snapped := false
	if not is_on_floor() and velocity.y <= 0 and (was_on_floor_last_frame or snapped_to_stairs_last_frame) and floor_below:
		var result := PhysicsTestMotionResult3D.new()
		if _run_body_test_motion(global_transform, Vector3(0, -MAX_STEP_HEIGHT, 0), result):
			position.y += result.get_travel().y
			apply_floor_snap()
			snapped = true
	snapped_to_stairs_last_frame = snapped


func _snap_up_to_stairs_check(delta: float) -> bool:
	if not is_on_floor() and not snapped_to_stairs_last_frame: return false
	if velocity.y > 0 or (velocity * Vector3(1, 0, 1)).length() == 0: return false

	var expected_motion := velocity * Vector3(1, 0, 1) * delta
	var step_check_from := global_transform.translated(expected_motion + Vector3(0, MAX_STEP_HEIGHT * 2, 0))

	var down_check := KinematicCollision3D.new()
	if not test_move(step_check_from, Vector3(0, -MAX_STEP_HEIGHT * 2, 0), down_check): return false
	if not (down_check.get_collider().is_class("StaticBody3D") or down_check.get_collider().is_class("CSGShape3D")): return false

	var step_height := ((step_check_from.origin + down_check.get_travel()) - global_position).y
	if step_height > MAX_STEP_HEIGHT or step_height <= 0.01 or (down_check.get_position() - global_position).y > MAX_STEP_HEIGHT: return false

	%StairsAheadRayCast3D.global_position = down_check.get_position() + Vector3(0, MAX_STEP_HEIGHT, 0) + expected_motion.normalized() * 0.1
	%StairsAheadRayCast3D.force_raycast_update()
	if not %StairsAheadRayCast3D.is_colliding() or is_surface_too_steep(%StairsAheadRayCast3D.get_collision_normal()): return false

	global_position = step_check_from.origin + down_check.get_travel()
	apply_floor_snap()
	snapped_to_stairs_last_frame = true
	return true


func _handle_noclip(delta: float) -> bool:
	if enable_noclip and Input.is_action_just_pressed("_noclip") and OS.has_feature("debug"):
		noclip = !noclip

	$CollisionShape3D.disabled = noclip
	if not noclip: return false

	var speed := get_move_speed() * noclip_speed_multiplier
	velocity = cam_aligned_wish_dir * speed
	global_position += velocity * delta
	return true


func clip_velocity(normal: Vector3, overbounce: float, delta: float) -> void:
	var backoff := velocity.dot(normal) * overbounce
	if backoff >= 0: return

	velocity -= normal * backoff

	var adjust := velocity.dot(normal)
	if adjust < 0.0:
		velocity -= normal * adjust


func is_surface_too_steep(normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) > floor_max_angle


func _run_body_test_motion(from: Transform3D, motion: Vector3, result = null) -> bool:
	if not result: result = PhysicsTestMotionResult3D.new()
	var params := PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	return PhysicsServer3D.body_test_motion(get_rid(), params, result)


func _handle_air_physics(delta: float) -> void:
	velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta

	var speed_in_wish_dir := velocity.dot(wish_dir)
	var capped_speed : float = min((air_move_speed * wish_dir).length(), air_speed_cap)
	var speed_to_add := capped_speed - speed_in_wish_dir
	if speed_to_add > 0:
		var acceleration : float = min(air_acceleration * air_move_speed * delta, speed_to_add)
		velocity += wish_dir * acceleration

	if is_on_wall():
		var wall_normal := get_wall_normal()
		motion_mode = CharacterBody3D.MOTION_MODE_FLOATING if is_surface_too_steep(wall_normal) else CharacterBody3D.MOTION_MODE_GROUNDED
		if enable_wall_bounce and _try_wall_bounce(wall_normal):
			return
		clip_velocity(wall_normal, 1.0, delta)

	if jumps_remaining > 0 and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
		jumps_remaining -= 1


func _try_wall_bounce(wall_normal: Vector3) -> bool:
	if jump_buffer_time <= 0.0: return false
	if wall_bounce_chain_active and wall_normal.angle_to(wall_bounce_chain_normal) < deg_to_rad(wall_bounce_same_wall_angle):
		return false

	var flat_normal := Vector3(wall_normal.x, 0, wall_normal.z)
	if flat_normal.length() < 0.001: return false
	flat_normal = flat_normal.normalized()

	# Keep the speed the player had running along the wall, and kick them away
	# from it - this way even a graze taken almost parallel to the wall still
	# bounces you off it, like kicking off a surface, instead of requiring
	# real speed driving into the wall. The parallel case exits at
	# wall_bounce_parallel_angle off the wall surface; a direct hit instead
	# scales the kick with how hard the player was driving into the wall.
	var incoming_horizontal := Vector3(velocity_before_last_move.x, 0, velocity_before_last_move.z)
	var tangential := incoming_horizontal - incoming_horizontal.dot(flat_normal) * flat_normal
	var approach_speed := -incoming_horizontal.dot(flat_normal)
	var parallel_kick := tangential.length() * tan(deg_to_rad(wall_bounce_parallel_angle))
	var outward_speed : float = max(wall_bounce_min_force, parallel_kick, approach_speed * wall_bounce_restitution)

	velocity = tangential + flat_normal * outward_speed
	velocity.y = max(velocity_before_last_move.y, 0.0) + wall_bounce_vertical_boost

	wall_bounce_chain_normal = wall_normal
	wall_bounce_chain_active = true
	jump_buffer_time = 0.0
	return true


func _handle_ground_physics(delta: float) -> void:
	if sliding:
		var horizontal := Vector3(velocity.x, 0, velocity.z)
		if horizontal.length() < slide_speed:
			velocity += wish_dir * slide_boost_acceleration * delta
	else:
		var speed_in_wish_dir := velocity.dot(wish_dir)
		var speed_to_add := get_move_speed() - speed_in_wish_dir
		if speed_to_add > 0:
			var acceleration : float = min(ground_acceleration * delta * get_move_speed(), speed_to_add)
			velocity += wish_dir * acceleration

	var friction := slide_friction if sliding else ground_friction
	var control : float = max(velocity.length(), ground_deceleration)
	var drop := control * friction * delta
	var new_speed : float = max(velocity.length() - drop, 0.0)
	if velocity.length() > 0:
		velocity *= new_speed / velocity.length()

	jumps_remaining = extra_jumps
	wall_bounce_chain_active = false
