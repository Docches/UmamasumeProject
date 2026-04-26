extends Node2D

enum GameState { WAITING, PLAYING, FINISHED }
var current_state = GameState.WAITING

@onready var giocatori_nodes = [$Giocatori/P0, $Giocatori/P1, $Giocatori/P2, $Giocatori/P3]
@onready var qte_labels = [$UI/QTE0, $UI/QTE1, $UI/QTE2, $UI/QTE3]
@onready var info_label = $UI/InfoLabel

var tasti_possibili = ["up", "down", "left", "right"]
var my_slot_index = -1

# Variabili Server-Side
var step_giocatori = [0, 0, 0, 0] 
var qte_progress = [0, 0, 0, 0]  
var sequenza_attuale: Array[String] = []
var bot_timers = [0.0, 0.0, 0.0, 0.0]

func _ready():
	# PREVENZIONE CRASH (Test F6)
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: Avvio Standalone Nuoto. Generazione Bot in corso...")
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else "BOT"})
			
	_assegna_slot_locale()
	_imposta_nomi_giocatori()
	
	if multiplayer.is_server():
		_server_start_countdown()

func _assegna_slot_locale():
	var my_id = multiplayer.get_unique_id()
	for i in range(GlobalData.players_data.size()):
		var p = GlobalData.players_data[i]
		if p["id"] == my_id and not p.get("is_bot", false):
			my_slot_index = i
			break

# --- INTEGRAZIONE NICKNAME (NUOTO) ---
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
				
				# Colora il tuo Nickname di giallo
				if p_data.get("id") == my_id and not p_data.get("is_bot", false):
					label.modulate = Color(1, 1, 0)
				else:
					label.modulate = Color(1, 1, 1)
		else:
			giocatori_nodes[i].visible = false 

# --- 1. COUNTDOWN E GENERAZIONE (SERVER) ---

func _server_start_countdown():
	current_state = GameState.WAITING
	
	var countdown = ["3", "2", "1", "VIA!"]
	for msg in countdown:
		client_update_info.rpc(msg)
		await get_tree().create_timer(1.0).timeout
	
	client_avvia_animazioni.rpc()
	_server_genera_nuova_sequenza()
	
	await get_tree().create_timer(1.0).timeout
	client_update_info.rpc("")

func _server_genera_nuova_sequenza():
	sequenza_attuale.clear()
	for i in range(3):
		sequenza_attuale.append(tasti_possibili.pick_random())
	
	qte_progress = [0, 0, 0, 0]
	
	for i in range(4):
		if i < GlobalData.players_data.size() and GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] = randf_range(1.5, 3.0)
	
	current_state = GameState.PLAYING
	client_sync_sequenza.rpc(sequenza_attuale)

# --- 2. INPUT CLIENT -> SERVER ---

func _unhandled_input(event):
	if current_state != GameState.PLAYING or my_slot_index == -1: return
	
	for key in tasti_possibili:
		if Input.is_action_just_pressed(key):
			server_submit_key.rpc_id(1, key)
			return

@rpc("any_peer", "call_local", "reliable")
func server_submit_key(key: String):
	if not multiplayer.is_server() or current_state != GameState.PLAYING: return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var slot = -1
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id:
			slot = i
			break
			
	if slot != -1:
		_server_valuta_input(slot, key)

# --- 3. LOGICA DI VALIDAZIONE (SERVER-SIDE) ---

func _server_valuta_input(slot: int, key: String):
	var step_corrente_qte = qte_progress[slot]
	if step_corrente_qte >= 3: return 
	
	if key == sequenza_attuale[step_corrente_qte]:
		qte_progress[slot] += 1
		client_update_qte_progress.rpc(slot, qte_progress[slot])
		
		if qte_progress[slot] >= 3:
			_server_avanza_giocatore(slot)
	else:
		qte_progress[slot] = 0
		client_qte_error.rpc(slot)

func _server_avanza_giocatore(slot: int):
	current_state = GameState.WAITING
	
	step_giocatori[slot] += 1
	client_esegui_avanzamento.rpc(slot, step_giocatori[slot])
	
	if step_giocatori[slot] >= 5:
		_server_vittoria(slot)
	else:
		await get_tree().create_timer(0.8).timeout
		if current_state != GameState.FINISHED:
			_server_genera_nuova_sequenza()

