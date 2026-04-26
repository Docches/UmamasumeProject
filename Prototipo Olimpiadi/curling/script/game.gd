extends Node2D

enum GameState { REVEAL, PLAYING, GAME_OVER }
var current_state: GameState = GameState.REVEAL

@export var stone_team_1: PackedScene
@export var stone_team_2: PackedScene

@onready var house_center: Marker2D = $HouseCenter
@onready var turn_label: Label = $UI/HBoxContainer/TurnLabel
@onready var stones_label: Label = $UI/HBoxContainer/StonesLabel
@onready var score_label: Label = $UI/HBoxContainer/ScoreLabel

@onready var team_reveal_label: Label = $UI/TeamRevealLabel
@onready var countdown_label: Label = $UI/CountdownLabel
@onready var winner_label: Label = $UI/WinnerLabel

# --- NODI VISIVI ---
@onready var role_label: Label = get_node_or_null("UI/RoleLabel")
@onready var scopa_sprite: Sprite2D = get_node_or_null("ScopaSprite")

var score_team_1: int = 0
var score_team_2: int = 0

var current_stone: RigidBody2D = null
var active_stone: RigidBody2D = null 
var check_stop: bool = false 

var clicked = false
var initialPosition: Vector2
const MAX_POWER: float = 700.0
const SWEEP_FORCE: float = 6.0 
const MAX_SWEEP_SPEED: float = 12.0 
var current_impulse: Vector2 = Vector2.ZERO

var current_turn: int = 0 
var stones_thrown: int = 0
const MAX_STONES: int = 6
const HOUSE_RADIUS: float = 250.0
const ICE_DAMPING: float = 0.8

var teams = [[], []]
var game_started = false
var bot_timer: float = 2.0
var time_since_throw: float = 0.0 

func _ready() -> void:
	randomize()
	
	if scopa_sprite:
		scopa_sprite.hide()
	
	# PREVENZIONE CRASH (Test F6)
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: Avvio Standalone Curling. Generazione Bot in corso...")
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else "BOT"})
			
	team_reveal_label.hide()
	countdown_label.hide()
	if winner_label: winner_label.hide()
	
	aggiorna_ui()
	
	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout 
		_server_assign_teams()

# --- 1. ASSEGNAZIONE E REVEAL ---

func _server_assign_teams():
	var players_indices = [0, 1, 2, 3]
	players_indices.shuffle()
	
	var t1 = [{"index": players_indices[0], "role": "Lanciatore"}, {"index": players_indices[1], "role": "Spazzatore"}]
	var t2 = [{"index": players_indices[2], "role": "Lanciatore"}, {"index": players_indices[3], "role": "Spazzatore"}]
	
	client_sync_teams.rpc(t1, t2)

@rpc("call_local", "authority", "reliable")
func client_sync_teams(t1: Array, t2: Array):
	teams[0] = t1
	teams[1] = t2
	current_state = GameState.REVEAL
	
	var my_id = multiplayer.get_unique_id()
	var my_team_str = ""
	
	for p in t1:
		if GlobalData.players_data[p["index"]]["id"] == my_id and not GlobalData.players_data[p["index"]].get("is_bot", false):
			my_team_str = "\n< SEI NEL TEAM 1 (ROSSO) >"
	for p in t2:
		if GlobalData.players_data[p["index"]]["id"] == my_id and not GlobalData.players_data[p["index"]].get("is_bot", false):
			my_team_str = "\n< SEI NEL TEAM 2 (GIALLO) >"

	var text = "--- KURLING CHAOS ---\n\n"
	text += "[ TEAM 1 (Rosso) ]\n" + _get_player_info(t1[0]) + "\n" + _get_player_info(t1[1]) + "\n\n"
	text += "[ TEAM 2 (Giallo) ]\n" + _get_player_info(t2[0]) + "\n" + _get_player_info(t2[1]) + "\n"
	text += my_team_str + "\n\n"
	text += "LANCIATORE: Trascina e Rilascia.\nSPAZZATORE: W/S o Frecce Su/Giu in corsa."
	
	team_reveal_label.text = text
	team_reveal_label.show()
	countdown_label.show()
	
	_play_countdown()

