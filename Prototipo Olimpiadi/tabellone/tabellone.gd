extends Node2D

@export var minigame_scenes: Array[PackedScene]

@onready var spaces_node: Node2D = $Spaces
@onready var turn_label: Label = $UI/TurnLabel
@onready var dice_label: Label = $UI/DiceLabel

# Usiamo get_node_or_null per evitare crash se l'interfaccia viene modificata
@onready var hud_nodes = [
	get_node_or_null("UI/PlayerHUDs/HUD_P0"),
	get_node_or_null("UI/PlayerHUDs/HUD_P1"),
	get_node_or_null("UI/PlayerHUDs/HUD_P2"),
	get_node_or_null("UI/PlayerHUDs/HUD_P3")
]

enum GameState { IDLE, DICE_ROLLING, MOVING, EVENT_ACTIVE, WAITING_FOR_MINIGAME, GAME_OVER }

enum SpaceType { 
	START_LAP, NEUTRAL, COIN_PLUS, STEP_BONUS, 
	STEP_PENALTY, SHOP, OLYMPIC_TORCH, GOLDEN_CARROT, HORSE_EAR 
}

var current_state: GameState = GameState.IDLE
var players_node: Node2D
var players: Array[Sprite2D] = []
var player_current_spaces: Array[int] = [] # Salva in quale casella si trova ogni giocatore

var active_steps_left = 0
var current_dice_number = 1
var move_direction = 1

const TOTAL_SPACES = 100
const MAX_TURNS = 15

var space_links = {}
var space_types = {}

func _ready() -> void:

	randomize()
	
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: GlobalData vuoto. Generazione giocatori di test in corso...")
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i > 0})
			GlobalData.player_space_indices.append(0)
			GlobalData.player_coins.append(0)
			GlobalData.player_medals.append(0)
	
	# 2. Generazione del tabellone
	generate_board()
	
	# 3. Generazione DINAMICA dei giocatori (Risolve l'errore "Node not found")
	players_node = Node2D.new()
	players_node.name = "Players"
	players_node.z_index = 10
	add_child(players_node)
	
	for i in range(GlobalData.players_data.size()):
		var p_sprite = Sprite2D.new()
		# Assicurati che questo percorso corrisponda all'icona del tuo gioco
		p_sprite.texture = load("res://curling/icon.svg") 
		p_sprite.scale = Vector2(0.3, 0.3)
		
		# Colori per distinguerli
		match i:
			0: p_sprite.modulate = Color.WHITE
			1: p_sprite.modulate = Color(1, 0, 1) # Fucsia
			2: p_sprite.modulate = Color(0.78, 0.58, 0.25) # Oro/Marrone
			3: p_sprite.modulate = Color(0, 0.74, 0.40) # Verde
			
		players_node.add_child(p_sprite)
		players.append(p_sprite)
		player_current_spaces.append(0)
	
	# 4. Ripristino stato partita
	restore_board_state()
	update_huds()
	
	# 5. Logica di inizio turno (Gestita dal Server)
	if multiplayer.is_server():
		if GlobalData.current_turn > MAX_TURNS:
			declare_winner.rpc()
			return
		
		if not GlobalData.minigame_winners.is_empty():
			apply_minigame_bonus.rpc(GlobalData.minigame_winners)
		else:
			update_ui.rpc(GlobalData.current_player_index)