func _process(delta):
	if not multiplayer.is_server() or current_state != GameState.PLAYING: return
	
	for i in range(4):
		if GlobalData.players_data[i].get("is_bot", false):
			bot_timers[i] -= delta
			if bot_timers[i] <= 0:
				_server_avanza_giocatore(i)
				break 

# --- 4. GESTIONE UI ED EFFETTI (CLIENT) ---

@rpc("authority", "call_local", "reliable")
func client_sync_sequenza(nuova_seq: Array):
	sequenza_attuale = nuova_seq
	current_state = GameState.PLAYING
	
	for i in range(4):
		_aggiorna_label_qte(i, 0)

@rpc("authority", "call_local", "reliable")
func client_update_qte_progress(slot: int, progress: int):
	_aggiorna_label_qte(slot, progress)

func _aggiorna_label_qte(slot: int, progress: int):
	var testo_qte = ""
	for i in range(sequenza_attuale.size()):
		var freccia = ""
		match sequenza_attuale[i]:
			"up": freccia = "↑"
			"down": freccia = "↓"
			"left": freccia = "←"
			"right": freccia = "→"
			
		if i < progress:
			testo_qte += "[OK] "
		else:
			testo_qte += freccia
			
	qte_labels[slot].text = "FATTO!" if progress >= 3 else testo_qte
	
	if slot == my_slot_index:
		var col = Color(0.2, 1, 0.2) if progress >= 3 else Color(1, 1, 0.2)
		qte_labels[slot].add_theme_color_override("font_color", col)
	else:
		qte_labels[slot].add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

@rpc("authority", "call_local", "reliable")
func client_qte_error(slot: int):
	_aggiorna_label_qte(slot, 0)
	
	if slot == my_slot_index:
		qte_labels[slot].text = "ERRORE!"
		qte_labels[slot].add_theme_color_override("font_color", Color(1, 0.2, 0.2))
	
	var p_node = giocatori_nodes[slot]
	var err_tween = create_tween()
	p_node.modulate = Color(1, 0.3, 0.3)
	err_tween.tween_property(p_node, "position:x", p_node.position.x - 15, 0.05)
	err_tween.tween_property(p_node, "position:x", p_node.position.x + 15, 0.05)
	err_tween.tween_property(p_node, "position:x", p_node.position.x, 0.05)
	err_tween.tween_property(p_node, "modulate", Color(1, 1, 1), 0.1)

@rpc("authority", "call_local", "reliable")
func client_esegui_avanzamento(slot: int, step_attuale: int):
	current_state = GameState.WAITING
	var nuova_x = 100.0 + (step_attuale * 160.0)
	
	var scale_orig = giocatori_nodes[slot].scale
	var tween = create_tween().set_parallel(true)
	tween.tween_property(giocatori_nodes[slot], "position:x", nuova_x, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(giocatori_nodes[slot], "scale", Vector2(scale_orig.x * 1.3, scale_orig.y * 0.7), 0.15)
	tween.chain().tween_property(giocatori_nodes[slot], "scale", scale_orig, 0.25)

# --- 5. FINE PARTITA ---

func _server_vittoria(slot: int):
	current_state = GameState.FINISHED
	var p_data = GlobalData.players_data[slot]
	
	var nome = p_data.get("name", "Giocatore")
	if p_data.get("is_bot", false) and not nome.begins_with("BOT"):
		nome += " (BOT)"
	
	client_update_info.rpc("🏆 " + nome + " VINCE! 🏆")
	client_ferma_animazioni.rpc()
	
	GlobalData.minigame_winners = [slot]
	await get_tree().create_timer(3.0).timeout
	client_ritorna_al_tabellone.rpc()

@rpc("authority", "call_local", "reliable")
func client_update_info(testo: String):
	info_label.text = testo

@rpc("authority", "call_local", "reliable")
func client_avvia_animazioni():
	for i in range(4):
		if giocatori_nodes[i] is AnimatedSprite2D:
			giocatori_nodes[i].play()

@rpc("authority", "call_local", "reliable")
func client_ferma_animazioni():
	for i in range(4):
		if giocatori_nodes[i] is AnimatedSprite2D:
			giocatori_nodes[i].stop()
	for l in qte_labels: 
		l.text = ""

@rpc("authority", "call_local", "reliable")
func client_ritorna_al_tabellone():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