# --- INTEGRAZIONE NICKNAME (CURLING) ---
func _get_player_info(player_data: Dictionary) -> String:
	var p_index = player_data["index"]
	var p_data = GlobalData.players_data[p_index]
	
	var name = p_data.get("name", "Giocatore")
	if p_data.get("is_bot", false) and not name.begins_with("BOT"):
		name += " (BOT)"
		
	return "- " + player_data["role"] + ": " + name

func _play_countdown():
	for i in range(8, 0, -1):
		countdown_label.text = "Inizio tra: " + str(i)
		await get_tree().create_timer(1.0).timeout
		
	team_reveal_label.hide()
	countdown_label.hide()
	
	if multiplayer.is_server():
		client_start_turn.rpc(0, 0)

@rpc("call_local", "authority", "reliable")
func client_start_turn(turn: int, thrown: int):
	current_state = GameState.PLAYING
	game_started = true
	current_turn = turn
	stones_thrown = thrown
	bot_timer = 2.0
	time_since_throw = 0.0
	
	check_stop = false
	clicked = false
	
	aggiorna_ui()
	_spawn_stone_local()

# --- 2. INPUT CLIENT -> SERVER ---

func _unhandled_input(event: InputEvent) -> void:
	if not game_started or current_state != GameState.PLAYING: return
	
	var current_team = teams[current_turn]
	var my_id = multiplayer.get_unique_id()
	
	var t_data = GlobalData.players_data[current_team[0]["index"]]
	var s_data = GlobalData.players_data[current_team[1]["index"]]
	
	var is_thrower = (t_data["id"] == my_id and not t_data.get("is_bot", false))
	var is_sweeper = (s_data["id"] == my_id and not s_data.get("is_bot", false))

	if is_thrower and not check_stop and current_stone != null:
		if event.is_action_pressed("action"):
			clicked = true
			initialPosition = get_global_mouse_position()
		elif event.is_action_released("action") and clicked:
			clicked = false
			queue_redraw()
			server_request_throw.rpc_id(1, current_impulse)
		elif event is InputEventMouseMotion and clicked:
			current_impulse = (initialPosition - get_global_mouse_position()) * 2.0
			if current_impulse.length() > MAX_POWER:
				current_impulse = current_impulse.normalized() * MAX_POWER
			queue_redraw()

	if is_sweeper and check_stop:
		if event.is_action_pressed("ui_up"): 
			server_request_sweep.rpc_id(1, Vector2(0, -1))
		elif event.is_action_pressed("ui_down"): 
			server_request_sweep.rpc_id(1, Vector2(0, 1))

@rpc("any_peer", "call_local", "reliable")
func server_request_throw(impulse: Vector2):
	if not multiplayer.is_server(): return
	var sender = multiplayer.get_remote_sender_id()
	if GlobalData.players_data[teams[current_turn][0]["index"]]["id"] != sender: return
	_server_execute_throw(impulse)

@rpc("any_peer", "call_local", "reliable")
func server_request_sweep(dir: Vector2):
	if not multiplayer.is_server(): return
	var sender = multiplayer.get_remote_sender_id()
	if GlobalData.players_data[teams[current_turn][1]["index"]]["id"] != sender: return
	_server_execute_sweep(dir)

# --- 3. FISICA SERVER-SIDE E BOT ---

func _server_execute_throw(impulse: Vector2):
	if current_stone:
		current_stone.sleeping = false 
		current_stone.apply_central_impulse(impulse)
		active_stone = current_stone
		current_stone = null
		check_stop = true
		time_since_throw = 0.0
		client_notify_throw.rpc()

