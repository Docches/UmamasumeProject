extends Node2D

enum GameState { INSTRUCTIONS, WAITING, PLAYING, FINISHED }
var current_state = GameState.INSTRUCTIONS

@onready var giocatori_nodes = [
	get_node_or_null("Giocatori/P0"),
	get_node_or_null("Giocatori/P1"),
	get_node_or_null("Giocatori/P2"),
	get_node_or_null("Giocatori/P3")
]
@onready var info_label = $UI/InfoLabel
@onready var qte_label = $UI/QTELabel
@onready var feedback_panel = $UI/FeedbackPanel
@onready var istruzioni_panel = $UI/IstruzioniPanel

# Setup Caselle
const START_X: float = 100.0
const STEP_DISTANCE: float = 95.0 
const MAX_STEPS: int = 10

var player_steps: Array[int] = [0, 0, 0, 0] 
var visual_steps: Array[int] = [0, 0, 0, 0] 
var bot_timers: Array[float] = [0.0, 0.0, 0.0, 0.0]

# Gestione QTE INDIVIDUALE E ISOLATA
var current_qte_seq: Array[String] = []
var local_qte_idx: int = 0
var local_predicted_step: int = 0 
var my_slot: int = -1

func _ready():
	_fix_lobby_data()
	
	_setup_game()
	_crea_griglia_visiva()
	_reset_animations()
	
	if multiplayer.is_server():
		_show_instructions_sequence()

# --- RIPARAZIONE AUTOMATICA DEI DATI DELLA LOBBY ---
# Assicura che i bot siano attivi e rinominati, anche se la Lobby non lo fa.
func _fix_lobby_data():
	if GlobalData.players_data.is_empty():
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else ""})
	else:
		if multiplayer.is_server():
			var connected_peers = multiplayer.get_peers()
			for i in range(GlobalData.players_data.size()):
				var p_id = GlobalData.players_data[i].get("id", -1)
				# Se l'ID non è 1 (il server) e non è in multiplayer... è un Bot!
				if p_id != 1 and not p_id in connected_peers:
					GlobalData.players_data[i]["is_bot"] = true

func _crea_griglia_visiva():
	for i in range(1, MAX_STEPS + 1):
		var linea = ColorRect.new()
		linea.color = Color(1, 1, 1, 0.2)
		if i == MAX_STEPS: 
			linea.color = Color(1, 0.8, 0.0, 0.6) 
		linea.size = Vector2(4, 650)
		linea.position = Vector2(START_X + (i * STEP_DISTANCE), 0)
		add_child(linea)
		move_child(linea, 1)

# --- ASSEGNAZIONE NICKNAME E BOT ---
func _setup_game():
	var id = multiplayer.get_unique_id()
	var bot_count = 1
	
	for i in range(GlobalData.players_data.size()):
		var p_data = GlobalData.players_data[i]
		if giocatori_nodes[i]:
			giocatori_nodes[i].position.x = START_X
			var label = giocatori_nodes[i].get_node_or_null("NameLabel")
			if label:
				var is_bot = p_data.get("is_bot", false)
				
				# Logica Assegnazione Nomi (Bot o Real)
				if is_bot:
					label.text = "BOT " + str(bot_count)
					bot_count += 1
				else:
					var p_name = p_data.get("name", "")
					# Fallback se il nome è vuoto o generico
					if p_name == "" or p_name.begins_with("Giocatore"):
						p_name = "Player " + str(i+1)
					label.text = p_name
				
				# Evidenzia il giocatore locale (Usa modulate perché scavalca LabelSettings)
				if p_data.get("id") == id and not is_bot:
					my_slot = i
					label.modulate = Color(1, 1, 0) # Giallo acceso
				else:
					label.modulate = Color(1, 1, 1) # Bianco

func _reset_animations():
	for p in giocatori_nodes:
		if p != null and p is AnimatedSprite2D:
			if p.sprite_frames.has_animation("idle"):
				p.play("idle")

# --- LOGICA SERVER ---
func _show_instructions_sequence():
	current_state = GameState.INSTRUCTIONS
	client_toggle_instructions.rpc(true)
	await get_tree().create_timer(7.0).timeout
	client_toggle_instructions.rpc(false)
	_start_game_sequence()

func _start_game_sequence():
	current_state = GameState.WAITING
	for m in ["PRONTI", "3", "2", "1", "VIA!"]:
		client_update_info.rpc(m)
		await get_tree().create_timer(1.0).timeout
	
	current_state = GameState.PLAYING
	client_start_game.rpc()
	
	for i in range(4):
		if GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] = _calcola_tempo_bot(0)

func _process(delta: float):
	if not multiplayer.is_server() or current_state != GameState.PLAYING: return
	
	for i in range(4):
		if GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] -= delta
			if bot_timers[i] <= 0:
				player_steps[i] += 1
				client_sync_steps.rpc(player_steps)
				
				if player_steps[i] >= MAX_STEPS:
					_declare_winner(i)
					return
				
				bot_timers[i] = _calcola_tempo_bot(player_steps[i])

