extends Control

@export var player_scene: PackedScene

# Riferimenti alla UI
@onready var buttons = [$UI/BtnHorse0, $UI/BtnHorse1, $UI/BtnHorse2, $UI/BtnHorse3]
@onready var labels = [$UI/LblHorse0, $UI/LblHorse1, $UI/LblHorse2, $UI/LblHorse3]
@onready var countdown_label = $UI/CountdownLabel
@onready var winner_label = $UI/WinnerLabel

var track_positions = [
	Vector2(100, 75),
	Vector2(100, 250),
	Vector2(100, 400),
	Vector2(100, 550)
]

var horse_owners = [-1, -1, -1, -1] # Salva chi possiede quale cavallo
var humans_to_pick = 0
var humans_picked = 0
var horses = {} 
var finish_order = []

func _ready():
	if multiplayer.is_server():
		# Il server conta quanti umani devono scegliere
		for p in GlobalData.players_data:
			if not p["is_bot"]:
				humans_to_pick += 1
				
	# Colleghiamo i bottoni localmente
	for i in range(4):
		buttons[i].pressed.connect(func(): _on_horse_btn_pressed(i))

func _on_horse_btn_pressed(horse_index: int):
	var my_player_index = -1
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == multiplayer.get_unique_id() and not GlobalData.players_data[i]["is_bot"]:
			my_player_index = i
			break
	
	if my_player_index != -1:
		request_horse.rpc_id(1, my_player_index, horse_index)

# --- LOGICA DI ASSEGNAZIONE ---

@rpc("any_peer", "call_remote")
func request_horse(player_index: int, horse_index: int):
	if multiplayer.is_server():
		if horse_owners[horse_index] == -1 and not (player_index in horse_owners):
			assign_horse_rpc.rpc(horse_index, player_index)
			humans_picked += 1
			
			if humans_picked >= humans_to_pick:
				assign_bots_and_start()

func assign_bots_and_start():
	var bot_indices = []
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["is_bot"]: bot_indices.append(i)
	
	var free_horses = []
	for i in range(4):
		if horse_owners[i] == -1: free_horses.append(i)
	
	free_horses.shuffle()
	for i in range(bot_indices.size()):
		assign_horse_rpc.rpc(free_horses[i], bot_indices[i])
		
	# Invece di partire subito, avviamo il countdown!
	start_countdown_rpc.rpc()

# QUESTA ERA LA FUNZIONE SPARITA!
@rpc("call_local", "authority")
func assign_horse_rpc(horse_index: int, player_index: int):
	horse_owners[horse_index] = player_index
	buttons[horse_index].disabled = true
	
	var p_data = GlobalData.players_data[player_index]
	var text = "Giocatore " + str(player_index + 1)
	if p_data["is_bot"]: text += " (BOT)"
	
	labels[horse_index].text = text
	
	if p_data["id"] == multiplayer.get_unique_id():
		for btn in buttons:
			btn.disabled = true

# --- COUNTDOWN E GARA ---

@rpc("call_local", "authority")
func start_countdown_rpc():
	# Nascondiamo i bottoni di scelta
	for btn in buttons: btn.hide()
	#for lbl in labels: lbl.hide()
	
	countdown_label.show()
	for i in range(3, 0, -1):
		countdown_label.text = str(i)
		await get_tree().create_timer(1.0).timeout
		
	countdown_label.text = "VIA!"
	await get_tree().create_timer(0.5).timeout
	countdown_label.hide()
	
	if multiplayer.is_server():
		start_race_rpc.rpc()

@rpc("call_local", "authority")
func start_race_rpc():
	if multiplayer.is_server():
		for h_idx in range(4):
			spawn_horse_rpc.rpc(h_idx, randf_range(500.0, 750.0), horse_owners[h_idx])

@rpc("call_local", "authority")
func spawn_horse_rpc(track_idx: int, max_speed: float, p_index: int):
	var runner = player_scene.instantiate()
	runner.name = str(p_index)
	runner.position = track_positions[track_idx]
	runner.max_speed = max_speed
	runner.race_manager = self
	runner.set_multiplayer_authority(1)
	add_child(runner)
	horses[p_index] = runner

@rpc("any_peer", "call_local")
func report_finish(p_index: int):
	if p_index in finish_order: return
	
	finish_order.append(p_index)
	var horse = horses.get(p_index, null)
	if horse and multiplayer.is_server():
		horse.stop_horse.rpc()
		
	if finish_order.size() == 4 and multiplayer.is_server():
		show_winner_rpc.rpc(finish_order[0])

@rpc("call_local", "authority")
func show_winner_rpc(winner_index: int):
	$UI.show()
	winner_label.show()
	var p_data = GlobalData.players_data[winner_index]
	var text = "HA VINTO IL GIOCATORE " + str(winner_index + 1)
	if p_data["is_bot"]: text += " (BOT)"
	winner_label.text = text + "!\n+3 Passi Bonus sul Tabellone!"
	
	if multiplayer.is_server():
		GlobalData.minigame_winners = [winner_index]
		await get_tree().create_timer(4.0).timeout
		change_scene_back.rpc()

@rpc("call_local", "authority")
func change_scene_back():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
