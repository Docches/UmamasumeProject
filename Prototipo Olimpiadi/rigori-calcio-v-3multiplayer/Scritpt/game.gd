extends Node

# =============================================================================
# RIGORI CALCIO MULTIPLAYER SERVER-AUTHORITATIVE + AUDIO
# =============================================================================

@onready var messaggi        = $punteggioCambiGiocatori/messaggi
@onready var label_g1        = $punteggioCambiGiocatori/Giocatore1score
@onready var label_g2        = $punteggioCambiGiocatori/Giocatore2score
@onready var label_g3        = $punteggioCambiGiocatori/Giocatore3
@onready var label_g4        = $punteggioCambiGiocatori/Giocatore4
@onready var portiere_node   = $Portiere
@onready var calciatore_node = $Calciatore
@onready var palla_node      = $Palla

# --- NODI AUDIO ---
@onready var audio_folla      = get_node_or_null("AudioFolla")
@onready var audio_tiro       = get_node_or_null("AudioTiro")
@onready var audio_gol        = get_node_or_null("AudioGol")
@onready var audio_sbagliato  = get_node_or_null("AudioSbagliato")

enum Fase { MESSAGGIO, SCELTA, RISULTATO, FINE }
var fase: Fase = Fase.MESSAGGIO

var punteggi = [0, 0, 0, 0]
var ordine_vittoria = []
var turno_corrente = 0
var MAX_TURNI = 4
var PUNTI_VITTORIA = 3

var portiere_corrente = -1
var calciatore_corrente = -1
var calciatori_da_tirare: Array[int] = []

var scelta_calciatore: int = 0
var scelta_portiere:   int = 0
var game_started: bool = false
var bot_timer: float = 0.0

var tiro_id_corrente: int = 0 

const ANIM_PORTIERE = { 1: "parataSinistra", 2: "parataCentroSinistra", 3: "parataCentroDestra", 4: "parataDestra" }
const POSIZIONI_PORTA = { 1: Vector2(363, 262), 2: Vector2(489, 150), 3: Vector2(694, 158), 4: Vector2(760, 257) }
const POSIZIONE_INIZIALE_PALLA = Vector2(557, 516)
const NOME_DIR = { 1: "Sinistra", 2: "Centro-Sin", 3: "Centro-Des", 4: "Destra" }

func _ready() -> void:
	randomize()
	
	if audio_folla and not audio_folla.playing:
		audio_folla.play()
	
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: Avvio Standalone Rigori. Generazione Bot in corso...")
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else "BOT"})

	_aggiorna_ui()

	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout
		_inizia_turno_server()

# --- INTEGRAZIONE NICKNAME UNIVERSALE ---
func _get_player_name(idx: int) -> String:
	if idx < 0 or idx >= GlobalData.players_data.size(): return "???"
	var p_data = GlobalData.players_data[idx]
	var nome = p_data.get("name", "Giocatore")
	
	if p_data.get("is_bot", false) and not nome.begins_with("BOT"):
		var bot_count = 1
		for j in range(idx):
			if GlobalData.players_data[j].get("is_bot", false): bot_count += 1
		nome = "BOT " + str(bot_count)
		
	return nome

# --- LOGICA DI FLUSSO SERVER ---
func _inizia_turno_server() -> void:
	var attivi = _giocatori_attivi()
	if attivi.size() < 2: 
		_fine_gioco_server()
		return
		
	var idx_portiere = attivi[randi() % attivi.size()]
	var calciatori: Array[int] = []
	for g in attivi:
		if g != idx_portiere: calciatori.append(g)
			
	if calciatori.size() > 3: calciatori.resize(3)
	
	_sync_inizio_turno.rpc(turno_corrente, idx_portiere, calciatori[0], calciatori)
	
	await get_tree().create_timer(4.0).timeout
	if fase == Fase.MESSAGGIO and game_started:
		_sync_inizia_tiro.rpc(calciatore_corrente, portiere_corrente)

