extends CharacterBody3D


# Settings
@export var look_sensitivity : float = 0.006

# Jumping
@export var jump_velocity := 5.0
@export var auto_bhop := true

# Ground movement
@export var walk_speed := 8.0
@export var sprint_speed := 20.0
@export var ground_accel := 15.0
@export var ground_decel := 10.0
@export var ground_friction := 10.0

# Dashing
@export var dashes := 2
var dashesRemaining := dashes
@export var dashLength := 200.0
@export var dashCooldown := 1.0

# Air movement
@export var air_cap := 2.0
@export var air_accel := 800.0
@export var air_move_speed := 500.0

@export var extraJumps := 2
var jumpsRemaining := extraJumps

var wish_dir := Vector3.ZERO # Store the desired movement direction

# No Clip
var cam_aligned_wish_dir := Vector3.ZERO
var noclip_speed_mult := 2.5
var noclip := false

# smooth stairs
const MAX_STEP_HEIGHT = 0.5
var _snapped_to_stairs_last_frame := false
var _last_frame_was_on_floor := -INF


# Get if the player is walking or running
func get_move_speed() -> float:
	return sprint_speed if Input.is_action_pressed("sprint") else walk_speed


# setup
func _ready():
	# Hide player model from own view
	for child in %WorldModel.find_children("*", "VisualInstance3d"): 
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)


# handles unhnandled inputs such as mouse movement
func _unhandled_input(event: InputEvent) -> void:
	# If the player clicks on the game, begin capturing inputs
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# If the user clicks escape, stop capturing inputs
	elif event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# Translate mouse movement into camera rotation
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotate_y(-event.relative.x * look_sensitivity)
			%Camera3D.rotate_x(-event.relative.y * look_sensitivity)
			# This makes sure the player cannot break their neck
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90))


# This function is called every frame. Delta is time since last frame.
func _process(delta: float) -> void:
	pass


func _snap_down_to_stairs_check() -> void:
	var did_snap := false
	var floor_below : bool = %StairsBelowRayCast3D.is_colliding() and not is_surface_too_steep(%StairsBelowRayCast3D.get_collision_normal())
	var was_on_floor_last_frame = Engine.get_physics_frames() == _last_frame_was_on_floor

	if not is_on_floor() and velocity.y <= 0 and (was_on_floor_last_frame or _snapped_to_stairs_last_frame) and floor_below:
		var body_test_result = PhysicsTestMotionResult3D.new()
		if _run_body_test_motion(self.global_transform, Vector3(0,-MAX_STEP_HEIGHT,0), body_test_result):
			var translate_y = body_test_result.get_travel().y
			self.position.y += translate_y
			apply_floor_snap()
			did_snap = true
	_snapped_to_stairs_last_frame = did_snap


func _snap_up_to_stairs_check(delta) -> bool:
	if not is_on_floor() and not _snapped_to_stairs_last_frame: return false
	# Don't snap stairs if trying to jump, also no need to check for stairs ahead if not moving
	if self.velocity.y > 0 or (self.velocity * Vector3(1,0,1)).length() == 0: return false
	var expected_move_motion = self.velocity * Vector3(1,0,1) * delta
	var step_pos_with_clearance = self.global_transform.translated(expected_move_motion + Vector3(0, MAX_STEP_HEIGHT * 2, 0))
	# Run a body_test_motion slightly above the pos we expect to move to, towards the floor.
	#  We give some clearance above to ensure there's ample room for the player.
	#  If it hits a step <= MAX_STEP_HEIGHT, we can teleport the player on top of the step
	#  along with their intended motion forward.
	var down_check_result = KinematicCollision3D.new()
	if (self.test_move(step_pos_with_clearance, Vector3(0,-MAX_STEP_HEIGHT*2,0), down_check_result)
	and (down_check_result.get_collider().is_class("StaticBody3D") or down_check_result.get_collider().is_class("CSGShape3D"))):
		var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y
		# Note I put the step_height <= 0.01 in just because I noticed it prevented some physics glitchiness
		# 0.02 was found with trial and error. Too much and sometimes get stuck on a stair. Too little and can jitter if running into a ceiling.
		# The normal character controller (both jolt & default) seems to be able to handled steps up of 0.1 anyway
		if step_height > MAX_STEP_HEIGHT or step_height <= 0.01 or (down_check_result.get_position() - self.global_position).y > MAX_STEP_HEIGHT: return false
		%StairsAheadRayCast3D.global_position = down_check_result.get_position() + Vector3(0,MAX_STEP_HEIGHT,0) + expected_move_motion.normalized() * 0.1
		%StairsAheadRayCast3D.force_raycast_update()
		if %StairsAheadRayCast3D.is_colliding() and not is_surface_too_steep(%StairsAheadRayCast3D.get_collision_normal()):
			self.global_position = step_pos_with_clearance.origin + down_check_result.get_travel()
			apply_floor_snap()
			_snapped_to_stairs_last_frame = true
			return true
	return false


