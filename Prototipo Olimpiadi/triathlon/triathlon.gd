extends Node2D

enum GameState { TUTORIAL, COUNTDOWN, PLAYING, ENDED }
enum Phase { SWIM, QTE1, BIKE, QTE2, RUN, FINISHED }

@onready var giocatori_nodes = [$Giocatori/P0, $Giocatori/P1, $Giocatori/P2, $Giocatori/P3]
@onready var info_label = $UI/InfoLabel
@onready var time_label = $UI/TimeLabel
@onready var tutorial_panel = $UI/TutorialPanel

var local_players_data = []
var standalone_test = false
var current_state = GameState.TUTORIAL
var my_slot_index = -1
var game_timer = 0.0

# Stato Giocatori (Server-Side)
var p_pos = []
var p_speed = [0.0, 0.0, 0.0, 0.0]
var p_phase = [Phase.SWIM, Phase.SWIM, Phase.SWIM, Phase.SWIM]
var p_stamina = [100.0, 100.0, 100.0, 100.0]
var p_exhausted = [0.0, 0.0, 0.0, 0.0]

# --- NUOVE MECCANICHE ---
var p_turbo = [0.0, 0.0, 0.0, 0.0]          # Livello Turbo in bici (0-100)
var p_is_boosting = [false, false, false, false] # Se il turbo è attivo
var p_qte_sequence = [[], [], [], []]       # La sequenza da premere
var p_qte_progress = [0, 0, 0, 0]           # A che punto della sequenza siamo
const QTE_KEYS = ["U", "D", "L", "R"]       # Up, Down, Left, Right
const QTE_LENGTH = 5                        # 5 frecce da azzeccare

# Input Giocatori (Server-Side)
var p_holding_acc = [false, false, false, false]
var p_holding_up = [false, false, false, false]
var p_holding_down = [false, false, false, false]

# Costanti Mappa
const ZONE_BIKE_START = 380.0
const ZONE_RUN_START = 800.0
const ZONE_FINISH = 1130.0

func _ready():
	info_label.text = ""
	tutorial_panel.show()
	
	for i in range(4):
		p_pos.append(giocatori_nodes[i].position)
		giocatori_nodes[i].get_node("Stamina").visible = false
		giocatori_nodes[i].get_node("Turbo").visible = false
		giocatori_nodes[i].get_node("Status").text = ""
		
	_inizializza_rete()
	_imposta_nomi_giocatori()
	
	if multiplayer.is_server():
		_avvia_routine()

func _inizializza_rete():
	var global_data_node = get_node_or_null("/root/GlobalData")
	if global_data_node and "players_data" in global_data_node and not global_data_node.players_data.is_empty():
		local_players_data = global_data_node.players_data
	else:
		standalone_test = true
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		local_players_data = [
			{"id": 1, "is_bot": false}, {"id": 0, "is_bot": true}, 
			{"id": 0, "is_bot": true}, {"id": 0, "is_bot": true}
		]
		
	var my_id = multiplayer.get_unique_id()
	for i in range(local_players_data.size()):
		if local_players_data[i]["id"] == my_id and not local_players_data[i].get("is_bot", false):
			my_slot_index = i

func _imposta_nomi_giocatori():
	for i in range(4):
		var p = local_players_data[i] if local_players_data.size() > i else {}
		var nome = "Bot " + str(i+1) if p.get("is_bot", true) else "P" + str(i+1)
		giocatori_nodes[i].get_node("Name").text = nome

func _avvia_routine():
	await get_tree().create_timer(6.0).timeout
	rpc("nascondi_tutorial")
	
	rpc("sync_info", "3")
	await get_tree().create_timer(1.0).timeout
	rpc("sync_info", "2")
	await get_tree().create_timer(1.0).timeout
	rpc("sync_info", "1")
	await get_tree().create_timer(1.0).timeout
	rpc("sync_info", "GO!")
	rpc("set_state", GameState.PLAYING)
	await get_tree().create_timer(1.0).timeout
	rpc("sync_info", "")

@rpc("authority", "call_local", "reliable")
func nascondi_tutorial(): tutorial_panel.hide()

@rpc("authority", "call_local", "reliable")
func sync_info(testo): info_label.text = testo

@rpc("authority", "call_local", "reliable")
func set_state(s): current_state = s

