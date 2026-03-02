extends CharacterBody2D

const SPEED = 300

func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())
	
func _process(delta: float) -> void:
	if(is_multiplayer_authority()):
		velocity = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")*SPEED
		move_and_slide()
