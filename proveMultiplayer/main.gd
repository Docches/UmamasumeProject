extends Node2D

const PORT = 8080
const SERVER_IP = "127.0.0.1"

var peer = ENetMultiplayerPeer.new()
@export var player_scene: PackedScene


func _on_btn_host_pressed() -> void:
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_add_player)
	_add_player(1)
	hide_ui()
	


func _on_btn_join_pressed() -> void:
	var server_add = $CanvasLayer/AddressInput.text
	var server_port = $CanvasLayer/PortInput.text.to_int()
	if server_add == "" or server_port == 0:
		print("Inserisci indirizzo e porta validi!")
		return
	var error = peer.create_client(server_add, server_port)
	if error != OK:
		print("Errore nella creazione del client: ", error)
		return
	multiplayer.multiplayer_peer = peer
	hide_ui()
	
func _add_player(id: int):
	var player = player_scene.instantiate()
	player.name = str(id)
	player.position = Vector2(200, 200)
	$Level.add_child(player)
	
func hide_ui():
	$CanvasLayer.hide()
	
