extends Node2D

enum GameState { PLAYING, GAME_OVER }
var current_state: GameState = GameState.PLAYING

@export var stone_team_1: PackedScene
@export var stone_team_2: PackedScene

@onready var house_center: Marker2D = $HouseCenter
@onready var turn_label: Label = $UI/HBoxContainer/TurnLabel
@onready var stones_label: Label = $UI/HBoxContainer/StonesLabel
@onready var score_label: Label = $UI/HBoxContainer/ScoreLabel
@onready var team_reveal_label: Label = $UI/TeamRevealLabel

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

#VARIABILI MULTIPLAYER
var teams = [[], []]
var game_started = false
var bot_timer: float = 2.0
var time_since_throw: float = 0.0 

func _ready() -> void:
	aggiorna_ui()
	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout 
		assign_teams_and_roles()

func assign_teams_and_roles():
	var players_indices = [0, 1, 2, 3]
	players_indices.shuffle()
	
	var t1 = [{"index": players_indices[0], "role": "Lanciatore"}, {"index": players_indices[1], "role": "Spazzatore"}]
	var t2 = [{"index": players_indices[2], "role": "Lanciatore"}, {"index": players_indices[3], "role": "Spazzatore"}]
	
	sync_teams.rpc(t1, t2)

@rpc("call_local", "authority")
func sync_teams(t1: Array, t2: Array):
	teams[0] = t1
	teams[1] = t2
	
	var text = "--- FORMAZIONI ---\n\n"
	text += "[ TEAM 1 (Rosso) ]\n" + get_player_name_and_role(t1[0]) + "\n" + get_player_name_and_role(t1[1]) + "\n\n"
	text += "[ TEAM 2 (Giallo) ]\n" + get_player_name_and_role(t2[0]) + "\n" + get_player_name_and_role(t2[1]) + "\n"
	
	team_reveal_label.text = text
	team_reveal_label.show()
	
	await get_tree().create_timer(5.0).timeout
	team_reveal_label.hide()
	
	if multiplayer.is_server():
		start_turn_rpc.rpc(0, 0)

func get_player_name_and_role(player_data: Dictionary) -> String:
	var p_index = player_data["index"]
	var p_global_data = GlobalData.players_data[p_index]
	var name = "Giocatore " + str(p_index + 1)
	if p_global_data["is_bot"]: name += " (BOT)"
	return "- " + player_data["role"] + ": " + name

@rpc("call_local", "authority")
func start_turn_rpc(turn: int, thrown: int):
	game_started = true
	current_turn = turn
	stones_thrown = thrown
	bot_timer = 2.0
	time_since_throw = 0.0
	
	check_stop = false
	clicked = false
	
	aggiorna_ui()
	spawn_stone()

#GESTIONE INPUT MULTIPLAYER
func _input(event: InputEvent) -> void:
	if not game_started or current_state == GameState.GAME_OVER or current_stone == null: return
	
	var current_team = teams[current_turn]
	var my_id = multiplayer.get_unique_id()
	
	var thrower_data = GlobalData.players_data[current_team[0]["index"]]
	var sweeper_data = GlobalData.players_data[current_team[1]["index"]]
	
	var am_i_thrower = (thrower_data["id"] == my_id and not thrower_data["is_bot"])
	var am_i_sweeper = (sweeper_data["id"] == my_id and not sweeper_data["is_bot"])

	if am_i_thrower and not check_stop:
		if event.is_action_pressed("action"):
			clicked = true
			initialPosition = get_global_mouse_position()
		elif event.is_action_released("action") and clicked:
			clicked = false
			queue_redraw()
			request_throw.rpc_id(1, current_impulse)
		elif event is InputEventMouseMotion and clicked:
			var currentPosition = get_global_mouse_position()
			current_impulse = (initialPosition - currentPosition) * 2.0
			if current_impulse.length() > MAX_POWER:
				current_impulse = current_impulse.normalized() * MAX_POWER
			queue_redraw()

	if am_i_sweeper and check_stop:
		if event.is_action_pressed("up"):
			request_sweep.rpc_id(1, Vector2(0, -1))
		elif event.is_action_pressed("down"):
			request_sweep.rpc_id(1, Vector2(0, 1))

# RISOLTO: Ora call_local permette anche all'Host di giocare i propri turni!
@rpc("any_peer", "call_local")
func request_throw(impulse: Vector2):
	if multiplayer.is_server():
		execute_throw.rpc(impulse)

@rpc("call_local", "authority")
func execute_throw(impulse: Vector2):
	if current_stone:
		if multiplayer.is_server():
			current_stone.sleeping = false # SVEGLIA! Così non ignora l'impulso.
			current_stone.apply_central_impulse(impulse)
		active_stone = current_stone
		current_stone = null
		check_stop = true
		time_since_throw = 0.0

@rpc("any_peer", "call_local")
func request_sweep(dir: Vector2):
	if multiplayer.is_server():
		execute_sweep(dir)

func execute_sweep(dir: Vector2):
	if active_stone:
		active_stone.sleeping = false
		active_stone.apply_central_impulse(dir * SWEEP_FORCE)
		
		var current_vel = active_stone.linear_velocity
		current_vel.y = clamp(current_vel.y, -MAX_SWEEP_SPEED, MAX_SWEEP_SPEED)
		active_stone.linear_velocity = current_vel
		
