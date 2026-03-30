extends Control

@onready var ip_input: LineEdit = $IPInput
@onready var start_button: Button = $StartButton 

var input_thread: Thread 

func _ready():
	if "--server" in OS.get_cmdline_args():
		_on_host_button_pressed()
		input_thread = Thread.new()
		input_thread.start(_thread_listen_input)

func _thread_listen_input():
	while true:
		var input = OS.read_string_from_stdin().strip_edges().to_lower()
		if input == "start":
			print("[SERVER] Comando 'start' ricevuto, lo sposto sul main thread...")
			call_deferred("_trigger_start_from_main_thread")
			break 

func _trigger_start_from_main_thread():
	setup_game_and_start.rpc()

func _exit_tree():
	if input_thread and input_thread.is_alive():
		input_thread.wait_to_finish()

func _on_host_button_pressed() -> void:
	GlobalData.host_game()
	start_button.show() 

func _on_join_button_pressed() -> void:
	var ip = ip_input.text if ip_input.text != "" else "127.0.0.1"
	GlobalData.join_game(ip)

func _on_connection_success():
	pass

func _on_peer_connected(id):
	if multiplayer.is_server():
		if id not in GlobalData.connected_peers:
			GlobalData.connected_peers.append(id)

func _on_start_button_pressed() -> void:
	if multiplayer.is_server():
		setup_game_and_start.rpc()

@rpc("call_local", "authority")
func setup_game_and_start():
	if multiplayer.is_server():
		print("[SERVER] Inizio setup partita...")
		GlobalData.players_data.clear()
		
		var peers = multiplayer.get_peers()
		
		for p_id in peers:
			GlobalData.players_data.append({"id": p_id, "is_bot": false})
			print("[SERVER] Aggiunto umano con ID: ", p_id)
			
		
		if not DisplayServer.get_name() == "headless":
			GlobalData.players_data.append({"id": 1, "is_bot": false})
			
		
		while GlobalData.players_data.size() < 4:
			GlobalData.players_data.append({"id": 0, "is_bot": true})
			print("[SERVER] Aggiunto BOT per riempire slot.")
			
		sync_roster.rpc(GlobalData.players_data)
		
@rpc("call_local", "authority")
func sync_roster(roster):
	GlobalData.players_data = roster
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