# --- GESTIONE INPUT CLIENT ---

var last_acc = false
var last_up = false
var last_down = false

func _process(delta):
	if current_state == GameState.PLAYING:
		game_timer += delta
		time_label.text = str(snapped(game_timer, 0.1))
		
		# Input continui per spostamenti e corsa
		if my_slot_index != -1:
			var acc = Input.is_action_pressed("ui_accept")
			var up = Input.is_action_pressed("ui_up")
			var down = Input.is_action_pressed("ui_down")
			
			if acc != last_acc or up != last_up or down != last_down:
				rpc_id(1, "receive_input_state", my_slot_index, acc, up, down)
				last_acc = acc
				last_up = up
				last_down = down
				
	if multiplayer.is_server() and current_state == GameState.PLAYING:
		_process_physics_server(delta)

func _unhandled_input(event):
	if current_state != GameState.PLAYING or my_slot_index == -1: return
	
	# Mashing per il nuoto e per l'attivazione Turbo
	if event.is_action_pressed("ui_accept", false) and not event.is_echo():
		rpc_id(1, "receive_action_button", my_slot_index)
		
	# Gestione precissisima dei tasti QTE
	if event.is_action_pressed("ui_up", false) and not event.is_echo(): rpc_id(1, "receive_qte", my_slot_index, "U")
	if event.is_action_pressed("ui_down", false) and not event.is_echo(): rpc_id(1, "receive_qte", my_slot_index, "D")
	if event.is_action_pressed("ui_left", false) and not event.is_echo(): rpc_id(1, "receive_qte", my_slot_index, "L")
	if event.is_action_pressed("ui_right", false) and not event.is_echo(): rpc_id(1, "receive_qte", my_slot_index, "R")

@rpc("any_peer", "call_local", "unreliable")
func receive_input_state(slot: int, acc: bool, up: bool, down: bool):
	if not multiplayer.is_server(): return
	p_holding_acc[slot] = acc
	p_holding_up[slot] = up
	p_holding_down[slot] = down

@rpc("any_peer", "call_local", "unreliable")
func receive_action_button(slot: int):
	if not multiplayer.is_server(): return
	
	if p_phase[slot] == Phase.SWIM:
		p_speed[slot] += 40.0
	elif p_phase[slot] == Phase.BIKE and p_turbo[slot] >= 100.0:
		# Attiva il Turbo!
		p_is_boosting[slot] = true
		p_turbo[slot] = 0.0

@rpc("any_peer", "call_local", "reliable")
func receive_qte(slot: int, key: String):
	if not multiplayer.is_server(): return
	
	if p_phase[slot] == Phase.QTE1 or p_phase[slot] == Phase.QTE2:
		var current_step = p_qte_progress[slot]
		if current_step < p_qte_sequence[slot].size():
			if key == p_qte_sequence[slot][current_step]:
				p_qte_progress[slot] += 1 # Tasto corretto!
				if p_qte_progress[slot] >= QTE_LENGTH:
					_supera_qte(slot)
			else:
				# ERRORE! Punizione: si ricomincia la sequenza da capo
				p_qte_progress[slot] = 0
				rpc_id(0, "mostra_errore_qte", slot)

@rpc("authority", "call_local", "unreliable")
func mostra_errore_qte(slot: int):
	giocatori_nodes[slot].get_node("Status").text = "ERRORE!"
	giocatori_nodes[slot].get_node("Status").modulate = Color(1,0,0)
	await get_tree().create_timer(0.3).timeout
	giocatori_nodes[slot].get_node("Status").modulate = Color(1,1,1)

# --- FISICA E LOGICA SERVER ---