#FISICA E BOT
func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not game_started or current_state == GameState.GAME_OVER: 
		return
	
	if multiplayer.is_server():
		handle_bots(delta)
		
		# NUOVO SISTEMA DI SYNC: Aggiorniamo tutte le pietre in un colpo solo!
		var all_stones = get_tree().get_nodes_in_group("stones")
		var pos_array = []
		var rot_array = []
		for s in all_stones:
			pos_array.append(s.global_position)
			rot_array.append(s.rotation)
		sync_all_stones.rpc(pos_array, rot_array)
		
		if check_stop and active_stone != null:
			time_since_throw += delta 
			if time_since_throw > 0.5 and active_stone.linear_velocity.length() < 5.0:
				active_stone.linear_velocity = Vector2.ZERO
				end_turn_server()

# Aggiorniamo le posizioni sul Client
@rpc("unreliable", "call_remote", "authority")
func sync_all_stones(pos_array: Array, rot_array: Array):
	var all_stones = get_tree().get_nodes_in_group("stones")
	for i in range(min(all_stones.size(), pos_array.size())):
		all_stones[i].global_position = pos_array[i]
		all_stones[i].rotation = rot_array[i]

func handle_bots(delta: float):
	if current_stone == null and active_stone == null: return
	var current_team = teams[current_turn]
	
	if current_stone != null and not check_stop and GlobalData.players_data[current_team[0]["index"]]["is_bot"]:
		bot_timer -= delta
		if bot_timer <= 0:
			var random_impulse = Vector2(MAX_POWER * randf_range(0.5, 0.9), randf_range(-120, 120))
			execute_throw.rpc(random_impulse)
			
	if active_stone != null and check_stop and GlobalData.players_data[current_team[1]["index"]]["is_bot"]:
		if randf() < 0.2: 
			var random_sweep = Vector2(0, randf_range(-1.0, 1.0))
			execute_sweep(random_sweep) 

func end_turn_server():
	check_stop = false
	active_stone = null
	stones_thrown += 1
	
	if stones_thrown >= MAX_STONES:
		calcola_punteggio_rpc.rpc()
	else:
		current_turn = 1 if current_turn == 0 else 0
		start_turn_rpc.rpc(current_turn, stones_thrown)

@rpc("call_local", "authority")
func calcola_punteggio_rpc():
	calcola_punteggio()

func spawn_stone() -> void:
	if current_state == GameState.GAME_OVER:
		return 
		
	if stone_team_1 == null or stone_team_2 == null:
		push_error("Assegna entrambe le scene delle stone nell'Inspector.")
		return
		
	var scene_to_spawn: PackedScene
	if current_turn == 0:
		scene_to_spawn = stone_team_1
	else:
		scene_to_spawn = stone_team_2
		
	current_stone = scene_to_spawn.instantiate()
	current_stone.add_to_group("stones")
	current_stone.set_meta("team", current_turn) 
	
	current_stone.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	current_stone.linear_damp = ICE_DAMPING
	
	# TRUCCO MAGICO: Il Client congela la pietra, diventando un puro spettatore visivo!
	if not multiplayer.is_server():
		current_stone.freeze = true
	
	add_child(current_stone)
	
	var screen_size = get_viewport_rect().size
	current_stone.position = Vector2(100, screen_size.y / 2.0)
	
func aggiorna_ui() -> void:
	var nome_team = "Team 1 (Rosso)" if current_turn == 0 else "Team 2 (Giallo)"
	turn_label.text = "Turno: " + nome_team
	
	var rimanenti = MAX_STONES - stones_thrown
	stones_label.text = " | Stones rimanenti: " + str(rimanenti) + " | "
	
	score_label.text = "Punteggio: T1 [" + str(score_team_1) + "] - T2 [" + str(score_team_2) + "]"

func _draw() -> void:
	if clicked and current_stone != null:
		var num_punti = 6 
		var dot_color = Color.RED if current_turn == 0 else Color.YELLOW
			
		for i in range(1, num_punti + 1):
			var frazione = float(i) / float(num_punti)
			var punto_pos = current_stone.position + (current_impulse * frazione)
			
			draw_circle(punto_pos, 4.0, dot_color)

func calcola_punteggio() -> void:
	var all_stones = get_tree().get_nodes_in_group("stones")
	var stone_valide = []
	
	print("--- CALCOLO PUNTEGGIO ---")
	print("Il centro bersaglio (HouseCenter) si trova alle coordinate: ", house_center.global_position)
	
	for s in all_stones:
		var distanza = s.global_position.distance_to(house_center.global_position)
		print("Pietra del team ", s.get_meta("team"), " trovata a distanza: ", distanza)
		
		if distanza <= HOUSE_RADIUS:
			stone_valide.append({"nodo": s, "distanza": distanza, "team": s.get_meta("team")})
			
	if not stone_valide.is_empty():
		stone_valide.sort_custom(func(a, b): return a["distanza"] < b["distanza"])
		var team_vincente = stone_valide[0]["team"]
		var punti = 0
		for s in stone_valide:
			if s["team"] == team_vincente:
				punti += 1
			else:
				break 
				
		if team_vincente == 0:
			score_team_1 += punti
		else:
			score_team_2 += punti
	else:
		print("Nessuna pietra era dentro il raggio di ", HOUSE_RADIUS)
			
	aggiorna_ui()

	if multiplayer.is_server():
		current_state = GameState.GAME_OVER 
		var winning_team_indices: Array[int] = [] 
		
		if score_team_1 > score_team_2:
			winning_team_indices = [teams[0][0]["index"], teams[0][1]["index"]]
			print("Vince il Team 1!")
		elif score_team_2 > score_team_1:
			winning_team_indices = [teams[1][0]["index"], teams[1][1]["index"]]
			print("Vince il Team 2!")
		else:
			print("Pareggio! Nessun bonus assegnato.")
			
		GlobalData.minigame_winners = winning_team_indices
		await get_tree().create_timer(4.0).timeout
		
		cambia_scena_rpc.rpc()

@rpc("call_local", "authority")
func cambia_scena_rpc():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
