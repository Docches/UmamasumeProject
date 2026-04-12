extends Control

@export var player_scene: PackedScene

# Riferimenti alla UI
@onready var buttons = [$UI/BtnHorse0, $UI/BtnHorse1, $UI/BtnHorse2, $UI/BtnHorse3]
@onready var labels = [$UI/LblHorse0, $UI/LblHorse1, $UI/LblHorse2, $UI/LblHorse3]
@onready var countdown_label = $UI/CountdownLabel
@onready var winner_label = $UI/WinnerLabel

enum GameState { SELECTING, COUNTDOWN, RACING, FINISHED }
var current_state = GameState.SELECTING

const FINISH_LINE_X = 1100.0 # Modifica questo valore in base alla larghezza del tuo schermo/pista

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

# Fisica e Nodi
var horses_nodes = []
var horses_speeds = [0.0, 0.0, 0.0, 0.0]
var horses_pos = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]

func _ready():
	countdown_label.hide()
	winner_label.hide()
	
	if multiplayer.is_server():
		for p in GlobalData.players_data:
			if not p["is_bot"]:
				humans_to_pick += 1
	
	for i in range(4):
		# Catturiamo l'indice locale usando bind o una lambda corretta per Godot 4
		buttons[i].pressed.connect(func(): _on_horse_btn_pressed(i))

# --- 1. FASE DI SELEZIONE (CLIENT -> SERVER) ---

func _on_horse_btn_pressed(horse_index: int):
	if current_state != GameState.SELECTING: return
	
	# Il client chiede al server di prenotare quel cavallo
	server_request_horse.rpc_id(1, horse_index)

@rpc("any_peer", "call_local", "reliable")
func server_request_horse(horse_index: int):
	if not multiplayer.is_server() or current_state != GameState.SELECTING: return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var player_index = -1
	
	# Verifica di sicurezza: Chi è il mittente?
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id:
			player_index = i
			break
			
	if player_index == -1: return # Peer non valido
	if player_index in horse_owners: return # Ha già scelto un cavallo
	if horse_owners[horse_index] != -1: return # Cavallo già preso
	
	# Assegnazione valida
	horse_owners[horse_index] = player_index
	humans_picked += 1
	
	client_update_selection.rpc(horse_index, player_index)
	
	if humans_picked >= humans_to_pick:
		_server_assign_bots_and_start()

func _server_assign_bots_and_start():
	var bot_indices = []
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["is_bot"]: bot_indices.append(i)
	
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
	var text = "Player " + str(p_data["id"]) if not p_data["is_bot"] else "BOT"
	
	# Se sono io che ho appena scelto, disabilito gli altri pulsanti per me
	if p_data["id"] == multiplayer.get_unique_id():
		for btn in buttons:
			btn.disabled = true
			
	labels[horse_index].text = text

# --- 2. FASE COUNTDOWN E SPAWN ---

func _server_start_countdown():
	current_state = GameState.COUNTDOWN
	
	# Disabilita UI per tutti
	client_prepare_race.rpc()
	
	# Spawn Cavalli (Server Only)
	for i in range(4):
		horses_pos[i] = track_positions[i]
		horses_speeds[i] = randf_range(300.0, 500.0) # Velocità determinata dal server
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
	if text == "":
		countdown_label.hide()

@rpc("authority", "call_local", "reliable")
func client_spawn_horse(horse_index: int, start_pos: Vector2):
	var runner = player_scene.instantiate()
	runner.position = start_pos
	# Rimuovi l'autorità fisica locale, il client è solo uno spettatore
	add_child(runner)
	
	# Salva il riferimento al nodo per poterlo muovere
	if horses_nodes.size() <= horse_index:
		horses_nodes.resize(4)
	horses_nodes[horse_index] = runner

# --- 3. FASE GARA E FISICA SERVER-SIDE ---

func _physics_process(delta):
	if current_state != GameState.RACING: return
	
	if multiplayer.is_server():
		var someone_finished = false
		var winner_horse_idx = -1
		
		# Il server muove i cavalli e controlla il traguardo
		for i in range(4):
			# Aggiungiamo un pizzico di variabilità alla velocità ogni frame
			horses_speeds[i] += randf_range(-10.0, 10.0)
			horses_speeds[i] = clamp(horses_speeds[i], 100.0, 700.0)
			
			horses_pos[i].x += horses_speeds[i] * delta
			
			if horses_pos[i].x >= FINISH_LINE_X and not someone_finished:
				someone_finished = true
				winner_horse_idx = i
		
		# Invia posizioni ai client 60 volte al secondo
		client_sync_race.rpc(horses_pos)
		
		if someone_finished:
			_server_declare_winner(winner_horse_idx)

@rpc("authority", "call_local", "unreliable")
func client_sync_race(positions: Array):
	for i in range(4):
		if is_instance_valid(horses_nodes[i]):
			horses_nodes[i].position = positions[i]

# --- 4. FASE FINALE ---

func _server_declare_winner(horse_index: int):
	current_state = GameState.FINISHED
	var winner_player_idx = horse_owners[horse_index]
	
	client_show_winner.rpc(winner_player_idx)
	
	GlobalData.minigame_winners = [winner_player_idx]
	await get_tree().create_timer(5.0).timeout
	client_return_to_board.rpc()

@rpc("authority", "call_local", "reliable")
func client_show_winner(player_index: int):
	var p_data = GlobalData.players_data[player_index]
	var text = "HA VINTO PLAYER " + str(p_data["id"])
	if p_data["is_bot"]: text = "HA VINTO UN BOT!"
	
	winner_label.text = text + "\n+3 Passi Bonus!"
	winner_label.show()

@rpc("authority", "call_local", "reliable")
func client_return_to_board():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