# Its in the name
func _handle_noclip(delta) -> bool:
	# Toggle noclip
	if Input.is_action_just_pressed("_noclip") and OS.has_feature("debug"):
		noclip = !noclip

	# set collision to state of noclip
	$CollisionShape3D.disabled = noclip

	if not noclip: return false

	var speed = get_move_speed() * noclip_speed_mult
	
	self.velocity = cam_aligned_wish_dir * speed
	global_position += self.velocity * delta

	return true

# For surfing
# Originally meant to prevent sticking to walls when moving against them
func clip_velocity (normal : Vector3, overbounce : float, delta : float) -> void:
	# Find the component of velocity that is directed into the surface
	var backoff := self.velocity.dot(normal) * overbounce

	# If the plater is moving away from the surface, no need to stop them
	if backoff >= 0: return

	# Multiply the normal by the backoff amount to get the change in velocity
	var change := normal * backoff
	# Direct it away
	self.velocity -= change

	# Prevent tiny velocity adjustments that can cause jitter
	# Basically smooths out the velocity change
	var adjust := self.velocity.dot(normal)
	if adjust < 0.0:
		self.velocity -= normal * adjust


# Also for surfing, semantically named
func is_surface_too_steep(normal : Vector3) -> bool:
	# This calculates the maximum slope angle dot product based on the floor max angle
	return normal.angle_to(Vector3.UP) > self.floor_max_angle


# For smooth movement on stairs 
# Works by using a builtin function to see if future movement in a direction will collide
# and returns true if it will
func _run_body_test_motion(from : Transform3D, motion : Vector3, result = null) -> bool:
	if not result: result = PhysicsTestMotionResult3D.new()
	var params = PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	return PhysicsServer3D.body_test_motion(self.get_rid(), params, result)


# Its in the name
func _handle_air_physics(delta) -> void:
	# Gets the global gravity and applies it to the player
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	
	# Get current speed in the desired direction
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)

	# Cap the speed in the desired direction
	var capped_speed = min((air_move_speed * wish_dir).length(), air_cap)
	
	# Accelerate towards the desired direction until capped
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = air_accel * air_move_speed * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += wish_dir * accel_speed

	# Surfing
	if is_on_wall():
		if is_surface_too_steep(get_wall_normal()):
			# If the surface is too steep, we switch to floating mode to make surfing smoother
			self.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		else:
			self.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		clip_velocity(get_wall_normal(), 1.0, delta)

	# Air jumps
	if jumpsRemaining > 0 and Input.is_action_just_pressed("jump"):
		self.velocity.y = jump_velocity
		jumpsRemaining -= 1


# self apparent
func _handle_ground_physics(delta) -> void:
	# Similiar to air physics
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)
	var add_speed_till_cap = get_move_speed() - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = ground_accel * delta * get_move_speed()
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += wish_dir * accel_speed
	
	# gets rid of residual velocity when no input is given
	var control = max(self.velocity.length(), ground_decel)
	# calculates the amount of speed to drop due to friction
	var drop = control * ground_friction * delta
	var new_speed = max(self.velocity.length() - drop, 0.0)
	# If the player is moving, scale the velocity to the new speed
	if self.velocity.length() > 0:
		new_speed /= self.velocity.length()
	self.velocity *= new_speed

	jumpsRemaining = extraJumps # Reset jumps on landing


# hqandles physics every frame
func _physics_process(delta: float) -> void:
	if is_on_floor(): _last_frame_was_on_floor = Engine.get_physics_frames()

	var input_dir = Input.get_vector("left", "right", "up", "down").normalized()

	wish_dir = self.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	cam_aligned_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)

	# Dashing
	if Input.is_action_just_pressed("dash") and dashesRemaining > 0:
		dashesRemaining -= 1
		var dash_dir = wish_dir
		dash_dir.y = 0
		dash_dir = dash_dir.normalized()
		var stored_velocity = velocity
		velocity = dash_dir * dashLength # Temporary high velocity for one frame
		move_and_slide()
		velocity = stored_velocity  # Restore original velocity
		
	
	if is_on_floor():
		dashesRemaining = dashes

	if not _handle_noclip(delta):
		if is_on_floor() or _snapped_to_stairs_last_frame:
			if Input.is_action_just_pressed("jump") or (auto_bhop and Input.is_action_pressed("jump")):
				self.velocity.y = jump_velocity
			_handle_ground_physics(delta)
		else:
			_handle_air_physics(delta)

		if not _snap_up_to_stairs_check(delta):

			move_and_slide()
			_snap_down_to_stairs_check()

# https://www.youtube.com/playlist?list=PLbuK0gG93AsHID1DDD1nt4YHcdOmJvWW1
#
# Bookmark: https://youtu.be/Tb-R3l0SQdc?list=PLbuK0gG93AsHID1DDD1nt4YHcdOmJvWW1&t=963
