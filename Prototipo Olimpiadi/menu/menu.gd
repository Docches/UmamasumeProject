extends Control

@onready var main_ui = $MainMenuUI
@onready var lobby_ui = $LobbyUI
@onready var ip_input = $MainMenuUI/JoinContainer/IPInput
@onready var player_list = $LobbyUI/Panel/PlayerList
@onready var start_button = $LobbyUI/Panel/StartButton
@onready var lobby_title = $LobbyUI/Panel/TitoloLobby

const MASTER_IP = "95.216.160.153" # VPS Guarducci
#const MASTER_IP = "87.106.29.126" # VPS Amine
const MASTER_PORT = 9000
const PORT_RANGE_START = 10001

var pending_action: String = ""
var room_players: Array = [] # Tiene traccia dei veri giocatori connessi
var active_rooms: Dictionary = {} 
var next_available_port: int = PORT_RANGE_START
var is_master_server: bool = false 
var current_room_code: String = ""

func _ready() -> void:
	print("--- [DEBUG] SCRIPT AVVIATO SUL NODO: ", name)
	main_ui.show()
	lobby_ui.hide()
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_master_failed)
	
	var args = OS.get_cmdline_user_args()
	if "--master" in args:
		_setup_master_server()
	elif "--server_instance" in args:
		var port = _get_arg_val(args, "--port").to_int()
		_setup_game_instance(port)

func _get_arg_val(args: PackedStringArray, key: String) -> String:
	var idx = args.find(key)
	return args[idx + 1] if idx != -1 and idx + 1 < args.size() else ""

# --- SALVATAGGIO NICKNAME LOCALE (Cerca-Testo Intelligente) ---
func _save_nickname() -> void:
	var my_name = ""
	var tutte_le_caselle = _trova_tutte_caselle(self)
	
	for casella in tutte_le_caselle:
		if casella.name == "IPInput":
			continue
			
		var testo_digitato = casella.text.strip_edges()
		if testo_digitato != "" and testo_digitato != "Inserisci IP...":
			my_name = testo_digitato
			break
	
	if my_name == "": 
		my_name = "Giocatore"
		
	GlobalData.local_player_name = my_name
	print("--- [DEBUG] Nickname salvato: ", GlobalData.local_player_name)

func _trova_tutte_caselle(nodo_corrente: Node) -> Array:
	var caselle_trovate = []
	if nodo_corrente is LineEdit:
		caselle_trovate.append(nodo_corrente)
	
	for child in nodo_corrente.get_children():
		caselle_trovate.append_array(_trova_tutte_caselle(child))
		
	return caselle_trovate

# --- LOGICA CORE CLIENT ---

func _on_host_button_pressed() -> void:
	print("--- [DEBUG] TASTO HOST PREMUTO")
	_save_nickname()
	pending_action = "host"
	_connect_to_master()

func _on_join_button_pressed() -> void:
	print("--- [DEBUG] TASTO JOIN PREMUTO")
	if ip_input.text == "" or ip_input.text == "Inserisci IP...": return
	_save_nickname()
	pending_action = "join"
	current_room_code = ip_input.text
	_connect_to_master()

# Modalità Solo Integrata
func _on_solo_button_pressed():
	_save_nickname()
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(8910, 4) 
	
	if error == OK:
		multiplayer.multiplayer_peer = peer
		GlobalData.players_data.clear()
		GlobalData.players_data.append({"id": 1, "name": GlobalData.local_player_name, "is_bot": false})
		GlobalData.players_data.append({"id": 101, "name": "BOT 1", "is_bot": true})
		GlobalData.players_data.append({"id": 102, "name": "BOT 2", "is_bot": true})
		GlobalData.players_data.append({"id": 103, "name": "BOT 3", "is_bot": true})
		
		get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
	else:
		print("Errore nella creazione del server locale!")

func _connect_to_master() -> void:
	multiplayer.multiplayer_peer = null
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(MASTER_IP, MASTER_PORT)
	if err == OK:
		multiplayer.multiplayer_peer = peer

func _on_connected_to_server() -> void:
	if pending_action == "host":
		master_request_room.rpc_id(1)
	elif pending_action == "join":
		master_request_join.rpc_id(1, current_room_code)
	elif pending_action == "room":
		# Connessi alla VERA stanza! Registriamo il nostro Nickname
		server_register_player.rpc_id(1, GlobalData.local_player_name)

