extends Node2D

enum GameState { WAITING, PLAYING, FINISHED }
var current_state = GameState.WAITING

# --- IMPOSTAZIONI GARA ---
@export var start_y: float = 600.0  # Posizione Y di partenza (basso)
@export var finish_y: float = 100.0 # Posizione Y del traguardo (alto)
@export var step_size: float = 15.0 # Quanti pixel si muove ad ogni "Spam"
@export var bot_base_spam_rate: float = 7.0 # Velocità base bot (click al sec)

var progress = [0.0, 0.0, 0.0, 0.0]
var bot_timers = [0.0, 0.0, 0.0, 0.0]

# Mappa l'indice della corsia (0-3) all'ID del Peer (0 = Bot)
var lane_assignments = {0: 0, 1: 0, 2: 0, 3: 0} 

@onready var giocatori_nodes = [$Lanes/P0, $Lanes/P1, $Lanes/P2, $Lanes/P3]
@onready var nomi_labels = [$UI/NomiContainer/Nome0, $UI/NomiContainer/Nome1, $UI/NomiContainer/Nome2, $UI/NomiContainer/Nome3]
@onready var countdown_label = $UI/CountdownLabel
@onready var winner_label = $UI/WinnerLabel

func _ready():
	winner_label.hide()
	countdown_label.show()
	
	if multiplayer.is_server():
		_assign_lanes()
		rpc("_setup_game_clients", lane_assignments)
		start_countdown()

# --- SETUP E SINCRONIZZAZIONE LOBBY ---
func _assign_lanes():
	var peers = multiplayer.get_peers()
	
	var all_players = []
	all_players.append(1)

	for p in peers:
		all_players.append(p)
	
	for i in range(4):
		if i < all_players.size():
			lane_assignments[i] = int(all_players[i]) 
		else:
			lane_assignments[i] = 0 

@rpc("authority", "call_local", "reliable")
func _setup_game_clients(assignments: Dictionary):
	lane_assignments = assignments
	
	for i in range(4):
		progress[i] = 0.0
		giocatori_nodes[i].position.y = start_y
		
		# Imposta il nome della corsia in basso
		var id = lane_assignments[i]
		if id == 0:
			nomi_labels[i].text = "Bot " + str(i + 1)
		elif id == multiplayer.get_unique_id():
			nomi_labels[i].text = "Tu (P" + str(i + 1) + ")"
		else:
			nomi_labels[i].text = "P" + str(i + 1)

# --- COUNTDOWN ---
func start_countdown():
	current_state = GameState.WAITING
	var countdown_steps = ["3", "2", "1", "VIA!"]
	
	for step in countdown_steps:
		rpc("update_countdown", step)
		await get_tree().create_timer(1.0).timeout
	
	rpc("start_race")

@rpc("authority", "call_local", "reliable")
func update_countdown(text: String):
	countdown_label.text = text

@rpc("authority", "call_local", "reliable")
func start_race():
	current_state = GameState.PLAYING
	countdown_label.hide()

# --- LOOP DI GIOCO ---
func _process(delta):
	if current_state != GameState.PLAYING:
		return
		
	# 1. INPUT DEL GIOCATORE (Client / Host)
	if Input.is_action_just_pressed("ui_accept"): # Barra spaziatrice
		rpc_id(1, "receive_player_input", multiplayer.get_unique_id())

	# 2. LOGICA BOT (Gestita solo dal Server)
	if multiplayer.is_server():
		for i in range(4):
			if lane_assignments[i] == 0: # È un bot
				bot_timers[i] += delta
				var current_bot_rate = bot_base_spam_rate + randf_range(-1.0, 2.0)
				var time_between_presses = 1.0 / current_bot_rate
				
				if bot_timers[i] >= time_between_presses:
					bot_timers[i] = 0.0
					_advance_lane(i)

# --- GESTIONE MOVIMENTI ---
@rpc("any_peer", "call_local", "reliable")
func receive_player_input(peer_id: int):
	if not multiplayer.is_server():
		return
		
	# Trova la corsia del giocatore che ha spammato spazio
	for i in range(4):
		if lane_assignments[i] == peer_id:
			_advance_lane(i)
			break

func _advance_lane(lane_index: int):
	if current_state != GameState.PLAYING:
		return
		
	progress[lane_index] += step_size
	var new_y = start_y - progress[lane_index]
	
	rpc("update_position", lane_index, new_y)
	
	if new_y <= finish_y:
		current_state = GameState.FINISHED 
		var winner_id = lane_assignments[lane_index]
		var winner_name = ""
		if winner_id == 0:
			winner_name = "BOT " + str(lane_index + 1)
		else:
			winner_name = "GIOCATORE " + str(lane_index + 1)
		_server_declare_winner(winner_name, [lane_index])

@rpc("authority", "call_local", "unreliable")
func update_position(lane_index: int, new_y: float):
	giocatori_nodes[lane_index].position.y = new_y

# --- VITTORIA E FINE GIOCO ---
@rpc("authority", "call_local", "reliable")
func declare_winner(lane_index: int):
	current_state = GameState.FINISHED
	var winner_id = lane_assignments[lane_index]
	
	if winner_id == 0:
		winner_label.text = "IL BOT HA VINTO!"
	elif winner_id == multiplayer.get_unique_id():
		winner_label.text = "HAI VINTO!"
	else:
		winner_label.text = "IL GIOCATORE " + str(lane_index + 1) + " HA VINTO!"
		
	winner_label.show()
	
	# Salva il vincitore nel GlobalData se necessario e torna al tabellone
	if multiplayer.is_server():
		GlobalData.minigame_winners = [winner_id]
		await get_tree().create_timer(4.0).timeout
		get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
		
		
func _server_declare_winner(winner_name: String, winner_slots: Array) -> void:
	client_sync_state.rpc(GameState.FINISHED)
	GlobalData.minigame_winners = winner_slots.duplicate()
	client_show_winner_ui.rpc(winner_name)
	await get_tree().create_timer(3.0).timeout
	client_ritorna_al_tabellone.rpc()
@rpc("authority", "call_local", "reliable")
func client_sync_state(new_state: int) -> void:
	current_state = new_state

@rpc("authority", "call_local", "reliable")
func client_show_winner_ui(winner_name: String) -> void:
	var my_slot = -1
	for i in range(4):
		if lane_assignments[i] == multiplayer.get_unique_id():
			my_slot = i
			break
			
	if GlobalData.minigame_winners.has(my_slot):
		winner_label.text = "HAI VINTO!"
	else:
		winner_label.text = winner_name + " HA VINTO!"
		
	winner_label.show()

@rpc("authority", "call_local", "reliable")
func client_ritorna_al_tabellone() -> void:
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