@rpc("authority", "call_local", "reliable")
func _sync_inizio_turno(turno: int, idx_portiere: int, idx_calciatore: int, calciatori: Array) -> void:
	turno_corrente      = turno
	portiere_corrente   = idx_portiere
	calciatore_corrente = idx_calciatore
	calciatori_da_tirare = calciatori.duplicate()

	scelta_calciatore = 0
	scelta_portiere   = 0
	game_started      = true

	_reset_animazioni()
	_aggiorna_ui()
	fase = Fase.MESSAGGIO
	
	var calc_name = _get_player_name(idx_calciatore)
	var port_name = _get_player_name(idx_portiere)
	messaggi.text = "=== TURNO %d / %d ===\n%s in Porta\n%s tira per primo" % [turno + 1, MAX_TURNI, port_name, calc_name]

@rpc("authority", "call_local", "reliable")
func _sync_inizia_tiro(idx_calciatore: int, idx_portiere: int) -> void:
	calciatore_corrente = idx_calciatore
	portiere_corrente   = idx_portiere
	scelta_calciatore = 0
	scelta_portiere   = 0
	fase = Fase.SCELTA

	_reset_animazioni()
	
	var my_id = multiplayer.get_unique_id()
	var calc_name = _get_player_name(idx_calciatore)
	var port_name = _get_player_name(idx_portiere)
	
	if GlobalData.players_data[idx_calciatore]["id"] == my_id and not GlobalData.players_data[idx_calciatore].get("is_bot", false):
		messaggi.text = "[SEI IL CALCIATORE]\nUsa A, S, D, F per tirare!"
	elif GlobalData.players_data[idx_portiere]["id"] == my_id and not GlobalData.players_data[idx_portiere].get("is_bot", false):
		messaggi.text = "[SEI IL PORTIERE]\nUsa A, S, D, F per parare!"
	else:
		messaggi.text = "%s Tira | %s Para\nIn attesa..." % [calc_name, port_name]

	if multiplayer.is_server():
		bot_timer = randf_range(1.0, 3.0) 
		tiro_id_corrente += 1
		var current_tiro = tiro_id_corrente
		await get_tree().create_timer(10.0).timeout
		if fase == Fase.SCELTA and current_tiro == tiro_id_corrente:
			_risolvi_tiro_server()

# --- INPUT E BOT ---
func _unhandled_input(event: InputEvent) -> void:
	if not game_started or fase != Fase.SCELTA: return

	var my_id = multiplayer.get_unique_id()
	var p_calc = GlobalData.players_data[calciatore_corrente]
	var p_port = GlobalData.players_data[portiere_corrente]
	
	var sono_calciatore = (p_calc["id"] == my_id and not p_calc.get("is_bot", false))
	var sono_portiere = (p_port["id"] == my_id and not p_port.get("is_bot", false))

	var dir_scelta = 0
	if event.is_action_pressed("paraTiraSin"): dir_scelta = 1
	elif event.is_action_pressed("paraTiraCentroSin"): dir_scelta = 2
	elif event.is_action_pressed("paraTiraCentroDes"): dir_scelta = 3
	elif event.is_action_pressed("paraTiraDes"): dir_scelta = 4

	if dir_scelta != 0:
		if sono_calciatore and scelta_calciatore == 0:
			_server_submit_action.rpc_id(1, true, dir_scelta)
		elif sono_portiere and scelta_portiere == 0:
			_server_submit_action.rpc_id(1, false, dir_scelta)

@rpc("any_peer", "call_local", "reliable")
func _server_submit_action(is_kicker: bool, dir: int):
	if not multiplayer.is_server() or fase != Fase.SCELTA: return
	
	var sender = multiplayer.get_remote_sender_id()
	if sender == 0: sender = 1 
	
	var calc_data = GlobalData.players_data[calciatore_corrente]
	var port_data = GlobalData.players_data[portiere_corrente]
	
	if is_kicker and scelta_calciatore == 0:
		if (calc_data["id"] == sender) or (calc_data.get("is_bot", false) and sender == 1):
			scelta_calciatore = dir
			_sync_calciatore_ready.rpc(dir)
			
	elif not is_kicker and scelta_portiere == 0:
		if (port_data["id"] == sender) or (port_data.get("is_bot", false) and sender == 1):
			scelta_portiere = dir
		
	if scelta_calciatore != 0 and scelta_portiere != 0:
		tiro_id_corrente += 1 
		_risolvi_tiro_server()