func _process_physics_server(delta):
	for i in range(4):
		if p_phase[i] == Phase.FINISHED: continue
		
		if local_players_data[i].get("is_bot", false):
			_bot_logic(i, delta)
			
		if p_exhausted[i] > 0:
			p_exhausted[i] -= delta
			p_speed[i] = 0.0 
			p_stamina[i] += 20.0 * delta 
			continue

		match p_phase[i]:
			Phase.SWIM:
				_physics_swim(i, delta)
			Phase.BIKE:
				_physics_bike(i, delta)
			Phase.RUN:
				_physics_run(i, delta)

		p_pos[i].x += p_speed[i] * delta
		p_pos[i].y = clamp(p_pos[i].y, 50, 600)
		
		_check_zone_transitions(i)
		
	# Generazione Stringhe di Stato per l'UI
	var status_texts = []
	for i in range(4):
		var st = ""
		if p_phase[i] == Phase.QTE1 or p_phase[i] == Phase.QTE2:
			# Disegna la stringa di frecce (es: [ ↑ ↓ * * * ])
			st = "[ "
			for k in range(QTE_LENGTH):
				if k < p_qte_progress[i]:
					st += "OK "
				else:
					var char_k = p_qte_sequence[i][k]
					if char_k == "U": st += "↑ "
					elif char_k == "D": st += "↓ "
					elif char_k == "L": st += "← "
					elif char_k == "R": st += "→ "
			st += "]"
		elif p_exhausted[i] > 0:
			st = "SVAMPITO!"
		elif p_phase[i] == Phase.BIKE:
			if p_is_boosting[i]: st = "TURBO!!!"
			elif _is_drafting(i): st = "Ricarica Scia..."
		
		# Evita di sovrascrivere "ERRORE!" se è appena apparso
		if giocatori_nodes[i].get_node("Status").text != "ERRORE!":
			status_texts.append(st)
		else:
			status_texts.append("ERRORE!")
			
	rpc("sync_visuals", p_pos, p_phase, p_stamina, p_turbo, status_texts)

func _physics_swim(i: int, delta: float):
	p_speed[i] = lerp(p_speed[i], 0.0, delta * 2.0)
	for j in range(4):
		if i != j and p_phase[j] == Phase.SWIM:
			if p_pos[i].distance_to(p_pos[j]) < 35.0:
				p_speed[i] *= 0.9 

func _physics_bike(i: int, delta: float):
	var base_speed = 100.0 if p_holding_acc[i] else 0.0
	
	if p_is_boosting[i]:
		base_speed = 300.0 # Velocità assurda del turbo
		p_turbo[i] -= 40.0 * delta # Si consuma in fretta
		if p_turbo[i] <= 0:
			p_turbo[i] = 0.0
			p_is_boosting[i] = false
	else:
		if _is_drafting(i):
			base_speed *= 1.3 # Leggero boost passivo
			p_turbo[i] = min(100.0, p_turbo[i] + 30.0 * delta) # Carica il turbo!
		
	p_speed[i] = lerp(p_speed[i], base_speed, delta * 3.0) 
	
	if p_holding_up[i]: p_pos[i].y -= 80.0 * delta
	if p_holding_down[i]: p_pos[i].y += 80.0 * delta

func _is_drafting(i: int) -> bool:
	for j in range(4):
		if i != j and p_phase[j] == Phase.BIKE:
			var diff_x = p_pos[j].x - p_pos[i].x
			var diff_y = abs(p_pos[j].y - p_pos[i].y)
			if diff_x > 20.0 and diff_x < 120.0 and diff_y < 25.0:
				return true
	return false

func _physics_run(i: int, delta: float):
	if p_holding_acc[i]:
		p_speed[i] = lerp(p_speed[i], 80.0, delta * 4.0)
		p_stamina[i] -= 25.0 * delta
		if p_stamina[i] <= 0.0:
			p_exhausted[i] = 2.0 
	else:
		p_speed[i] = lerp(p_speed[i], 0.0, delta * 5.0)
		p_stamina[i] = min(100.0, p_stamina[i] + 30.0 * delta)

func _check_zone_transitions(i: int):
	var x = p_pos[i].x
	if p_phase[i] == Phase.SWIM and x >= ZONE_BIKE_START:
		p_pos[i].x = ZONE_BIKE_START
		p_phase[i] = Phase.QTE1
		p_speed[i] = 0.0 
		_genera_sequenza_qte(i)
		
	elif p_phase[i] == Phase.BIKE and x >= ZONE_RUN_START:
		p_pos[i].x = ZONE_RUN_START
		p_phase[i] = Phase.QTE2
		p_speed[i] = 0.0
		_genera_sequenza_qte(i)
		
	elif p_phase[i] == Phase.RUN and x >= ZONE_FINISH:
		p_phase[i] = Phase.FINISHED
		_giocatore_arrivato(i)

