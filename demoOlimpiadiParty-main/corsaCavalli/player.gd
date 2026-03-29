extends CharacterBody2D

@export var is_bot: bool = false

var run_speed: float = 0.0
var max_speed: float = 0.0
var race_manager: Node = null
var finished: bool = false
var stopped: bool = false
var index: int = 0  # track index


var change_speed_timer: float = 0.0
const MIN_RANDOM_SPEED: float = 40.0
const MAX_RANDOM_SPEED: float = 250.0

func _ready():
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(get_multiplayer_authority())
	change_speed_timer = 0.0

func _physics_process(delta: float):
	if not multiplayer.is_server():
		return

	if stopped:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	change_speed_timer -= delta
	if change_speed_timer <= 0:
		max_speed = randf_range(MIN_RANDOM_SPEED, MAX_RANDOM_SPEED)
		change_speed_timer = randf_range(0.5, 1.5)
		
	# Constant acceleration toward max_speed
	run_speed = lerpf(run_speed, max_speed, 2.5*delta)

	velocity = Vector2(run_speed, 0)
	move_and_slide()

	check_finish()

func check_finish():
	var finish_x = 1000
	if position.x >= finish_x and not finished:
		finished = true
		if race_manager:
			# Pass the player ID, not index
			race_manager.report_finish.rpc(int(name))

@rpc("call_local","authority","reliable")
func stop_horse():
	run_speed = 0
	max_speed = 0
	velocity = Vector2.ZERO
	stopped = true
