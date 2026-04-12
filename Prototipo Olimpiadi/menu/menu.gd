extends Control

@onready var main_ui = $MainMenuUI
@onready var lobby_ui = $LobbyUI
@onready var ip_input = $MainMenuUI/JoinContainer/IPInput
@onready var player_list = $LobbyUI/Panel/PlayerList
@onready var start_button = $LobbyUI/Panel/StartButton
# Nodo per il titolo della lobby dove mostreremo il codice
@onready var lobby_title = $LobbyUI/Panel/TitoloLobby

const MASTER_IP = "87.106.29.126"
const MASTER_PORT = 9000
const PORT_RANGE_START = 10001

var pending_action: String = ""
var connected_players: Array = []
var active_rooms: Dictionary = {} 
var next_available_port: int = PORT_RANGE_START
var is_master_server: bool = false 
# Variabile per memorizzare il codice della sessione attuale
var current_room_code: String = ""

func _ready() -> void:
	print("--- [DEBUG] SCRIPT AVVIATO SUL NODO: ", name)
	main_ui.show()
	lobby_ui.hide()
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_master_connected)
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

# --- LOGICA CORE CLIENT ---

func _on_host_button_pressed() -> void:
	print("--- [DEBUG] TASTO HOST PREMUTO")
	pending_action = "host"
	_connect_to_master()

func _on_join_button_pressed() -> void:
	print("--- [DEBUG] TASTO JOIN PREMUTO")
	if ip_input.text == "" or ip_input.text == "Inserisci IP...": return
	pending_action = "join"
	# Salviamo il codice inserito manualmente per mostrarlo in lobby
	current_room_code = ip_input.text
	_connect_to_master()

func _connect_to_master() -> void:
	print("--- [DEBUG] TENTATIVO CONNESSIONE A: ", MASTER_IP)
	multiplayer.multiplayer_peer = null
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(MASTER_IP, MASTER_PORT)
	if err == OK:
		multiplayer.multiplayer_peer = peer
	else:
		print("--- [DEBUG] ERRORE CREAZIONE CLIENT: ", err)

func _on_master_connected() -> void:
	print("--- [DEBUG] CONNESSO AL MASTER SERVER")
	if pending_action == "host":
		master_request_room.rpc_id(1)
	elif pending_action == "join":
		master_request_join.rpc_id(1, current_room_code)
	pending_action = ""

func _on_master_failed() -> void:
	print("--- [DEBUG] CONNESSIONE AL MASTER FALLITA (TIMED OUT)")
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
	print("--- [DEBUG] RICEVUTI DETTAGLI STANZA: ", code, " PORTA: ", port)
	current_room_code = code # Memorizziamo il codice stanza
	
	multiplayer.multiplayer_peer = null
	main_ui.hide()
	lobby_ui.show()
	
	# Aggiorniamo il titolo della lobby con il codice stanza
	lobby_title.text = "SALA D'ATTESA\nStanza: " + current_room_code
	player_list.text = "[center]Avvio stanza sul server... attendi...[/center]"
	
	await get_tree().create_timer(1.5).timeout
	
	var peer = ENetMultiplayerPeer.new()
	if peer.create_client(ip, port) == OK:
		multiplayer.multiplayer_peer = peer

# --- LOGICA SERVER (VPS) ---

func _setup_master_server() -> void:
	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(MASTER_PORT) == OK:
		multiplayer.multiplayer_peer = peer
		is_master_server = true
		print("--- [MASTER] ORCHESTRATORE AVVIATO")

func _setup_game_instance(port: int) -> void:
	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(port) == OK:
		multiplayer.multiplayer_peer = peer
		is_master_server = false
		print("--- [ROOM] STANZA AVVIATA SU PORTA ", port)

# --- LOBBY E START ---

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server() and not is_master_server:
		if id not in connected_players:
			connected_players.append(id)
			client_update_lobby.rpc(connected_players)

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server() and not is_master_server:
		connected_players.erase(id)
		client_update_lobby.rpc(connected_players)
		if connected_players.size() == 0: 
			print("--- [ROOM] Stanza vuota, chiusura processo.")
			get_tree().quit()

@rpc("authority", "call_local", "reliable")
func client_update_lobby(players: Array) -> void:
	connected_players = players
	# Manteniamo il titolo aggiornato se necessario
	lobby_title.text = "SALA D'ATTESA\nStanza: " + current_room_code
	
	var text = "[center]GIOCATORI (" + str(connected_players.size()) + "/4):\n\n"
	for p_id in connected_players:
		text += "Player " + str(p_id) + "\n"
	player_list.text = text + "[/center]"
	
	start_button.visible = (connected_players.find(multiplayer.get_unique_id()) == 0)

func _on_start_button_pressed() -> void:
	server_trigger_start.rpc_id(1)

@rpc("any_peer", "call_local", "reliable")
func server_trigger_start() -> void:
	if not multiplayer.is_server(): return
	GlobalData.players_data.clear()
	for p_id in connected_players:
		GlobalData.players_data.append({"id": p_id, "is_bot": false})
	while GlobalData.players_data.size() < 4:
		GlobalData.players_data.append({"id": 0, "is_bot": true})
	client_start_game.rpc(GlobalData.players_data)

@rpc("authority", "call_local", "reliable")
func client_start_game(roster: Array) -> void:
	GlobalData.players_data = roster
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