@rpc("authority", "call_local", "reliable")
func _sync_calciatore_ready(dir: int):
	scelta_calciatore = dir
	calciatore_node.get_node("AnimatedSprite2D").play("Tiro")
	if multiplayer.get_unique_id() != 1:
		messaggi.text += "\n[Il calciatore ha scelto!]"

func _process(delta: float) -> void:
	if not game_started or fase != Fase.SCELTA or not multiplayer.is_server(): return

	bot_timer -= delta
	if bot_timer <= 0.0:
		if GlobalData.players_data[calciatore_corrente].get("is_bot", false) and scelta_calciatore == 0:
			_server_submit_action.rpc_id(1, true, randi_range(1, 4))
		if GlobalData.players_data[portiere_corrente].get("is_bot", false) and scelta_portiere == 0:
			_server_submit_action.rpc_id(1, false, randi_range(1, 4))
		
		bot_timer = 2.0 

# --- RISULTATO E FINE ---
func _risolvi_tiro_server() -> void:
	var sc = scelta_calciatore
	var sp = scelta_portiere
	
	if sc == 0 and sp == 0:
		punteggi[calciatore_corrente] = max(0, punteggi[calciatore_corrente] - 1)
		punteggi[portiere_corrente] = max(0, punteggi[portiere_corrente] - 1)
	elif sc == 0 and sp != 0:
		punteggi[portiere_corrente] += 1
	elif sc != 0 and sp == 0:
		punteggi[calciatore_corrente] += 1
	else:
		if sc != sp: punteggi[calciatore_corrente] += 1
		else: punteggi[portiere_corrente] += 1

	_sync_risultato.rpc(sc, sp, calciatore_corrente, portiere_corrente, punteggi)
	
	await get_tree().create_timer(5.0).timeout
	_gestisci_fine_tiro_server()

@rpc("authority", "call_local", "reliable")
func _sync_risultato(sc: int, sp: int, idx_calc: int, idx_port: int, nuovi_punteggi: Array) -> void:
	fase = Fase.RISULTATO
	punteggi = nuovi_punteggi
	scelta_calciatore = sc
	scelta_portiere   = sp

	if sc != 0:
		if audio_tiro: audio_tiro.play()
		calciatore_node.get_node("AnimatedSprite2D").play("Tiro")
		palla_node.get_node("AnimatedSprite2D").play("Tiro")
		create_tween().tween_property(palla_node, "position", POSIZIONI_PORTA[sc], 0.8)
	
	if sp != 0:
		portiere_node.get_node("AnimatedSprite2D").play(ANIM_PORTIERE[sp])

	var calc_name = _get_player_name(idx_calc)
	var port_name = _get_player_name(idx_port)

	if sc == 0 and sp == 0: 
		messaggi.text = "Timeout! %s e %s perdono 1 punto" % [calc_name, port_name]
		if audio_sbagliato: audio_sbagliato.play()
	elif sc == 0: 
		messaggi.text = "%s non ha tirato!\nPunto a %s" % [calc_name, port_name]
		if audio_sbagliato: audio_sbagliato.play()
	elif sp == 0: 
		messaggi.text = "%s fermo!\nGOAL di %s" % [port_name, calc_name]
		if audio_gol: audio_gol.play()
	elif sc != sp: 
		messaggi.text = "GOAL! %s segna!\nTiro: %s | Parata: %s" % [calc_name, NOME_DIR[sc], NOME_DIR[sp]]
		if audio_gol: audio_gol.play()
	else: 
		messaggi.text = "PARATA! %s blocca %s!" % [port_name, NOME_DIR[sc]]
		if audio_sbagliato: audio_sbagliato.play()

	_aggiorna_ui()
	
	for i in range(4):
		if punteggi[i] >= PUNTI_VITTORIA and not (i in ordine_vittoria):
			ordine_vittoria.append(i)

