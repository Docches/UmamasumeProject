extends Control

@onready var ip_input: LineEdit = $IPInput
@onready var start_button: Button = $StartButton # Assicurati di avere questo nodo!

func _ready():
	multiplayer.connected_to_server.connect(_on_connection_success)
	multiplayer.peer_connected.connect(_on_peer_connected)

func _on_host_button_pressed() -> void:
	GlobalData.host_game()
	start_button.show() # Mostriamo il tasto "Avvia Partita" solo all'Host
	print("Sei l'Host! Aspetta i giocatori e poi premi Avvia.")

func _on_join_button_pressed() -> void:
	var ip = ip_input.text if ip_input.text != "" else "127.0.0.1"
	GlobalData.join_game(ip)
	print("In attesa che l'Host avvii la partita...")

func _on_connection_success():
	print("Connesso al server! Aspettiamo l'Host...")

func _on_peer_connected(id):
	if GlobalData.is_server:
		GlobalData.connected_peers.append(id)
		print("Nuovo giocatore unito! Totale umani: ", GlobalData.connected_peers.size())

# Questa è la funzione collegata al nuovo bottone StartButton
func _on_start_button_pressed() -> void:
	if multiplayer.is_server():
		setup_game_and_start.rpc()

@rpc("call_local", "authority")
func setup_game_and_start():
	if multiplayer.is_server():
		GlobalData.players_data.clear()
		
		# 1. Inseriamo i giocatori umani (Client)
		for peer_id in GlobalData.connected_peers:
			GlobalData.players_data.append({"id": peer_id, "is_bot": false})
			
		# 2. Riempiamo i buchi con i Bot fino ad arrivare a 4 giocatori
		while GlobalData.players_data.size() < 4:
			GlobalData.players_data.append({"id": 0, "is_bot": true}) # id 0 significa Bot
			
		# Inviamo la lista definitiva a tutti e cambiamo scena
		sync_roster.rpc(GlobalData.players_data)

@rpc("call_local", "authority")
func sync_roster(roster):
	GlobalData.players_data = roster
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
