extends CharacterBody3D


# Settings
@export var look_sensitivity : float = 0.006

# Jumping
@export var jump_velocity := 5.0
@export var auto_bhop := true

# Ground movement
@export var walk_speed := 10.0
@export var sprint_speed := 15.0
@export var ground_accel := 15.0
@export var ground_decel := 10.0
@export var ground_friction := 10.0

# Air movement
@export var air_cap := 2.0
@export var air_accel := 800.0
@export var air_move_speed := 500.0

@export var extraJumps := 1

var wish_dir := Vector3.ZERO # Store the desired movement direction

# No Clip
var cam_aligned_wish_dir := Vector3.ZERO
var noclip_speed_mult := 2.0
var noclip := false


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
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90)) # This makes sure the player cannot break their neck


# This function is called every frame. Delta is time since last frame.
func _process(delta: float) -> void:
	pass


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


# Also for surfing
func is_surface_too_steep(normal : Vector3) -> bool:
	# This calculates the maximum slope angle dot product based on the floor max angle
	var max_slope_ang_dot = Vector3(0,1,0).rotated(Vector3(1,0,0), self.floor_max_angle).dot(Vector3(0,1,0))
	if normal.dot(Vector3(0,1,0)) < max_slope_ang_dot:
		return true
	return false


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


# hqandles physics every frame
func _physics_process(delta: float) -> void:
	var input_dir = Input.get_vector("left", "right", "up", "down").normalized()

	wish_dir = self.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	cam_aligned_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)

	if not _handle_noclip(delta):
		if is_on_floor():
			if Input.is_action_just_pressed("jump") or (auto_bhop and Input.is_action_pressed("jump")):
				self.velocity.y = jump_velocity
			_handle_ground_physics(delta)
		else:
			_handle_air_physics(delta)

		move_and_slide()

# https://www.youtube.com/playlist?list=PLbuK0gG93AsHID1DDD1nt4YHcdOmJvWW1