# --- GENERAZIONE TABELLONE ---
func generate_board():
	var cols = 10
	var rows = 10
	var start_x = 180
	var start_y = 100
	var step_x = 88
	var step_y = 52
	
	for i in range(TOTAL_SPACES):
		space_links[i] = [(i + 1) % TOTAL_SPACES]
		
		var row = i / cols
		var col = i % cols
		if row % 2 != 0: col = (cols - 1) - col # Zig-Zag
		var pos = Vector2(start_x + col * step_x, start_y + row * step_y)
		
		var marker = Marker2D.new()
		marker.name = "Space_" + str(i)
		marker.position = pos
		
		var rect = ColorRect.new()
		rect.name = "Visual"
		rect.size = Vector2(44, 44)
		rect.position = Vector2(-22, -22)
		
		var label = Label.new()
		label.text = str(i)
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color.BLACK)
		
		var icon_label = Label.new()
		icon_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
		icon_label.position.y = -20
		icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		icon_label.add_theme_font_size_override("font_size", 20)
		
		_assign_space_properties(i, rect, icon_label)
		
		marker.add_child(rect)
		marker.add_child(label)
		marker.add_child(icon_label)
		spaces_node.add_child(marker)

func _assign_space_properties(i: int, rect: ColorRect, icon: Label):
	if i == 0:
		space_types[i] = SpaceType.START_LAP
		rect.color = Color(1.0, 0.8, 0.2)
		icon.text = "⭐"
	elif i == 69:
		space_types[i] = SpaceType.HORSE_EAR
		rect.color = Color(0.9, 0.5, 0.6)
		icon.text = "🐴"
	elif i == 42 or i == 88:
		space_types[i] = SpaceType.GOLDEN_CARROT
		rect.color = Color(1.0, 0.7, 0.0)
		icon.text = "🥕"
	elif i == 25 or i == 50 or i == 75:
		space_types[i] = SpaceType.OLYMPIC_TORCH
		rect.color = Color(1.0, 0.4, 0.0)
		icon.text = "🪔"
	elif i % 20 == 0 and i != 0:
		space_types[i] = SpaceType.SHOP
		rect.color = Color(0.6, 0.4, 0.8)
		icon.text = "🏪"
	elif i % 15 == 0:
		space_types[i] = SpaceType.STEP_PENALTY
		rect.color = Color(0.9, 0.2, 0.2)
		icon.text = "⏪"
	elif i % 13 == 0:
		space_types[i] = SpaceType.STEP_BONUS
		rect.color = Color(1.0, 1.0, 0.3)
		icon.text = "⏩"
	elif i % 5 == 0:
		space_types[i] = SpaceType.COIN_PLUS
		rect.color = Color(0.4, 0.9, 0.4)
		icon.text = "🪙"
	else:
		space_types[i] = SpaceType.NEUTRAL
		rect.color = Color(0.95, 0.95, 0.85) if i % 2 == 0 else Color(0.9, 0.9, 0.7)

# --- INPUT E GESTIONE TURNO MULTIPLAYER ---
func _process(_delta: float) -> void:
	if current_state == GameState.DICE_ROLLING:
		current_dice_number = randi_range(1, 6)
		dice_label.text = "[ " + str(current_dice_number) + " ]"
	
	elif current_state == GameState.IDLE and multiplayer.is_server():
		var current_p = GlobalData.players_data[GlobalData.current_player_index]
		if current_p["is_bot"]:
			current_state = GameState.DICE_ROLLING
			await get_tree().create_timer(1.0).timeout 
			stop_dice_server.rpc_id(1, randi_range(1, 6))

func _input(event: InputEvent) -> void:
	if current_state == GameState.IDLE or current_state == GameState.DICE_ROLLING:
		var current_p = GlobalData.players_data[GlobalData.current_player_index]
		# Permetti l'input solo se l'ID del client corrisponde a quello di chi deve giocare
		if current_p["id"] == multiplayer.get_unique_id() and not current_p["is_bot"]:
			if current_state == GameState.IDLE and event.is_action_pressed("ui_accept"):
				start_dice_spin.rpc()
			elif current_state == GameState.DICE_ROLLING and event.is_action_pressed("ui_accept"):
				stop_dice_server.rpc_id(1, current_dice_number)

@rpc("any_peer", "call_local", "reliable")
func start_dice_spin():
	current_state = GameState.DICE_ROLLING
	turn_label.text = "TIRA IL DADO!"