func _gestisci_fine_tiro_server() -> void:
	if fase == Fase.FINE: return

	if ordine_vittoria.size() >= 3:
		_fine_gioco_server()
		return

	if calciatori_da_tirare.size() > 0: calciatori_da_tirare.remove_at(0)
	calciatori_da_tirare = calciatori_da_tirare.filter(func(g): return not (g in ordine_vittoria))

	if calciatori_da_tirare.size() > 0:
		calciatore_corrente = calciatori_da_tirare[0]
		_sync_messaggio_prossimo_tiro.rpc(calciatore_corrente)
		await get_tree().create_timer(4.0).timeout
		if fase == Fase.MESSAGGIO and game_started:
			_sync_inizia_tiro.rpc(calciatore_corrente, portiere_corrente)
	else:
		turno_corrente += 1
		if turno_corrente >= MAX_TURNI: _fine_gioco_server()
		else: _inizia_turno_server()

@rpc("authority", "call_local", "reliable")
func _sync_messaggio_prossimo_tiro(idx_calciatore: int) -> void:
	calciatore_corrente = idx_calciatore
	fase = Fase.MESSAGGIO
	_reset_animazioni()
	messaggi.text = "Tocca a %s!" % _get_player_name(idx_calciatore)

func _fine_gioco_server() -> void:
	var classifica: Array[int] = []
	classifica.append_array(ordine_vittoria)
	
	var altri: Array[int] = []
	for i in range(4):
		if not (i in classifica): altri.append(i)
		
	altri.sort_custom(func(a, b): return punteggi[a] > punteggi[b])
	classifica.append_array(altri)

	GlobalData.minigame_winners = [classifica[0]] 
	_sync_fine_gioco.rpc(classifica, punteggi.duplicate())
	
	await get_tree().create_timer(5.0).timeout
	_cambia_scena_rpc.rpc()

@rpc("authority", "call_local", "reliable")
func _sync_fine_gioco(classifica: Array, punteggi_finali: Array) -> void:
	fase = Fase.FINE
	punteggi = punteggi_finali

	var testo = "=== FINE PARTITA ===\n\n"
	for pos in range(classifica.size()):
		var g = classifica[pos]
		var nome = _get_player_name(g)
		testo += "%d. %s - %d pt\n" % [pos + 1, nome, punteggi[g]]
		
	messaggi.text = testo
	_aggiorna_ui()

@rpc("authority", "call_local", "reliable")
func _cambia_scena_rpc() -> void:
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")

func _giocatori_attivi() -> Array[int]:
	var attivi: Array[int] = []
	for i in range(4):
		if not (i in ordine_vittoria): attivi.append(i)
	return attivi

func _aggiorna_ui() -> void:
	var l_nodes = [label_g1, label_g2, label_g3, label_g4]
	var my_id = multiplayer.get_unique_id()
	
	for i in range(4):
		if i < GlobalData.players_data.size():
			var p_data = GlobalData.players_data[i]
			var nome = _get_player_name(i)
			l_nodes[i].text = nome + ": " + str(punteggi[i])
			
			if p_data["id"] == my_id and not p_data.get("is_bot", false):
				l_nodes[i].modulate = Color(1, 1, 0)
			else:
				l_nodes[i].modulate = Color(1, 1, 1)

func _reset_animazioni():
	portiere_node.get_node("AnimatedSprite2D").play("Fermo")
	calciatore_node.get_node("AnimatedSprite2D").play("Fermo")
	palla_node.get_node("AnimatedSprite2D").play("Fermo")
	palla_node.position = POSIZIONE_INIZIALE_PALLA
