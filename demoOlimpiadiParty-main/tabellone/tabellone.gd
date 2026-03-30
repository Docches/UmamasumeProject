extends Node2D

@export var minigame_scenes: Array[PackedScene]

@onready var spaces_node: Node2D = $Spaces
@onready var players_node: Node2D = $Players

# --- RIFERIMENTI ALLA UI ---
@onready var turn_label: Label = $UI/TurnLabel
@onready var dice_label: Label = $UI/DiceLabel
@onready var leaderboard_label: Label = $UI/LeaderboardLabel

var players: Array[Node] = []
enum GameState { IDLE, ROLLING, MOVING, WAITING_FOR_MINIGAME }
var current_state: GameState = GameState.IDLE

func _ready() -> void:
	players = players_node.get_children()
	restore_board_state()
	update_leaderboard()
	
	# Controllo Bonus Minigioco
	if not GlobalData.minigame_winners.is_empty():
		if multiplayer.is_server():
			apply_minigame_bonus.rpc(GlobalData.minigame_winners)
	else:
		if multiplayer.is_server():
			update_ui.rpc(GlobalData.current_player_index)

@rpc("call_local", "authority")
func apply_minigame_bonus(winners: Array):
	current_state = GameState.MOVING 
	turn_label.text = "VITTORIA DI SQUADRA!"
	dice_label.text = "I vincitori avanzano di 3 caselle!"
	await get_tree().create_timer(2.0).timeout
	
	for winner_index in winners:
		var active_player: BoardPlayer = players[winner_index]
		active_player.move_spaces(spaces_node, 3)
		await active_player.movement_finished
		GlobalData.player_space_indices[winner_index] = active_player.current_space_index
		
	update_leaderboard()
	if multiplayer.is_server():
		GlobalData.minigame_winners.clear() 
		sync_state.rpc(GlobalData.current_player_index)

func restore_board_state() -> void:
	var space_children = spaces_node.get_children()
	for i in range(players.size()):
		var player: BoardPlayer = players[i]
		var saved_index = mini(GlobalData.player_space_indices[i], space_children.size() - 1)
		player.current_space_index = saved_index
		player.global_position = space_children[saved_index].global_position
	GlobalData.is_first_board_load = false

# --- INPUT E TURNI ---

func _input(event: InputEvent) -> void:
	if current_state != GameState.IDLE: return
	
	var current_p = GlobalData.players_data[GlobalData.current_player_index]
	if current_p["id"] == multiplayer.get_unique_id() and not current_p["is_bot"]:
		if event.is_action_pressed("ui_accept"):
			request_roll.rpc_id(1)

@rpc("any_peer", "call_remote")
func request_roll():
	if multiplayer.is_server():
		var sender_id = multiplayer.get_remote_sender_id()
		var current_p = GlobalData.players_data[GlobalData.current_player_index]
		if sender_id == current_p["id"]:
			execute_turn_server()

func _process(delta: float) -> void:
	if not multiplayer.is_server(): return
	
	if current_state == GameState.IDLE:
		var current_p = GlobalData.players_data[GlobalData.current_player_index]
		if current_p["is_bot"]:
			current_state = GameState.WAITING_FOR_MINIGAME 
			await get_tree().create_timer(1.0).timeout 
			execute_turn_server()

# --- LOGICA DEL DADO E MOVIMENTO ---

func execute_turn_server() -> void:
	current_state = GameState.ROLLING
	var steps = randi_range(1, 6)
	var current_p_index = GlobalData.current_player_index
	
	animate_dice_roll.rpc(steps)
	await get_tree().create_timer(1.5).timeout
	sync_movement.rpc(current_p_index, steps)

@rpc("call_local", "authority")
func animate_dice_roll(final_steps: int):
	current_state = GameState.ROLLING

	for i in range(10):
		dice_label.text = "[ " + str(randi_range(1, 6)) + " ]"
		await get_tree().create_timer(0.1).timeout
	
	
	dice_label.text = "[ " + str(final_steps) + " ]"

@rpc("call_local", "authority")
func sync_movement(p_index: int, steps: int):
	current_state = GameState.MOVING
	var active_player: BoardPlayer = players[p_index]
	active_player.move_spaces(spaces_node, steps)
	await active_player.movement_finished
	
	GlobalData.player_space_indices[p_index] = active_player.current_space_index
	update_leaderboard() 
	
	if multiplayer.is_server():
		end_turn_server()

func end_turn_server() -> void:
	GlobalData.current_player_index += 1
	
	if GlobalData.current_player_index >= GlobalData.players_data.size():
		GlobalData.current_player_index = 0
		start_minigame_sequence.rpc()
	else:
		sync_state.rpc(GlobalData.current_player_index)

@rpc("call_local", "authority")
func sync_state(next_player_index):
	GlobalData.current_player_index = next_player_index
	current_state = GameState.IDLE
	update_ui(next_player_index) 

# --- AGGIORNAMENTO UI VISIVA ---

@rpc("call_local", "authority")
func update_ui(p_index: int):
	var current_p = GlobalData.players_data[p_index]
	
	var testo_turno = "Turno: Giocatore " + str(p_index + 1)
	if current_p["is_bot"]:
		testo_turno += " (BOT)"
	turn_label.text = testo_turno
	
	if current_p["is_bot"]:
		dice_label.text = "[ Il Bot sta tirando... ]"
	elif current_p["id"] == multiplayer.get_unique_id():
		dice_label.text = "[ PREMI SPAZIO ]"
	else:
		dice_label.text = "[ Attendi il tuo turno ]"

@rpc("call_local", "authority")
func update_leaderboard():
	var testo_classifica = "--- CLASSIFICA ---\n"
	var board_data = []
	

	for i in range(GlobalData.players_data.size()):
		board_data.append({"player": i + 1, "space": GlobalData.player_space_indices[i]})
		
	board_data.sort_custom(func(a, b): return a["space"] > b["space"])
	
	
	for i in range(board_data.size()):
		var data = board_data[i]
		testo_classifica += str(i + 1) + "° - Giocatore " + str(data["player"]) + " (Casella " + str(data["space"]) + ")\n"
		
	leaderboard_label.text = testo_classifica

# --- SEQUENZA MINIGIOCO ---

@rpc("call_local", "authority")
func start_minigame_sequence():
	current_state = GameState.WAITING_FOR_MINIGAME
	turn_label.text = "ATTENZIONE!"
	dice_label.text = "MINIGIOCO IN ARRIVO..."
	await get_tree().create_timer(3.0).timeout
	
	if multiplayer.is_server():
		var random_scene = minigame_scenes.pick_random()
		change_scene_all.rpc(random_scene.resource_path)

@rpc("call_local", "authority")
func change_scene_all(path: String):
	get_tree().change_scene_to_file(path)
