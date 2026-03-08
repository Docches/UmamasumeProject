extends Node2D

const PORT = 8080
const MAXPLAYER = 4

var peer = ENetMultiplayerPeer.new()
@export var player_scene: PackedScene

var track_positions = [
	Vector2(150, 600),
	Vector2(350, 600),
	Vector2(550, 600),
	Vector2(750, 600)
]

var connected_players = []
var game_started = false


func _on_btn_host_pressed() -> void:
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(connect_player)
	$CanvasLayer/HBoxContainer/BtnHost.hide()
	$CanvasLayer/HBoxContainer/BtnJoin.hide()
	print("Server avviato. In attesa di giocatori...")
	

func connect_player(id):
	if game_started or connected_players.size() >= MAXPLAYER:
		print("Server pieno!")
		return
	for i in range(connected_players.size()):
		spawn_runner_on_all.rpc_id(id, connected_players[i], i, false)
	
	if game_started:
		for i in range(connected_players.size(), MAXPLAYER):
			spawn_runner_on_all.rpc_id(id, 1000 + i, i, true)
	var index = connected_players.size()
	connected_players.append(id)
	spawn_runner_on_all.rpc(id, index, false)
	print("Giocatore ", id, " connesso alla corsia ", index)

func bots():
	if game_started: return
	game_started = true
	
	for i in range(connected_players.size(), MAXPLAYER):
		var bot_id = 1000+i
		spawn_runner_on_all.rpc(bot_id, i, true) 
		
		

@rpc("call_local", "authority", "reliable")
func spawn_runner_on_all(id: int, index: int, is_bot: bool):
	runner_spawn(id, index, is_bot)

func runner_spawn(id: int, index: int, is_bot: bool):
	var runner = player_scene.instantiate()
	runner.name = str(id)
	runner.position = track_positions[index]
	runner.is_bot = is_bot
	if is_bot:
		runner.set_multiplayer_authority(1)
	else:
		runner.set_multiplayer_authority(id)  
	$Level.add_child(runner)                   
	
func _on_btn_join_pressed():
	peer.create_client("127.0.0.1", PORT)
	multiplayer.multiplayer_peer = peer
	$CanvasLayer.hide()
	

func _ready() -> void:
	if OS.get_cmdline_args().has("--server"):
		_on_btn_host_pressed()
		
		
func _input(event):
	if multiplayer.is_server() and event.is_action_pressed("ui_accept"):
		bots()
		print("Gara iniziata!")
