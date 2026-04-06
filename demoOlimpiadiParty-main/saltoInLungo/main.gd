extends Node2D

# --- GAME STATE ---
var game_started := false
var current_player_index := 0
var players_order := []
var results := {}

# --- CONFIG ---
@export var player_scene: PackedScene

# --- NODES ---
@onready var spawn_point = $SpawnPoint
@onready var foul_line = $FoulLine

func _ready():
	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout
		start_game()

# --------------------------------------------------
# START GAME
# --------------------------------------------------
func start_game():
	game_started = true
	
	players_order = [0,1,2,3]
	players_order.shuffle()
	
	start_turn_rpc.rpc(0)

@rpc("call_local", "authority")
func start_turn_rpc(index):
	current_player_index = index
	
	var p_index = players_order[index]
	var p_data = GlobalData.players_data[p_index]
	
	spawn_player(p_index, p_data["id"], p_data["is_bot"])

# --------------------------------------------------
# SPAWN PLAYER
# --------------------------------------------------
func spawn_player(p_index: int, peer_id: int, is_bot: bool):
	var p = player_scene.instantiate()
	add_child(p)
	
	p.position = spawn_point.position
	p.player_index = p_index
	p.game_manager = self
	
	# 👇 PASSIAMO LA LINEA DI FALLO
	p.foul_line_x = foul_line.global_position.x
	
	if not is_bot:
		p.set_multiplayer_authority(peer_id)
	else:
		p.set_as_bot()

# --------------------------------------------------
# RISULTATI
# --------------------------------------------------
func report_result(player_index, distance):
	if not multiplayer.is_server():
		return
	
	results[player_index] = distance
	next_turn()

func next_turn():
	current_player_index += 1
	
	if current_player_index >= players_order.size():
		finish_game()
	else:
		start_turn_rpc.rpc(current_player_index)

# --------------------------------------------------
# FINE PARTITA
# --------------------------------------------------
func finish_game():
	var ranking := []
	
	for i in results:
		ranking.append({
			"index": i,
			"dist": results[i]
		})
	
	ranking.sort_custom(func(a,b): return a.dist > b.dist)
	show_results_rpc.rpc(ranking)

@rpc("call_local", "authority")
func show_results_rpc(ranking):
	print("=== SALTO IN LUNGO ===")
	for i in range(ranking.size()):
		print(i+1, " - Player ", ranking[i].index, " -> ", ranking[i].dist)
	
	if multiplayer.is_server():
		var winners := [ranking[0].index, ranking[1].index]
		GlobalData.minigame_winners = winners
		
		await get_tree().create_timer(4.0).timeout
		change_scene_rpc.rpc()

@rpc("call_local", "authority")
func change_scene_rpc():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