func _genera_sequenza_qte(slot: int):
	p_qte_sequence[slot].clear()
	p_qte_progress[slot] = 0
	for _k in range(QTE_LENGTH):
		p_qte_sequence[slot].append(QTE_KEYS[randi() % QTE_KEYS.size()])

func _supera_qte(slot: int):
	if p_phase[slot] == Phase.QTE1:
		p_phase[slot] = Phase.BIKE
		p_pos[slot].x += 5.0
	elif p_phase[slot] == Phase.QTE2:
		p_phase[slot] = Phase.RUN
		p_stamina[slot] = 100.0
		p_pos[slot].x += 5.0

# Timer per simulare i riflessi dei bot nei QTE
var bot_qte_timers = [0.0, 0.0, 0.0, 0.0]

func _bot_logic(slot: int, delta: float):
	match p_phase[slot]:
		Phase.SWIM:
			if randf() < 0.15: receive_action_button(slot)
		Phase.QTE1, Phase.QTE2:
			bot_qte_timers[slot] -= delta
			if bot_qte_timers[slot] <= 0:
				bot_qte_timers[slot] = randf_range(0.3, 0.6) # Un bot ci mette mezzo secondo a tasto
				if randf() > 0.1: # 90% di precisione
					var right_key = p_qte_sequence[slot][p_qte_progress[slot]]
					receive_qte(slot, right_key)
				else:
					receive_qte(slot, "U") # Sbaglia apposta
		Phase.BIKE:
			p_holding_acc[slot] = true
			if p_turbo[slot] >= 100.0 and randf() < 0.05:
				receive_action_button(slot) # Usa il turbo
				
			var found_draft = false
			for j in range(4):
				if slot != j and p_phase[j] == Phase.BIKE:
					if p_pos[j].x > p_pos[slot].x and p_pos[j].x < p_pos[slot].x + 150.0:
						if p_pos[j].y > p_pos[slot].y: 
							p_holding_down[slot] = true; p_holding_up[slot] = false
						else: 
							p_holding_up[slot] = true; p_holding_down[slot] = false
						found_draft = true
						break
			if not found_draft:
				p_holding_up[slot] = false; p_holding_down[slot] = false
		Phase.RUN:
			if p_stamina[slot] > 80.0: p_holding_acc[slot] = true
			elif p_stamina[slot] < 15.0: p_holding_acc[slot] = false

# --- SINCRONIZZAZIONE CLIENT ---

@rpc("authority", "call_local", "unreliable")
func sync_visuals(pos_arr, phase_arr, stam_arr, turbo_arr, status_arr):
	for i in range(4):
		giocatori_nodes[i].position = pos_arr[i]
		
		var stamina_bar = giocatori_nodes[i].get_node("Stamina")
		var turbo_bar = giocatori_nodes[i].get_node("Turbo")
		
		if phase_arr[i] == Phase.RUN:
			stamina_bar.visible = true
			stamina_bar.value = stam_arr[i]
			turbo_bar.visible = false
			if stam_arr[i] < 30.0: stamina_bar.modulate = Color(1, 0, 0)
			else: stamina_bar.modulate = Color(1, 1, 1)
		elif phase_arr[i] == Phase.BIKE:
			stamina_bar.visible = false
			turbo_bar.visible = true
			turbo_bar.value = turbo_arr[i]
		else:
			stamina_bar.visible = false
			turbo_bar.visible = false
			
		giocatori_nodes[i].get_node("Status").text = status_arr[i]

func _giocatore_arrivato(slot: int):
	if current_state == GameState.ENDED: return 
	current_state = GameState.ENDED
	rpc("set_state", GameState.ENDED)
	
	var nome = giocatori_nodes[slot].get_node("Name").text
	rpc("sync_info", nome + " HA VINTO!\nTempo: " + time_label.text)
	
	var g_data = get_node_or_null("/root/GlobalData")
	if g_data:
		g_data.minigame_winners.clear()
		g_data.minigame_winners.append(slot)
	
	await get_tree().create_timer(5.0).timeout
	if standalone_test:
		multiplayer.multiplayer_peer = null
		get_tree().reload_current_scene()
	else:
		rpc("torna_al_tabellone")

@rpc("authority", "call_local", "reliable")
func torna_al_tabellone():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
