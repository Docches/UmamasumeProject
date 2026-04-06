extends Node2D

# --- GAME STATE ---
var game_started := false
var current_player_index := 0
var throw_results := {}
var players_order := []

# --- CONFIG ---
@export var player_scene: PackedScene

# --- NODES ---
@onready var spawn_point = $SpawnPoint

func _ready():
	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout
		start_game()

# --------------------------------------------------
# START GAME
# --------------------------------------------------
func start_game():
	game_started = true
	
	# Ordine casuale giocatori
	players_order = [0,1,2,3]
	players_order.shuffle()
	
	start_turn_rpc.rpc(0)

@rpc("call_local", "authority")
func start_turn_rpc(index: int):
	current_player_index = index
	
	var p_index = players_order[index]
	var player_data = GlobalData.players_data[p_index]
	
	spawn_player(p_index, player_data["id"], player_data["is_bot"])

# --------------------------------------------------
# SPAWN PLAYER
# --------------------------------------------------
func spawn_player(p_index: int, peer_id: int, is_bot: bool):
	var p = player_scene.instantiate()
	add_child(p)
	
	p.position = spawn_point.position
	p.player_index = p_index
	p.game_manager = self
	
	if not is_bot:
		p.set_multiplayer_authority(peer_id)
	else:
		p.set_as_bot()

# --------------------------------------------------
# RISULTATI
# --------------------------------------------------
func report_throw(player_index: int, distance: float):
	if not multiplayer.is_server():
		return
	
	throw_results[player_index] = distance
	
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
	
	for i in throw_results:
		ranking.append({
			"index": i,
			"dist": throw_results[i]
		})
	
	ranking.sort_custom(func(a,b): return a.dist > b.dist)
	
	show_results_rpc.rpc(ranking)

@rpc("call_local", "authority")
func show_results_rpc(ranking):
	print("=== CLASSIFICA ===")
	for i in range(ranking.size()):
		print(i+1, " - Player ", ranking[i].index, " -> ", ranking[i].dist)
	
	if multiplayer.is_server():
		var winners := []
		
		# primi 2 vincono (come team)
		winners.append(ranking[0].index)
		winners.append(ranking[1].index)
		
		GlobalData.minigame_winners = winners
		
		await get_tree().create_timer(4.0).timeout
		change_scene_rpc.rpc()

@rpc("call_local", "authority")
func change_scene_rpc():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
