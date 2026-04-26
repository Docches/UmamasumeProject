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

@onready var giocatori_nodes = [$Lanes/P0, $Lanes/P1, $Lanes/P2, $Lanes/P3]
@onready var nomi_labels = [$UI/NomiContainer/Nome0, $UI/NomiContainer/Nome1, $UI/NomiContainer/Nome2, $UI/NomiContainer/Nome3]
@onready var countdown_label = $UI/CountdownLabel
@onready var winner_label = $UI/WinnerLabel

func _ready():
	randomize()
	winner_label.hide()
	countdown_label.show()
	
	# PREVENZIONE CRASH: Test Standalone (F6)
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: Avvio Standalone. Generazione Bot in corso...")
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i > 0, "name": "Tester" if i==0 else "BOT"})
	
	if multiplayer.is_server():
		_setup_game_clients.rpc()
		start_countdown()

# --- SETUP E SINCRONIZZAZIONE LOBBY ---
@rpc("authority", "call_local", "reliable")
func _setup_game_clients():
	var my_id = multiplayer.get_unique_id()
	
	for i in range(4):
		progress[i] = 0.0
		giocatori_nodes[i].position.y = start_y
		
		# Associa ogni corsia al rispettivo giocatore nel GlobalData
		if i < GlobalData.players_data.size():
			var p_data = GlobalData.players_data[i]
			giocatori_nodes[i].show()
			
			# --- INTEGRAZIONE NICKNAME UNIVERSALE ---
			if nomi_labels[i]:
				nomi_labels[i].text = p_data.get("name", "Giocatore " + str(i+1))
				
				if p_data.get("is_bot", false): 
					if not nomi_labels[i].text.begins_with("BOT"):
						nomi_labels[i].text += " (BOT)"
				
				if p_data.get("id") == my_id and not p_data.get("is_bot", false):
					nomi_labels[i].modulate = Color(1, 1, 0) # Giallo
				else:
					nomi_labels[i].modulate = Color(1, 1, 1) # Bianco per gli altri
		else:
			giocatori_nodes[i].hide()
			if nomi_labels[i]:
				nomi_labels[i].text = ""

	# Ferma tutti all'avvio
	client_sync_animation("idle")

# --- COUNTDOWN ---
func start_countdown():
	current_state = GameState.WAITING
	var countdown_steps = ["3", "2", "1", "VIA!"]
	
	for step in countdown_steps:
		update_countdown.rpc(step)
		await get_tree().create_timer(1.0).timeout
	
	start_race.rpc()

@rpc("authority", "call_local", "reliable")
func update_countdown(text: String):
	countdown_label.text = text

@rpc("authority", "call_local", "reliable")
func start_race():
	current_state = GameState.PLAYING
	countdown_label.hide()
	client_sync_animation("run") # Avvia l'animazione di corsa per tutti

# --- INPUT DEL GIOCATORE ---
func _unhandled_input(event: InputEvent) -> void:
	if current_state != GameState.PLAYING: return
	
	# Intercetta la barra spaziatrice e invia il comando al server
	if event.is_action_pressed("ui_accept"):
		receive_player_input.rpc_id(1)

# --- LOGICA BOT (Solo Server) ---
func _process(delta):
	if current_state != GameState.PLAYING or not multiplayer.is_server():
		return
		
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] += delta
			var current_bot_rate = bot_base_spam_rate + randf_range(-1.5, 1.5)
			var time_between_presses = 1.0 / current_bot_rate
			
			if bot_timers[i] >= time_between_presses:
				bot_timers[i] = 0.0
				_advance_lane(i)

# --- GESTIONE MOVIMENTI E ANIMAZIONI ---
@rpc("any_peer", "call_local", "reliable")
func receive_player_input():
	if not multiplayer.is_server() or current_state != GameState.PLAYING:
		return
		
	var sender_id = multiplayer.get_remote_sender_id()
	
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id and not GlobalData.players_data[i].get("is_bot", false):
			_advance_lane(i)
			break

func _advance_lane(lane_index: int):
	progress[lane_index] += step_size
	var new_y = start_y - progress[lane_index]
	
	update_position.rpc(lane_index, new_y)
	
	if new_y <= finish_y and current_state == GameState.PLAYING:
		current_state = GameState.FINISHED 
		_server_declare_winner(lane_index)

@rpc("authority", "call_local", "unreliable")
func update_position(lane_index: int, new_y: float):
	if is_instance_valid(giocatori_nodes[lane_index]):
		giocatori_nodes[lane_index].position.y = new_y

# Sincronizza l'animazione corrente per tutti i client
@rpc("authority", "call_local", "reliable")
func client_sync_animation(anim_name: String):
	for i in range(4):
		if is_instance_valid(giocatori_nodes[i]) and giocatori_nodes[i].visible:
			if giocatori_nodes[i].sprite_frames.has_animation(anim_name):
				giocatori_nodes[i].play(anim_name)
			elif anim_name == "idle":
				giocatori_nodes[i].stop() # Se non c'è "idle", semplicemente fermiamo l'animazione
			else:
				giocatori_nodes[i].play() # Se manca "run", prova a fare play sull'animazione di default

# --- VITTORIA E FINE GIOCO ---
func _server_declare_winner(winner_index: int) -> void:
	GlobalData.minigame_winners = [winner_index]
	
	client_show_winner_ui.rpc(winner_index)
	await get_tree().create_timer(4.0).timeout
	client_ritorna_al_tabellone.rpc()

@rpc("authority", "call_local", "reliable")
func client_show_winner_ui(winner_index: int) -> void:
	current_state = GameState.FINISHED
	countdown_label.hide()
	client_sync_animation("idle") # Ferma i personaggi
	
	var p_data = GlobalData.players_data[winner_index]
	var my_id = multiplayer.get_unique_id()
	
	var nome_vincitore = p_data.get("name", "Giocatore")
	if p_data.get("is_bot", false) and not nome_vincitore.begins_with("BOT"):
		nome_vincitore += " (BOT)"
	
	if p_data["id"] == my_id and not p_data.get("is_bot", false):
		winner_label.text = "HAI VINTO!"
	else:
		winner_label.text = "🏆 " + nome_vincitore + " HA VINTO! 🏆"
		
	winner_label.text += "\n+10 Monete!"
	winner_label.show()

@rpc("authority", "call_local", "reliable")
func client_ritorna_al_tabellone() -> void:
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