@rpc("authority", "call_local", "reliable")
func client_notify_throw():
	current_stone = null
	check_stop = true
	clicked = false
	queue_redraw()

func _server_execute_sweep(dir: Vector2):
	if active_stone:
		active_stone.sleeping = false
		active_stone.apply_central_impulse(dir * SWEEP_FORCE)
		var c_vel = active_stone.linear_velocity
		c_vel.y = clamp(c_vel.y, -MAX_SWEEP_SPEED, MAX_SWEEP_SPEED)
		active_stone.linear_velocity = c_vel
		
		client_show_sweep_effect.rpc(dir, active_stone.global_position)

@rpc("authority", "call_local", "unreliable")
func client_show_sweep_effect(dir: Vector2, stone_pos: Vector2):
	if scopa_sprite == null: return
	
	scopa_sprite.global_position = stone_pos + (dir * 30.0)
	scopa_sprite.modulate.a = 1.0 
	scopa_sprite.show()
	
	var tween = create_tween().set_parallel(true)
	tween.tween_property(scopa_sprite, "global_position", stone_pos + (dir * 55.0), 0.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(scopa_sprite, "modulate:a", 0.0, 0.3).set_delay(0.1)
	
	tween.chain().tween_callback(scopa_sprite.hide)

func _physics_process(delta: float) -> void:
	if current_state != GameState.PLAYING: return
	
	if multiplayer.is_server():
		_handle_bots(delta)
		
		var all_stones = get_tree().get_nodes_in_group("stones")
		var pos_arr = []
		var rot_arr = []
		for s in all_stones:
			pos_arr.append(s.global_position)
			rot_arr.append(s.rotation)
			
		client_sync_stones.rpc(pos_arr, rot_arr)
		
		if check_stop and active_stone != null:
			time_since_throw += delta 
			if time_since_throw > 0.5 and active_stone.linear_velocity.length() < 5.0:
				active_stone.linear_velocity = Vector2.ZERO
				_server_end_turn()

@rpc("authority", "call_local", "unreliable")
func client_sync_stones(pos_arr: Array, rot_arr: Array):
	var all_stones = get_tree().get_nodes_in_group("stones")
	for i in range(min(all_stones.size(), pos_arr.size())):
		if is_instance_valid(all_stones[i]):
			all_stones[i].global_position = pos_arr[i]
			all_stones[i].rotation = rot_arr[i]

func _handle_bots(delta: float):
	if current_stone == null and active_stone == null: return
	var current_team = teams[current_turn]
	var t_data = GlobalData.players_data[current_team[0]["index"]]
	
	if current_stone != null and not check_stop and t_data.get("is_bot", false):
		bot_timer -= delta
		if bot_timer <= 0:
			var rand_impulse = Vector2(MAX_POWER * randf_range(0.5, 0.9), randf_range(-120, 120))
			_server_execute_throw(rand_impulse)
			
	var s_data = GlobalData.players_data[current_team[1]["index"]]
	if active_stone != null and check_stop and s_data.get("is_bot", false):
		if randf() < 0.15: 
			var rand_sweep = Vector2(0, randf_range(-1.0, 1.0))
			_server_execute_sweep(rand_sweep) 

# --- 4. GESTIONE TURNI E SPAWN ---

func _server_end_turn():
	check_stop = false
	active_stone = null
	stones_thrown += 1
	
	if stones_thrown >= MAX_STONES:
		_server_calculate_score()
	else:
		current_turn = 1 if current_turn == 0 else 0
		client_start_turn.rpc(current_turn, stones_thrown)

func _spawn_stone_local() -> void:
	if current_state == GameState.GAME_OVER: return 
		
	var scene = stone_team_1 if current_turn == 0 else stone_team_2
	current_stone = scene.instantiate()
	current_stone.add_to_group("stones")
	current_stone.set_meta("team", current_turn) 
	current_stone.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	current_stone.linear_damp = ICE_DAMPING
	
	if not multiplayer.is_server():
		current_stone.freeze = true
	
	add_child(current_stone)
	current_stone.position = Vector2(100, 360)

func _draw() -> void:
	if clicked and current_stone != null:
		var num_punti = 6 
		var dot_color = Color.RED if current_turn == 0 else Color.YELLOW
		for i in range(1, num_punti + 1):
			var frazione = float(i) / float(num_punti)
			var punto_pos = current_stone.position + (current_impulse * frazione)
			draw_circle(punto_pos, 4.0, dot_color)

# --- 5. FINE PARTITA ---

func _server_calculate_score() -> void:
	var all_stones = get_tree().get_nodes_in_group("stones")
	var valide = []
	
	for s in all_stones:
		var dist = s.global_position.distance_to(house_center.global_position)
		if dist <= HOUSE_RADIUS:
			valide.append({"dist": dist, "team": s.get_meta("team")})
			
	if not valide.is_empty():
		valide.sort_custom(func(a, b): return a["dist"] < b["dist"])
		var team_vincente = valide[0]["team"]
		var punti = 0
		for s in valide:
			if s["team"] == team_vincente: punti += 1
			else: break 
				
		if team_vincente == 0: score_team_1 += punti
		else: score_team_2 += punti
			
	client_sync_scores.rpc(score_team_1, score_team_2)

	current_state = GameState.GAME_OVER 
	var winners = [] 
	var msg = ""
	
	if score_team_1 > score_team_2:
		winners = [teams[0][0]["index"], teams[0][1]["index"]]
		msg = "Vittoria TEAM 1!\n" + _get_team_string(teams[0])
	elif score_team_2 > score_team_1:
		winners = [teams[1][0]["index"], teams[1][1]["index"]]
		msg = "Vittoria TEAM 2!\n" + _get_team_string(teams[1])
	else:
		msg = "PAREGGIO!\nNessun passo bonus."
		
	GlobalData.minigame_winners = winners
	client_show_winner.rpc(msg)
	
	await get_tree().create_timer(5.0).timeout
	client_change_scene.rpc()

func _get_team_string(t_array: Array) -> String:
	var s = ""
	for p in t_array:
		var p_data = GlobalData.players_data[p["index"]]
		var nome = p_data.get("name", "Giocatore")
		if p_data.get("is_bot", false) and not nome.begins_with("BOT"):
			nome += " (BOT)"
		s += nome + "\n"
	return s

@rpc("authority", "call_local", "reliable")
func client_sync_scores(s1: int, s2: int):
	score_team_1 = s1
	score_team_2 = s2
	aggiorna_ui()

func aggiorna_ui() -> void:
	turn_label.text = "Turno: " + ("Team 1" if current_turn == 0 else "Team 2")
	stones_label.text = " | Stones rimaste: " + str(MAX_STONES - stones_thrown) + " | "
	score_label.text = "Punti: T1 [" + str(score_team_1) + "] - T2 [" + str(score_team_2) + "]"
	
	if role_label and not teams[0].is_empty():
		var my_id = multiplayer.get_unique_id()
		var my_role_text = "Spettatore"
		
		for t_idx in range(teams.size()):
			var nome_team = "TEAM 1 (Rosso)" if t_idx == 0 else "TEAM 2 (Giallo)"
			
			for p in teams[t_idx]:
				if GlobalData.players_data[p["index"]]["id"] == my_id and not GlobalData.players_data[p["index"]].get("is_bot", false):
					var stato = " (TURNO TUO!)" if current_turn == t_idx else " (In attesa...)"
					my_role_text = nome_team + " | Ruolo: " + p["role"] + stato
					
		role_label.text = my_role_text

@rpc("authority", "call_local", "reliable")
func client_show_winner(msg: String):
	if winner_label:
		winner_label.text = msg
		winner_label.show()

@rpc("authority", "call_local", "reliable")
func client_change_scene():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
