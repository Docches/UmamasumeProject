class_name BoardPlayer
extends Node2D

var current_space_index: int = 0

signal movement_finished

func move_spaces(spaces_node: Node2D, spaces_to_move: int) -> void:
	var space_children: Array[Node] = spaces_node.get_children()
	var max_spaces: int = space_children.size() - 1

	for i in range(spaces_to_move):
		if current_space_index >= max_spaces:
			break
			
		current_space_index += 1
		var target_position: Vector2 = space_children[current_space_index].global_position
		
		var tween: Tween = create_tween()
		tween.tween_property(self, "global_position", target_position, 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		await tween.finished

	movement_finished.emit()
