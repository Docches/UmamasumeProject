extends Node2D

enum GameState { TUTORIAL, COUNTDOWN, PLAYING, ENDED }
enum ItemType { GATE, BONUS, BOMB }

@onready var giocatori_nodes = [$Giocatori/P0, $Giocatori/P1, $Giocatori/P2, $Giocatori/P3]
@onready var porte_node = $Porte
@onready var info_label = $UI/InfoLabel
@onready var time_label = $UI/TimeLabel
@onready var score_label = $UI/ScorePanel/Text
@onready var tutorial_panel = $UI/TutorialPanel

# Fisica e Stato
const RIVER_SPEED = 180.0
var current_state = GameState.TUTORIAL
var p_pos: Array[Vector2] = []
var p_vel: Array[Vector2] = []
var p_rot: Array[float] = [0.0, 0.0, 0.0, 0.0]

# Gioco
var time_left = 60.0
var last_synced_time = -1 
var scores = [0, 0, 0, 0]
var items_dict = {} 
var item_counter = 0
var item_timer = 0.0
var bot_timers = [0.0, 0.0, 0.0, 0.0]
var my_slot_index = -1

func _ready():
	# PREVENZIONE CRASH: Test Standalone (F6)
	if GlobalData.players_data.is_empty():
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else "BOT"})
			
	_assign_local_slot()
	_imposta_nomi_giocatori()
	
	if multiplayer.is_server():
		for i in range(4):
			p_pos.append(giocatori_nodes[i].position)
			p_vel.append(Vector2.ZERO)
		_avvia_routine_server()
	
	tutorial_panel.show()
	_update_score_ui()

func _assign_local_slot():
	var my_id = multiplayer.get_unique_id()
	for i in range(GlobalData.players_data.size()):
		var p = GlobalData.players_data[i]
		if p["id"] == my_id and not p.get("is_bot", false):
			my_slot_index = i
			break

# --- INTEGRAZIONE NICKNAME UNIVERSALE ---
func _imposta_nomi_giocatori():
	var my_id = multiplayer.get_unique_id()
	for i in range(4):
		if i < GlobalData.players_data.size():
			var p_data = GlobalData.players_data[i]
			var label = giocatori_nodes[i].get_node_or_null("NameLabel")
			
			if label:
				label.text = p_data.get("name", "Giocatore " + str(i+1))
				
				if p_data.get("is_bot", false) and not label.text.begins_with("BOT"):
					label.text += " (BOT)"
				
				if p_data.get("id") == my_id and not p_data.get("is_bot", false):
					label.modulate = Color(1, 1, 0) # Giallo per te
				else:
					label.modulate = Color(1, 1, 1)
		else:
			giocatori_nodes[i].visible = false 

# --- LOGICA SERVER ---

func _avvia_routine_server():
	await get_tree().create_timer(5.0).timeout
	client_hide_tutorial.rpc()
	
	var countdown = ["3", "2", "1", "PAGAIA!"]
	for msg in countdown:
		client_sync_info.rpc(msg)
		await get_tree().create_timer(1.0).timeout
	
	client_sync_info.rpc("")
	client_set_state.rpc(GameState.PLAYING)
	current_state = GameState.PLAYING

func _physics_process(delta):
	if current_state != GameState.PLAYING: return
	
	if multiplayer.is_server():
		_process_server_logic(delta)
	
	_process_items_movement(delta)

func _process_server_logic(delta):
	time_left -= delta
	if time_left <= 0:
		_determina_vincitore()
		return
	
	var current_sec = int(time_left)
	if current_sec != last_synced_time:
		client_sync_time.rpc(current_sec)
		last_synced_time = current_sec
	
	item_timer -= delta
	if item_timer <= 0:
		_server_spawn_item()

	for i in range(4):
		p_vel[i] = p_vel[i].lerp(Vector2(0, RIVER_SPEED), delta * 3.0)
		p_pos[i] += p_vel[i] * delta
		p_rot[i] = lerp(p_rot[i], 0.0, delta * 4.0)
		
		p_pos[i].x = clamp(p_pos[i].x, 50, 1100)
		p_pos[i].y = clamp(p_pos[i].y, 50, 600)
		
		if GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] -= delta
			if bot_timers[i] <= 0:
				_bot_paddle_logic(i)
				bot_timers[i] = randf_range(0.2, 0.4)
	
	client_sync_physics.rpc(p_pos, p_rot)

func _server_spawn_item():
	item_timer = randf_range(0.7, 1.3)
	var rnd = randf()
	var tipo = ItemType.GATE
	if rnd < 0.2: tipo = ItemType.BONUS
	elif rnd < 0.4: tipo = ItemType.BOMB
	
	var x_pos = randf_range(100, 1050)
	client_spawn_item.rpc(item_counter, tipo, x_pos)
	item_counter += 1

