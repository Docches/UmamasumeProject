extends CharacterBody2D

@export var game_manager: Node
var player_index := -1
var is_bot := false

# --- FOUL LINE ---
var foul_line_x := 0.0
var is_foul := false

# --- MOVIMENTO ---
var speed := 0.0
var max_speed := 600.0
var acceleration := 1200.0

# --- SALTO ---
var jump_force := -900.0
var gravity := 2000.0
var has_jumped := false
var finished := false

# --- CHARGE ---
var charging := false
var charge := 0.0

# --- DISTANZA ---
var start_x := 0.0

# --- BOT ---
var bot_timer := 1.5

func set_as_bot():
	is_bot = true

func _ready():
	start_x = position.x

# --------------------------------------------------
# PHYSICS
# --------------------------------------------------
func _physics_process(delta):
	if finished:
		return
	
	if is_bot:
		handle_bot(delta)
	elif is_multiplayer_authority():
		handle_input(delta)
	
	# Movimento automatico
	if charging:
		speed += acceleration * delta
		speed = clamp(speed, 0, max_speed)
	
	velocity.x = speed
	
	# Gravità
	if not is_on_floor():
		velocity.y += gravity * delta
	
	move_and_slide()
	
	# Atterraggio
	if has_jumped and is_on_floor():
		finish_jump()

# --------------------------------------------------
# INPUT
# --------------------------------------------------
func handle_input(delta):
	if Input.is_action_just_pressed("ui_accept"):
		charging = true
	
	if Input.is_action_just_released("ui_accept") and not has_jumped:
		if charging:
			jump()

# --------------------------------------------------
# BOT
# --------------------------------------------------
func handle_bot(delta):
	bot_timer -= delta
	
	if bot_timer <= 0 and not has_jumped:
		charging = true
	
	if charging and speed > max_speed * randf_range(0.6, 0.9):
		jump()

# --------------------------------------------------
# SALTO
# --------------------------------------------------
func jump():
	# 🚨 CONTROLLO FALLO
	if position.x > foul_line_x:
		is_foul = true
		print("FALLO!")
	
	has_jumped = true
	charging = false
	
	velocity.y = jump_force
	
	if multiplayer.is_server():
		execute_jump()
	else:
		request_jump.rpc_id(1)

@rpc("any_peer")
func request_jump():
	if multiplayer.is_server():
		execute_jump()

func execute_jump():
	has_jumped = true
	charging = false
	velocity.y = jump_force

# --------------------------------------------------
# PROJECTILE
# --------------------------------------------------
func apply_projectile(delta):
	if finished:
		return
	
	velocity.y += gravity * delta
	move_and_slide()

# --------------------------------------------------
# FINE SALTO
# --------------------------------------------------
func finish_jump():
	if finished:
		return
	
	finished = true
	speed = 0
	
	var distance := 0.0
	
	if is_foul:
		print("Salto nullo (fallo)")
		distance = 0
	else:
		distance = position.x - start_x
	
	print("Distanza salto:", distance)
	
	if multiplayer.is_server():
		game_manager.report_result(player_index, distance)
	else:
		game_manager.report_result.rpc_id(1, player_index, distance)
