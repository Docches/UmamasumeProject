extends Control

@export var player_scene: PackedScene

# Riferimenti alla UI
@onready var buttons = [$UI/BtnHorse0, $UI/BtnHorse1, $UI/BtnHorse2, $UI/BtnHorse3]
@onready var labels = [$UI/LblHorse0, $UI/LblHorse1, $UI/LblHorse2, $UI/LblHorse3]
@onready var countdown_label = $UI/CountdownLabel
@onready var winner_label = $UI/WinnerLabel

enum GameState { SELECTING, COUNTDOWN, RACING, FINISHED }
var current_state = GameState.SELECTING

const FINISH_LINE_X = 1100.0 # Modifica questo valore in base alla larghezza della tua pista

# Dati Server-Side
var horse_owners = [-1, -1, -1, -1] # Mappa Indice Cavallo -> Indice in GlobalData.players_data
var humans_to_pick = 0
var humans_picked = 0

var track_positions = [
	Vector2(100, 75),
	Vector2(100, 250),
	Vector2(100, 400),
	Vector2(100, 550)
]

# --- NODI E POSIZIONI ---
var horses_nodes = []
var horses_pos = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]

# --- VARIABILI SUSPENSE (Gestite dal Server) ---
var horses_run_speed = [0.0, 0.0, 0.0, 0.0]
var horses_target_speed = [0.0, 0.0, 0.0, 0.0]
var change_speed_timer = [0.0, 0.0, 0.0, 0.0]

const MIN_SPEED: float = 50.0
const MAX_SPEED: float = 350.0
const BURST_SPEED: float = 750.0
const STUMBLE_SPEED: float = 10.0

func _ready():
	randomize()
	countdown_label.hide()
	winner_label.hide()
	
	if multiplayer.is_server():
		for p in GlobalData.players_data:
			if not p.get("is_bot", false):
				humans_to_pick += 1
	
	for i in range(4):
		buttons[i].pressed.connect(func(): _on_horse_btn_pressed(i))

# --- 1. FASE DI SELEZIONE (CLIENT -> SERVER) ---

func _on_horse_btn_pressed(horse_index: int):
	if current_state != GameState.SELECTING: return
	server_request_horse.rpc_id(1, horse_index)

@rpc("any_peer", "call_local", "reliable")
func server_request_horse(horse_index: int):
	if not multiplayer.is_server() or current_state != GameState.SELECTING: return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var player_index = -1
	
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id:
			player_index = i
			break
			
	if player_index == -1: return 
	if player_index in horse_owners: return 
	if horse_owners[horse_index] != -1: return 
	
	horse_owners[horse_index] = player_index
	humans_picked += 1
	
	client_update_selection.rpc(horse_index, player_index)
	
	if humans_picked >= humans_to_pick:
		_server_assign_bots_and_start()

func _server_assign_bots_and_start():
	var bot_indices = []
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i].get("is_bot", false): bot_indices.append(i)
	
	var free_horses = []
	for i in range(4):
		if horse_owners[i] == -1: free_horses.append(i)
	
	free_horses.shuffle()
	
	for i in range(bot_indices.size()):
		var h_idx = free_horses[i]
		var p_idx = bot_indices[i]
		horse_owners[h_idx] = p_idx
		client_update_selection.rpc(h_idx, p_idx)
		
	_server_start_countdown()

@rpc("authority", "call_local", "reliable")
func client_update_selection(horse_index: int, player_index: int):
	horse_owners[horse_index] = player_index
	buttons[horse_index].disabled = true
	
	var p_data = GlobalData.players_data[player_index]
	var text = "Player " + str(p_data["id"]) if not p_data.get("is_bot", false) else "BOT"
	
	if p_data["id"] == multiplayer.get_unique_id():
		for btn in buttons:
			btn.disabled = true
			
	labels[horse_index].text = text

# --- 2. FASE COUNTDOWN E SPAWN ---