func _calcola_tempo_bot(step_attuale: int) -> float:
	var frecce_da_premere = step_attuale + 1 
	return frecce_da_premere * randf_range(0.35, 0.55)

# --- INPUT E LOGICA CLIENT (QTE ISOLATO) ---
func _unhandled_input(event):
	if my_slot == -1 or current_state != GameState.PLAYING: return
	
	var keys = ["up", "down", "left", "right"]
	for k in keys:
		if event.is_action_pressed(k):
			_process_qte_input(k)

func _process_qte_input(key: String):
	if key == current_qte_seq[local_qte_idx]:
		local_qte_idx += 1
		_update_qte_label(local_predicted_step)
		
		if local_qte_idx >= current_qte_seq.size():
			server_apply_result.rpc_id(1, true)
			local_predicted_step += 1
			
			if local_predicted_step >= MAX_STEPS:
				current_qte_seq.clear()
				qte_label.text = "ATTESA..."
			else:
				_generate_new_qte(local_predicted_step)
				
			_flash_feedback(Color.GREEN)
	else:
		server_apply_result.rpc_id(1, false)
		local_predicted_step = max(0, local_predicted_step - 1)
		_generate_new_qte(local_predicted_step)
		_flash_feedback(Color.RED)

func _generate_new_qte(step_for_length: int):
	current_qte_seq.clear()
	var keys = ["up", "down", "left", "right"]
	var num_frecce = step_for_length + 1
	
	for i in range(num_frecce):
		current_qte_seq.append(keys.pick_random())
	
	local_qte_idx = 0
	_update_qte_label(step_for_length)

# --- RPC E SINCRONIZZAZIONE ---
@rpc("any_peer", "call_local", "reliable")
func server_apply_result(success: bool):
	if not multiplayer.is_server(): return
	var id = multiplayer.get_remote_sender_id()
	if id == 0: id = 1 
	
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == id:
			if success:
				player_steps[i] += 1
				if player_steps[i] >= MAX_STEPS:
					client_sync_steps.rpc(player_steps)
					_declare_winner(i)
					return
			else:
				player_steps[i] = max(0, player_steps[i] - 1)
			
			client_sync_steps.rpc(player_steps)

@rpc("authority", "call_local", "reliable")
func client_sync_steps(steps: Array):
	player_steps.assign(steps)
	
	for i in range(4):
		var old_step = visual_steps[i] 
		var new_step = steps[i]
		
		if old_step != new_step:
			visual_steps[i] = new_step 
			
			var target_x = START_X + (new_step * STEP_DISTANCE)
			
			if giocatori_nodes[i]:
				var tween = create_tween()
				tween.tween_property(giocatori_nodes[i], "position:x", target_x, 0.25)
				
				if new_step > old_step:
					_play_anim_safe(i, "run")
					tween.tween_callback(func(): _play_anim_safe(i, "idle"))
				elif new_step < old_step:
					_play_anim_safe(i, "stumble")
					tween.tween_callback(func(): _play_anim_safe(i, "idle"))

func _play_anim_safe(slot: int, anim: String):
	var node = giocatori_nodes[slot]
	if node and node is AnimatedSprite2D:
		if node.sprite_frames.has_animation(anim):
			node.play(anim)
		else:
			node.play("idle")

@rpc("authority", "call_local", "reliable")
func client_toggle_instructions(show: bool):
	if istruzioni_panel: istruzioni_panel.visible = show
	info_label.text = "ROAD TO THE TOP" if show else ""

@rpc("authority", "call_local", "reliable")
func client_update_info(msg: String):
	info_label.text = msg

@rpc("authority", "call_local", "reliable")
func client_start_game():
	current_state = GameState.PLAYING
	info_label.text = ""
	feedback_panel.visible = true
	if my_slot != -1:
		local_predicted_step = 0
		visual_steps = [0, 0, 0, 0] 
		_generate_new_qte(0)

func _update_qte_label(step_attuale: int):
	var s = ""
	for i in range(current_qte_seq.size()):
		var f = {"up":"↑","down":"↓","left":"←","right":"→"}[current_qte_seq[i]]
		s += "[OK] " if i < local_qte_idx else f + " "
	
	qte_label.text = "Passo " + str(step_attuale + 1) + "/" + str(MAX_STEPS) + "\n" + s

func _flash_feedback(color: Color):
	feedback_panel.color = color
	feedback_panel.color.a = 0.8
	create_tween().tween_property(feedback_panel, "color:a", 0.0, 0.3)

func _declare_winner(i: int):
	current_state = GameState.FINISHED
	var p_data = GlobalData.players_data[i]
	
	var nome = "BOT " if p_data.get("is_bot", false) else p_data.get("name", "Giocatore")
	if p_data.get("is_bot", false):
		var bot_count = 1
		for j in range(i):
			if GlobalData.players_data[j].get("is_bot", false): bot_count += 1
		nome += str(bot_count)
		
	client_update_info.rpc("🏆 " + nome + " VINCE L'ORO! 🏆")
	qte_label.text = ""
	GlobalData.minigame_winners = [i]
	await get_tree().create_timer(3.5).timeout
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
