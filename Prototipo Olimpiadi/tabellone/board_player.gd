class_name BoardPlayer
extends Node2D

var current_space_index: int = 0
var has_last_spurt: bool = false # Memorizza il potenziamento Ferro di Cavallo

signal step_taken(space_index)
signal movement_finished

func move_spaces(spaces_node: Node2D, spaces_to_move: int) -> void:
	var space_children: Array[Node] = spaces_node.get_children()
	var max_spaces: int = space_children.size() - 1

	for i in range(spaces_to_move):
		if current_space_index >= max_spaces:
			current_space_index = 0 # Fa il giro del tabellone se arriva alla fine!
			
		current_space_index += 1
		var target_position: Vector2 = space_children[current_space_index].global_position
		
		# Animazione di salto ad ogni passo
		var tween: Tween = create_tween().set_parallel(true)
		tween.tween_property(self, "global_position:x", target_position.x, 0.25).set_trans(Tween.TRANS_LINEAR)
		tween.tween_property(self, "global_position:y", target_position.y, 0.25).set_trans(Tween.TRANS_LINEAR)
		
		var jump_tween = create_tween()
		jump_tween.tween_property(self, "scale", Vector2(1.2, 1.2), 0.12)
		jump_tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.13)
		
		await tween.finished
		
		# Avvisa il tabellone che ha fatto un passo (utile per Podio/Negozio)
		step_taken.emit(current_space_index)
		await get_tree().create_timer(0.05).timeout # Piccola pausa tra i passi

	movement_finished.emit()
