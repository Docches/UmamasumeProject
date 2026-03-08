extends CharacterBody2D

@export var is_bot: bool = false
var last_key: String = ""
var run_speed: float = 0.0

const ACC = 70.0
const FRICTION = 0.92
const MAX_SPEED = 1500.0

func _enter_tree() -> void:
	if has_node("MultiplayerSynchronizer"):
		$MultiplayerSynchronizer.set_multiplayer_authority(get_multiplayer_authority())
	
func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		if not is_bot:
			if Input.is_action_just_pressed("ui_left") and last_key != "left":
				run_speed += ACC
				last_key = "left"  
			elif Input.is_action_just_pressed("ui_right") and last_key != "right":
				run_speed += ACC
				last_key = "right"  
		else:
			run_speed += (ACC*0.4)*randf()
			
		run_speed = clamp(run_speed*FRICTION,0,MAX_SPEED)
		velocity.y = -run_speed
		move_and_slide()