func _process_items_movement(delta):
	for itm_id in items_dict.keys():
		var data = items_dict[itm_id]
		var n = data["node"]
		if is_instance_valid(n):
			n.position.y += RIVER_SPEED * delta
			
			if multiplayer.is_server():
				_check_item_collision(itm_id, n, data["type"])

func _check_item_collision(itm_id, node, tipo):
	for i in range(4):
		var center = node.position + (node.size / 2.0)
		var dist = p_pos[i].distance_to(center)
		
		var collision_limit = 60.0 if tipo == ItemType.GATE else 40.0
		if dist < collision_limit:
			var pts = 1
			if tipo == ItemType.BONUS: pts = 3
			if tipo == ItemType.BOMB: pts = -2
			_server_add_score(i, itm_id, pts)
			break
			
	if node.position.y > 750:
		client_destroy_item.rpc(itm_id)

func _server_add_score(slot: int, itm_id: int, points: int):
	scores[slot] += points
	client_destroy_item.rpc(itm_id)
	client_sync_scores.rpc(scores)
	if points != 1:
		client_sync_info.rpc("BOMBA!" if points < 0 else "BONUS!")

# --- RPC INPUT ---
func _unhandled_input(event):
	if current_state != GameState.PLAYING or my_slot_index == -1: return
	
	if event.is_action_pressed("ui_left", false) and not event.is_echo():
		server_receive_paddle.rpc_id(1, true)
	elif event.is_action_pressed("ui_right", false) and not event.is_echo():
		server_receive_paddle.rpc_id(1, false)

@rpc("any_peer", "call_local", "reliable")
func server_receive_paddle(is_left: bool):
	if not multiplayer.is_server(): return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var slot = -1
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id:
			slot = i
			break
	
	if slot != -1:
		_apply_paddle_physics(slot, is_left)

func _apply_paddle_physics(slot: int, is_left: bool):
	p_vel[slot].y -= 160.0
	p_vel[slot].x += 110.0 if is_left else -110.0
	p_rot[slot] = 0.3 if is_left else -0.3

# --- RPC SYNC ---
@rpc("authority", "call_local", "unreliable")
func client_sync_physics(pos_array, rot_array):
	for i in range(4):
		giocatori_nodes[i].position = pos_array[i]
		giocatori_nodes[i].rotation = rot_array[i]

@rpc("authority", "call_local", "reliable")
func client_spawn_item(itm_id: int, tipo: int, x: float):
	var rect = ColorRect.new()
	rect.size = Vector2(100, 20) if tipo == ItemType.GATE else Vector2(40, 40)
	rect.color = Color.YELLOW if tipo == ItemType.GATE else (Color.GREEN if tipo == ItemType.BONUS else Color.BLACK)
	rect.position = Vector2(x - (rect.size.x/2), -60)
	porte_node.add_child(rect)
	items_dict[itm_id] = {"node": rect, "type": tipo}

@rpc("authority", "call_local", "reliable")
func client_destroy_item(itm_id: int):
	if items_dict.has(itm_id):
		if is_instance_valid(items_dict[itm_id]["node"]):
			items_dict[itm_id]["node"].queue_free()
		items_dict.erase(itm_id)

@rpc("authority", "call_local", "reliable")
func client_sync_scores(s):
	scores = s
	_update_score_ui()

@rpc("authority", "call_local", "reliable")
func client_sync_time(t: int): 
	time_label.text = str(t)

@rpc("authority", "call_local", "reliable")
func client_sync_info(txt): 
	info_label.text = txt

@rpc("authority", "call_local", "reliable")
func client_hide_tutorial(): 
	tutorial_panel.hide()

@rpc("authority", "call_local", "reliable")
func client_set_state(s): 
	current_state = s

# --- FINE PARTITA ---
func _update_score_ui():
	var t = "PUNTI\n"
	for i in range(4):
		if i < GlobalData.players_data.size():
			# Tronca i nomi troppo lunghi per il pannellino laterale
			var nome = GlobalData.players_data[i].get("name", "P"+str(i))
			if nome.length() > 8: nome = nome.substr(0, 8) + "."
			t += nome + ": " + str(scores[i]) + "\n"
	score_label.text = t

func _determina_vincitore():
	current_state = GameState.ENDED
	var winner_idx = scores.find(scores.max())
	
	var nome_vincitore = GlobalData.players_data[winner_idx].get("name", "Giocatore")
	client_sync_info.rpc("🏆 VINCE " + nome_vincitore.to_upper() + " 🏆")
	
	GlobalData.minigame_winners = [winner_idx]
	await get_tree().create_timer(4.0).timeout
	client_return_to_board.rpc()

@rpc("authority", "call_local", "reliable")
func client_return_to_board():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")

func _bot_paddle_logic(slot: int):
	_apply_paddle_physics(slot, randf() > 0.5)
