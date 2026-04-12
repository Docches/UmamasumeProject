extends Node2D

enum GameState { WAITING, PLAYING, FINISHED }
var current_state = GameState.WAITING

@onready var giocatori_nodes = [$Giocatori/P0, $Giocatori/P1, $Giocatori/P2, $Giocatori/P3]
@onready var qte_labels = [$UI/QTE0, $UI/QTE1, $UI/QTE2, $UI/QTE3]
@onready var info_label = $UI/InfoLabel

var tasti_possibili = ["ui_up", "ui_down", "ui_left", "ui_right"]
var my_slot_index = -1

# Variabili Server-Side
var step_giocatori = [0, 0, 0, 0] # Posizione in piscina (0 a 5)
var qte_progress = [0, 0, 0, 0]   # Quante frecce ha indovinato ogni giocatore (0 a 3)
var sequenza_attuale: Array[String] = []
var bot_timers = [0.0, 0.0, 0.0, 0.0]

func _ready():
	_assegna_slot_locale()
	
	if multiplayer.is_server():
		_server_start_countdown()

func _assegna_slot_locale():
	var my_id = multiplayer.get_unique_id()
	for i in range(GlobalData.players_data.size()):
		var p = GlobalData.players_data[i]
		if p["id"] == my_id and not p["is_bot"]:
			my_slot_index = i
			break

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
	
	# Resetta i progressi QTE di tutti per la nuova sequenza
	qte_progress = [0, 0, 0, 0]
	
	# Imposta i timer dei bot (tra 1.5 e 3 secondi per finire l'intera sequenza)
	for i in range(4):
		if i < GlobalData.players_data.size() and GlobalData.players_data[i]["is_bot"]:
			bot_timers[i] = randf_range(1.5, 3.0)
	
	current_state = GameState.PLAYING
	client_sync_sequenza.rpc(sequenza_attuale)

# --- 2. INPUT CLIENT -> SERVER ---

func _unhandled_input(event):
	if current_state != GameState.PLAYING or my_slot_index == -1: return
	
	# Il client intercetta la pressione e invia SOLO il nome del tasto al server
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
	
	if step_corrente_qte >= 3: return # Ha già finito, sta aspettando l'animazione
	
	# Se il tasto è corretto
	if key == sequenza_attuale[step_corrente_qte]:
		qte_progress[slot] += 1
		client_update_qte_progress.rpc(slot, qte_progress[slot])
		
		# Se ha completato le 3 frecce
		if qte_progress[slot] >= 3:
			_server_avanza_giocatore(slot)
	else:
		# Se sbaglia, resetta il suo progresso locale a 0
		qte_progress[slot] = 0
		client_qte_error.rpc(slot)

func _server_avanza_giocatore(slot: int):
	# Il primo che finisce blocca la sequenza per tutti
	current_state = GameState.WAITING
	
	step_giocatori[slot] += 1
	client_esegui_avanzamento.rpc(slot, step_giocatori[slot])
	
	if step_giocatori[slot] >= 5:
		_server_vittoria(slot)
	else:
		# Aspetta che l'animazione di nuoto finisca, poi genera la prossima sequenza
		await get_tree().create_timer(0.8).timeout
		_server_genera_nuova_sequenza()

func _process(delta):
	if not multiplayer.is_server() or current_state != GameState.PLAYING: return
	
	for i in range(4):
		if GlobalData.players_data[i]["is_bot"]:
			bot_timers[i] -= delta
			if bot_timers[i] <= 0:
				# Il bot è infallibile: scade il suo timer e vince la sequenza
				_server_avanza_giocatore(i)
				break # Evita che più bot avanzino nello stesso esatto frame

# --- 4. GESTIONE UI ED EFFETTI (CLIENT) ---

@rpc("authority", "call_local", "reliable")
func client_sync_sequenza(nuova_seq: Array):
	sequenza_attuale = nuova_seq
	current_state = GameState.PLAYING
	
	# Inizializza le UI per tutti i giocatori a 0 progressi
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
			"ui_up": freccia = "SU "
			"ui_down": freccia = "GIU "
			"ui_left": freccia = "SX "
			"ui_right": freccia = "DX "
			
		if i < progress:
			testo_qte += "[OK] "
		else:
			testo_qte += freccia
			
	qte_labels[slot].text = "FATTO!" if progress >= 3 else testo_qte
	
	# Evidenzia solo il TUO slot
	if slot == my_slot_index:
		var col = Color(0.2, 1, 0.2) if progress >= 3 else Color(1, 1, 0.2)
		qte_labels[slot].add_theme_color_override("font_color", col)
	else:
		qte_labels[slot].add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

@rpc("authority", "call_local", "reliable")
func client_qte_error(slot: int):
	# Resetta visivamente le frecce per chi ha sbagliato
	_aggiorna_label_qte(slot, 0)
	
	if slot == my_slot_index:
		qte_labels[slot].text = "ERRORE!"
		qte_labels[slot].add_theme_color_override("font_color", Color(1, 0.2, 0.2))
	
	# Animazione Shake per il giocatore che ha sbagliato
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

# --- 5. FINE PARTITA E UTILITIES ---

func _server_vittoria(slot: int):
	current_state = GameState.FINISHED
	var p_data = GlobalData.players_data[slot]
	var nome = "Bot " if p_data["is_bot"] else "Player " + str(p_data["id"])
	
	client_update_info.rpc("Vince: " + nome + "!")
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