# Solo il Server riceve questo comando e decide come si muove il giocatore
@rpc("any_peer", "call_local", "reliable")
func stop_dice_server(final_number: int):
	if not multiplayer.is_server(): return
	current_state = GameState.MOVING
	active_steps_left = final_number
	move_direction = 1 # Avanza normalmente
	
	lock_dice_ui.rpc(active_steps_left)
	await get_tree().create_timer(0.8).timeout
	_step_player()

@rpc("authority", "call_local", "reliable")
func lock_dice_ui(num: int):
	current_state = GameState.MOVING
	dice_label.text = "[ " + str(num) + " ]"
	var tween = create_tween()
	tween.tween_property(dice_label, "modulate", Color(0.2, 1, 0.2), 0.2)
	tween.tween_property(dice_label, "scale", Vector2(1.2, 1.2), 0.1)
	tween.tween_property(dice_label, "scale", Vector2(1.0, 1.0), 0.1)
	tween.tween_property(dice_label, "modulate", Color.WHITE, 0.3)

# --- SISTEMA DI MOVIMENTO (SERVER-SIDE) ---
func _step_player():
	if not multiplayer.is_server(): return
	
	var p_idx = GlobalData.current_player_index
	var current_node = player_current_spaces[p_idx]
	
	if active_steps_left <= 0:
		_resolve_landed_space()
		return
		
	# Calcola la prossima casella
	var target_node = 0
	if move_direction == 1:
		target_node = (current_node + 1) % TOTAL_SPACES
		# Controllo Medaglia Giro Completo
		if target_node == 0:
			GlobalData.player_medals[p_idx] += 1
			sync_info_text.rpc("Giro completato! +1 Medaglia!")
			update_leaderboard_data.rpc(GlobalData.player_coins, GlobalData.player_medals)
	else:
		# Muoversi all'indietro
		target_node = (current_node - 1 + TOTAL_SPACES) % TOTAL_SPACES
	
	# Applica il passo
	active_steps_left -= 1
	player_current_spaces[p_idx] = target_node
	GlobalData.player_space_indices[p_idx] = target_node
	
	var target_pos = spaces_node.get_child(target_node).global_position
	
	# Avvisa tutti i client di aggiornare la visuale
	update_dice_visual.rpc(active_steps_left)
	sync_player_pos.rpc(p_idx, target_pos, target_node)
	
	# Attendi che finisca l'animazione del salto, poi fai il prossimo passo
	await get_tree().create_timer(0.25).timeout
	_step_player()

@rpc("authority", "call_local", "reliable")
func update_dice_visual(left: int):
	if left > 0: dice_label.text = "[ " + str(left) + " ]"
	else: dice_label.text = ""