func _server_start_countdown():
	current_state = GameState.COUNTDOWN
	client_prepare_race.rpc()
	
	for i in range(4):
		horses_pos[i] = track_positions[i]
		client_spawn_horse.rpc(i, track_positions[i])
	
	var countdown_steps = ["3", "2", "1", "VIA!"]
	for step in countdown_steps:
		client_sync_countdown.rpc(step)
		await get_tree().create_timer(1.0).timeout
	
	client_sync_countdown.rpc("")
	current_state = GameState.RACING

@rpc("authority", "call_local", "reliable")
func client_prepare_race():
	for btn in buttons: btn.hide()
	countdown_label.show()

@rpc("authority", "call_local", "reliable")
func client_sync_countdown(text: String):
	countdown_label.text = text
	if text == "": countdown_label.hide()

@rpc("authority", "call_local", "reliable")
func client_spawn_horse(horse_index: int, start_pos: Vector2):
	var runner = player_scene.instantiate()
	runner.position = start_pos
	
	# Disabilitiamo la fisica locale del cavallo: ora è un burattino del server
	runner.set_process(false)
	runner.set_physics_process(false)
	if runner is RigidBody2D: runner.freeze = true
	
	add_child(runner)
	
	if horses_nodes.size() <= horse_index:
		horses_nodes.resize(4)
	horses_nodes[horse_index] = runner

# --- 3. FASE GARA E LOGICA SUSPENSE (SERVER-SIDE) ---

func _physics_process(delta):
	# Si muovono SOLO quando lo stato è RACING
	if current_state != GameState.RACING: return
	
	if multiplayer.is_server():
		var someone_finished = false
		var winner_horse_idx = -1
		
		for i in range(4):
			# --- LOGICA SUSPENSE ---
			change_speed_timer[i] -= delta
			if change_speed_timer[i] <= 0:
				var roll = randf()
				if roll < 0.15:
					horses_target_speed[i] = BURST_SPEED
					change_speed_timer[i] = randf_range(0.2, 0.5)
				elif roll < 0.30:
					horses_target_speed[i] = STUMBLE_SPEED
					change_speed_timer[i] = randf_range(0.3, 0.7)
				else:
					horses_target_speed[i] = randf_range(MIN_SPEED, MAX_SPEED)
					change_speed_timer[i] = randf_range(0.2, 0.8)
					
			horses_run_speed[i] = lerpf(horses_run_speed[i], horses_target_speed[i], 4.0 * delta)
			horses_pos[i].x += horses_run_speed[i] * delta
			
			# Controlla Traguardo
			if horses_pos[i].x >= FINISH_LINE_X and not someone_finished:
				someone_finished = true
				winner_horse_idx = i
		
		# Sincronizza le posizioni con i client
		client_sync_race.rpc(horses_pos)
		
		if someone_finished:
			# Imposta FINISHED: il _physics_process si congela e nessuno si muove più!
			current_state = GameState.FINISHED
			_server_declare_winner(winner_horse_idx)

@rpc("authority", "call_local", "unreliable")
func client_sync_race(positions: Array):
	for i in range(4):
		if is_instance_valid(horses_nodes[i]):
			horses_nodes[i].position = positions[i]

# --- 4. FASE FINALE ---

func _server_declare_winner(horse_index: int):
	var winner_player_idx = horse_owners[horse_index]
	
	client_show_winner.rpc(winner_player_idx)
	
	GlobalData.minigame_winners = [winner_player_idx]
	await get_tree().create_timer(5.0).timeout
	client_return_to_board.rpc()

@rpc("authority", "call_local", "reliable")
func client_show_winner(player_index: int):
	var p_data = GlobalData.players_data[player_index]
	var text = "HA VINTO PLAYER " + str(p_data["id"])
	if p_data.get("is_bot", false): text = "HA VINTO UN BOT!"
	
	winner_label.text = text + "\n+3 Passi Bonus!"
	winner_label.show()

@rpc("authority", "call_local", "reliable")
func client_return_to_board():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