func _on_master_failed() -> void:
	pending_action = ""

# --- RPC MASTER ---

@rpc("any_peer", "call_local", "reliable")
func master_request_room() -> void:
	if not multiplayer.is_server(): return
	var sender_id = multiplayer.get_remote_sender_id()
	var code = str(randi() % 9000 + 1000)
	var port = next_available_port
	next_available_port += 1
	
	var args = ["--display-driver", "headless", "--", "--server_instance", "--port", str(port)]
	var pid = OS.create_instance(args)
	if pid != -1:
		active_rooms[code] = port
		master_send_room_details.rpc_id(sender_id, MASTER_IP, port, code)

@rpc("any_peer", "call_local", "reliable")
func master_request_join(code: String) -> void:
	if not multiplayer.is_server(): return
	var sender_id = multiplayer.get_remote_sender_id()
	if active_rooms.has(code):
		master_send_room_details.rpc_id(sender_id, MASTER_IP, active_rooms[code], code)

@rpc("authority", "call_local", "reliable")
func master_send_room_details(ip: String, port: int, code: String) -> void:
	current_room_code = code
	multiplayer.multiplayer_peer = null
	main_ui.hide()
	lobby_ui.show()
	
	lobby_title.text = "SALA D'ATTESA\nStanza: " + current_room_code
	player_list.text = "[center]Connessione in corso...[/center]"
	
	pending_action = "room"
	await get_tree().create_timer(1.5).timeout
	
	var peer = ENetMultiplayerPeer.new()
	if peer.create_client(ip, port) == OK:
		multiplayer.multiplayer_peer = peer

# --- LOGICA SERVER (VPS) E LOBBY ---

func _setup_master_server() -> void:
	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(MASTER_PORT) == OK:
		multiplayer.multiplayer_peer = peer
		is_master_server = true

func _setup_game_instance(port: int) -> void:
	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(port) == OK:
		multiplayer.multiplayer_peer = peer
		is_master_server = false

func _on_peer_connected(id: int) -> void:
	# Il server attende l'RPC server_register_player prima di aggiungere qualcuno alla lista
	pass

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server() and not is_master_server:
		for i in range(room_players.size() - 1, -1, -1):
			if room_players[i]["id"] == id:
				room_players.remove_at(i)
				break
				
		client_update_lobby.rpc(room_players)
		
		if room_players.size() == 0: 
			print("--- [ROOM] Stanza vuota, chiusura processo.")
			get_tree().quit()

# Riceve il nome dal client e controlla i doppioni
@rpc("any_peer", "call_local", "reliable")
func server_register_player(desired_name: String) -> void:
	if not multiplayer.is_server(): return
	var sender_id = multiplayer.get_remote_sender_id()
	
	var final_name = desired_name
	var counter = 1
	var name_exists = true
	
	while name_exists:
		name_exists = false
		for p in room_players:
			if p["name"] == final_name:
				name_exists = true
				final_name = desired_name + " (" + str(counter) + ")"
				counter += 1
				break
				
	room_players.append({"id": sender_id, "name": final_name, "is_bot": false})
	client_update_lobby.rpc(room_players)

@rpc("authority", "call_local", "reliable")
func client_update_lobby(players: Array) -> void:
	room_players = players
	
	var text = "[center]GIOCATORI (" + str(room_players.size()) + "/4):\n\n"
	for p in room_players:
		text += p["name"] + "\n"
	player_list.text = text + "[/center]"
	
	# Il tasto START appare SOLO a chi ha creato la stanza
	if room_players.size() > 0 and room_players[0]["id"] == multiplayer.get_unique_id():
		start_button.show()
	else:
		start_button.hide()

func _on_start_button_pressed() -> void:
	server_trigger_start.rpc_id(1)

@rpc("any_peer", "call_local", "reliable")
func server_trigger_start() -> void:
	if not multiplayer.is_server(): return
	
	var final_roster = room_players.duplicate()
	var bot_count = 1
	
	while final_roster.size() < 4:
		final_roster.append({
			"id": randi() % 1000 + 100, 
			"name": "BOT " + str(bot_count), 
			"is_bot": true
		})
		bot_count += 1
		
	client_start_game.rpc(final_roster)

@rpc("authority", "call_local", "reliable")
func client_start_game(roster: Array) -> void:
	GlobalData.players_data = roster
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