@rpc("authority", "call_local", "reliable")
func sync_player_pos(p_idx: int, base_pos: Vector2, new_space_index: int):
	# Sincronizza l'indice per sicurezza (Locale e Globale)
	player_current_spaces[p_idx] = new_space_index
	GlobalData.player_space_indices[p_idx] = new_space_index 
	
	var offset = Vector2((p_idx % 2) * 16 - 8, int(p_idx / 2) * 16 - 8)
	var final_pos = base_pos + offset
	var player_sprite = players[p_idx]
	
	var tween = create_tween().set_parallel(true)
	tween.tween_property(player_sprite, "global_position:x", final_pos.x, 0.2)
	
	var y_tween = create_tween()
	y_tween.tween_property(player_sprite, "global_position:y", final_pos.y - 25.0, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	y_tween.tween_property(player_sprite, "global_position:y", final_pos.y, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

# --- RISOLUZIONE CASELLE ---
func _resolve_landed_space():
	current_state = GameState.EVENT_ACTIVE
	var p_idx = GlobalData.current_player_index
	var space_idx = player_current_spaces[p_idx]
	
	var type = space_types.get(space_idx, SpaceType.NEUTRAL)
	var end_turn_immediately = true
	
	match type:
		SpaceType.COIN_PLUS:
			GlobalData.player_coins[p_idx] += 10
			sync_info_text.rpc("🪙 Casella Moneta: +10 Monete!")
		SpaceType.STEP_BONUS:
			sync_info_text.rpc("⏩ Boost! Avanzi di 4!")
			end_turn_immediately = false
			await get_tree().create_timer(1.0).timeout
			if multiplayer.is_server():
				active_steps_left = 4
				move_direction = 1
				_step_player() # Riavvia il movimento in avanti
		SpaceType.STEP_PENALTY:
			sync_info_text.rpc("⏪ Malus! Indietreggi di 3!")
			end_turn_immediately = false
			await get_tree().create_timer(1.0).timeout
			if multiplayer.is_server():
				active_steps_left = 3
				move_direction = -1 # Direzione inversa
				_step_player() # Riavvia il movimento indietro
		SpaceType.SHOP:
			if GlobalData.player_coins[p_idx] >= 10:
				GlobalData.player_coins[p_idx] -= 10
				GlobalData.player_medals[p_idx] += 1
				sync_info_text.rpc("🏪 SHOP: Spese 10 Monete per 1 Medaglia!")
			else:
				sync_info_text.rpc("🏪 SHOP: Povero! Servono 10 monete per 1 Medaglia.")
		SpaceType.OLYMPIC_TORCH:
			GlobalData.player_medals[p_idx] += 2
			sync_info_text.rpc("🪔 Fiaccola Olimpica: +2 Medaglie!")
		SpaceType.GOLDEN_CARROT:
			GlobalData.player_coins[p_idx] += 50
			sync_info_text.rpc("🥕 CAROTA D'ORO! Trovi 50 Monete!")
		SpaceType.HORSE_EAR:
			GlobalData.player_coins[p_idx] += 1
			sync_info_text.rpc("🐴 Trovi l'Orecchio di Cavallo... Nitrisci. +1 Moneta.")
		SpaceType.START_LAP:
			sync_info_text.rpc("⭐ Sei sul VIA! Riposati!")
		_:
			sync_info_text.rpc("Casella Neutrale.")
			
	if end_turn_immediately:
		await get_tree().create_timer(2.0).timeout
		update_leaderboard_data.rpc(GlobalData.player_coins, GlobalData.player_medals)
		end_turn_server()

# --- FINE TURNO ---
func end_turn_server() -> void:
	GlobalData.current_player_index += 1
	if GlobalData.current_player_index >= GlobalData.players_data.size():
		GlobalData.current_player_index = 0
		GlobalData.current_turn += 1
		if GlobalData.current_turn <= MAX_TURNS:
			start_minigame_sequence.rpc(GlobalData.current_turn)
		else:
			declare_winner.rpc()
	else:
		sync_state.rpc(GlobalData.current_player_index, GlobalData.current_turn)

@rpc("authority", "call_local", "reliable")
func sync_info_text(txt: String):
	turn_label.text = txt

@rpc("authority", "call_local", "reliable")
func sync_state(next_player_index: int, turn: int):
	GlobalData.current_player_index = next_player_index
	GlobalData.current_turn = turn
	current_state = GameState.IDLE
	update_ui(next_player_index) 

@rpc("authority", "call_local", "reliable")
func update_ui(p_index: int):
	var current_p = GlobalData.players_data[p_index]
	var txt = "Turno " + str(GlobalData.current_turn) + "/" + str(MAX_TURNS) + "\nGiocatore " + str(p_index + 1)
	if current_p.get("is_bot", false): txt += " (BOT)"
	turn_label.text = txt
	
	if current_state == GameState.IDLE:
		if current_p.get("is_bot", false): 
			dice_label.text = "[ Il Bot sta tirando... ]"
		elif current_p["id"] == multiplayer.get_unique_id(): 
			dice_label.text = "[ PREMI SPAZIO PER GIRARE ]"
		else: 
			dice_label.text = "[ Attendi il tuo turno ]"
	
	update_huds() 

@rpc("authority", "call_local", "reliable")
func update_leaderboard_data(coins, medals):
	GlobalData.player_coins = coins
	GlobalData.player_medals = medals
	update_huds()

func update_huds():
	for i in range(4):
		if hud_nodes[i] == null: continue
		
		if i < GlobalData.players_data.size():
			var p_data = GlobalData.players_data[i]
			hud_nodes[i].show()
			hud_nodes[i].get_node("Name").text = "Giocatore " + str(i + 1) + (" (BOT)" if p_data.get("is_bot", false) else "")
			hud_nodes[i].get_node("Stats").text = "🏅 " + str(GlobalData.player_medals[i]) + "\n🪙 " + str(GlobalData.player_coins[i])
			
			if i == GlobalData.current_player_index:
				hud_nodes[i].modulate = Color(1.3, 1.3, 1.3, 1.0) 
				hud_nodes[i].scale = Vector2(1.05, 1.05)
			else:
				hud_nodes[i].modulate = Color(1.0, 1.0, 1.0, 0.8)
				hud_nodes[i].scale = Vector2(1.0, 1.0)
		else:
			hud_nodes[i].hide()

@rpc("authority", "call_local", "reliable")
func apply_minigame_bonus(winners: Array):
	current_state = GameState.MOVING 
	turn_label.text = "VITTORIA MINIGIOCO!"
	dice_label.text = "I vincitori ottengono 10 Monete!"
	
	if multiplayer.is_server():
		for w in winners: GlobalData.player_coins[w] += 10
		update_leaderboard_data.rpc(GlobalData.player_coins, GlobalData.player_medals)
		GlobalData.minigame_winners.clear() 
		await get_tree().create_timer(3.0).timeout
		sync_state.rpc(GlobalData.current_player_index, GlobalData.current_turn)

func restore_board_state() -> void:
	var space_children = spaces_node.get_children()
	if space_children.is_empty(): return
	
	for i in range(players.size()):
		if GlobalData.player_space_indices.size() > i:
			var saved_index = mini(GlobalData.player_space_indices[i], space_children.size() - 1)
			player_current_spaces[i] = saved_index
			var base_pos = space_children[saved_index].global_position
			var offset = Vector2((i % 2) * 16 - 8, int(i / 2) * 16 - 8)
			players[i].global_position = base_pos + offset

@rpc("authority", "call_local", "reliable")
func start_minigame_sequence(new_turn: int):
	# Sincronizza turno e resetta l'indice giocatore prima di cambiare scena
	GlobalData.current_turn = new_turn
	GlobalData.current_player_index = 0
	
	current_state = GameState.WAITING_FOR_MINIGAME
	turn_label.text = "ATTENZIONE!"
	dice_label.text = "MINIGIOCO IN ARRIVO..."
	await get_tree().create_timer(3.0).timeout
	if multiplayer.is_server():
		change_scene_all.rpc(minigame_scenes.pick_random().resource_path)

@rpc("authority", "call_local", "reliable")
func change_scene_all(path: String):
	get_tree().change_scene_to_file(path)

@rpc("authority", "call_local", "reliable")
func declare_winner():
	current_state = GameState.GAME_OVER
	
	var winner_idx = 0
	for i in range(1, GlobalData.players_data.size()):
		if GlobalData.player_medals[i] > GlobalData.player_medals[winner_idx]:
			winner_idx = i
		elif GlobalData.player_medals[i] == GlobalData.player_medals[winner_idx]:
			if GlobalData.player_coins[i] > GlobalData.player_coins[winner_idx]:
				winner_idx = i
				
	var winner_name = "Giocatore " + str(winner_idx + 1)
	if GlobalData.players_data[winner_idx].get("is_bot", false):
		winner_name += " (BOT)"
		
	turn_label.text = "🏆 FINE PARTITA 🏆"
	turn_label.modulate = Color(1, 0.8, 0)
	dice_label.text = "Vincitore Assoluto:\n" + winner_name + "!"
