extends CharacterBody2D

@export var game_manager: Node
var player_index := -1
var is_bot := false

@export var max_strength := 4000.0

@onready var strength_bar = $StrengthBar
@onready var javelin = $Javelin
@export var angle_offset := -80.0

# --- STATE ---
var angle := 45.0
var strength := 0.0
var charging := false
var thrown := false
var finished := false

var velocity_vec := Vector2.ZERO
var gravity := 2000.0

# --------------------------------------------------
# BOT SETUP
# --------------------------------------------------
func set_as_bot():
	is_bot = true

# --------------------------------------------------
# PHYSICS
# --------------------------------------------------
func _physics_process(delta):
	if not thrown:
		if is_bot:
			handle_bot(delta)
		elif is_multiplayer_authority():
			handle_input(delta)

	if thrown and multiplayer.is_server():
		apply_projectile(delta)

# --------------------------------------------------
# INPUT
# --------------------------------------------------
func handle_input(delta):
	if Input.is_action_pressed("ui_up"):
		angle -= 60 * delta
	if Input.is_action_pressed("ui_down"):
		angle += 60 * delta
	
	angle = clamp(angle, 10, 80)
	javelin.rotation = velocity_vec.angle() + deg_to_rad(angle_offset)
	
	if Input.is_action_just_pressed("ui_accept"):
		charging = true
	
	if charging:
		strength += 10000 * delta
		strength = clamp(strength, 0, max_strength)
		strength_bar.value = strength
	
	if Input.is_action_just_released("ui_accept") and charging:
		charging = false
		request_throw()

# --------------------------------------------------
# BOT
# --------------------------------------------------
var bot_timer := 1.5

func handle_bot(delta):
	bot_timer -= delta
	
	if bot_timer <= 0:
		var a = randf_range(30, 70)
		var s = randf_range(max_strength*0.5, max_strength)
		execute_throw(a, s)

# --------------------------------------------------
# THROW FLOW
# --------------------------------------------------
func request_throw():
	if multiplayer.is_server():
		execute_throw(angle, strength)
	else:
		request_throw_rpc.rpc_id(1, angle, strength)

	strength = 0
	strength_bar.value = 0

@rpc("any_peer")
func request_throw_rpc(a, s):
	if multiplayer.is_server():
		execute_throw(a, s)

func execute_throw(a, s):
	angle = a
	strength = s
	throw_javelin()

# --------------------------------------------------
# THROW LOGIC
# --------------------------------------------------
func throw_javelin():
	thrown = true
	
	var rad = deg_to_rad(90 - angle)
	velocity_vec.x = cos(rad) * strength
	velocity_vec.y = -sin(rad) * strength
	
	javelin.rotation = velocity_vec.angle()

# --------------------------------------------------
# PROJECTILE
# --------------------------------------------------
func apply_projectile(delta):
	if finished:
		return
	
	velocity_vec.y += gravity * delta
	javelin.position += velocity_vec * delta
	
	if velocity_vec.length() > 0:
		javelin.rotation = velocity_vec.angle() + deg_to_rad(angle_offset)
	
	if javelin.position.y >= 50:
		javelin.position.y = 50
		finish_throw()

# --------------------------------------------------
# FINE LANCIO
# --------------------------------------------------
func finish_throw():
	if finished:
		return
	
	finished = true
	velocity_vec = Vector2.ZERO
	
	var distance = javelin.position.x - position.x
	
	if multiplayer.is_server():
		game_manager.report_throw(player_index, distance)
	else:
		game_manager.report_throw.rpc_id(1, player_index, distance) 
