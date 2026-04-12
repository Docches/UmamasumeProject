extends Node

# =============================================================================
# RIGORI CALCIO MULTIPLAYER SERVER-AUTHORITATIVE
# =============================================================================

# --- NODI ---
@onready var messaggi        = $punteggioCambiGiocatori/messaggi
@onready var label_g1        = $punteggioCambiGiocatori/Giocatore1score
@onready var label_g2        = $punteggioCambiGiocatori/Giocatore2score
@onready var label_g3        = $punteggioCambiGiocatori/Giocatore3
@onready var label_g4        = $punteggioCambiGiocatori/Giocatore4
@onready var portiere_node   = $Portiere
@onready var calciatore_node = $Calciatore
@onready var palla_node      = $Palla
@onready var timer_tiro      = $TimerTiroPalla  
@onready var timer_attesa    = $Attesa          

# --- STATO LOCALE DELLA PARTITA ---
enum Fase { MESSAGGIO, SCELTA, RISULTATO, FINE }
var fase: Fase = Fase.MESSAGGIO

# Stato sincronizzato dal server
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

# --- MAPPE COSTANTI ---
const ANIM_PORTIERE = {
	1: "parataSinistra",
	2: "parataCentroSinistra",
	3: "parataCentroDestra",
	4: "parataDestra"
}
const POSIZIONI_PORTA = {
	1: Vector2(363, 262),
	2: Vector2(489, 150),
	3: Vector2(694, 158),
	4: Vector2(760, 257)
}
const POSIZIONE_INIZIALE_PALLA = Vector2(557, 516)
const NOME_DIR = { 1: "Sinistra", 2: "Centro-Sin", 3: "Centro-Des", 4: "Destra" }

# =============================================================================
# AVVIO
# =============================================================================
func _ready() -> void:
	timer_tiro.one_shot   = true
	timer_attesa.one_shot = true
	timer_tiro.timeout.connect(_on_timer_tiro_timeout)
	timer_attesa.timeout.connect(_on_timer_attesa_timeout)

	_aggiorna_ui()

	if multiplayer.is_server():
		await get_tree().create_timer(1.0).timeout
		_inizia_turno_server()

# =============================================================================
# GESTIONE TURNI (Server)
# =============================================================================
func _inizia_turno_server() -> void:
	var attivi = _giocatori_attivi()
	if attivi.size() < 2: 
		_fine_gioco_server()
		return
		
	var idx_portiere = attivi[randi() % attivi.size()]
	var calciatori: Array[int] = []
	for g in attivi:
		if g != idx_portiere:
			calciatori.append(g)
			
	if calciatori.size() > 3: calciatori.resize(3)
	
	_sync_inizio_turno.rpc(turno_corrente, idx_portiere, calciatori[0], calciatori)

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
	_mostra_messaggio("=== TURNO %d / %d ===\nP%d in Porta\nP%d tira per primo" % [turno + 1, MAX_TURNI, idx_portiere + 1, idx_calciatore + 1])

@rpc("authority", "call_local", "reliable")
func _sync_inizia_tiro(idx_calciatore: int, idx_portiere: int) -> void:
	calciatore_corrente = idx_calciatore
	portiere_corrente   = idx_portiere
	scelta_calciatore = 0
	scelta_portiere   = 0
	fase = Fase.SCELTA

	_reset_animazioni()
	
	var is_my_turn = false
	var my_id = multiplayer.get_unique_id()
	
	# Colora o personalizza il messaggio se è il mio turno
	if GlobalData.players_data[idx_calciatore]["id"] == my_id:
		messaggi.text = "[SEI IL CALCIATORE]\nUsa A, S, D, F per tirare!"
	elif GlobalData.players_data[idx_portiere]["id"] == my_id:
		messaggi.text = "[SEI IL PORTIERE]\nUsa A, S, D, F per parare!"
	else:
		messaggi.text = "P%d Tira | P%d Para\nIn attesa..." % [idx_calciatore + 1, idx_portiere + 1]

	if multiplayer.is_server():
		bot_timer = randf_range(1.0, 3.0) 
		timer_tiro.start(10.0)

func _reset_animazioni():
	portiere_node.get_node("AnimatedSprite2D").play("Fermo")
	calciatore_node.get_node("AnimatedSprite2D").play("Fermo")
	palla_node.get_node("AnimatedSprite2D").play("Fermo")
	palla_node.position = POSIZIONE_INIZIALE_PALLA

# =============================================================================
# INPUT CLIENT -> SERVER
# =============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not game_started or fase != Fase.SCELTA: return

	var my_id = multiplayer.get_unique_id()
	var sono_calciatore = (GlobalData.players_data[calciatore_corrente]["id"] == my_id)
	var sono_portiere = (GlobalData.players_data[portiere_corrente]["id"] == my_id)

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
	
	if is_kicker and GlobalData.players_data[calciatore_corrente]["id"] == sender and scelta_calciatore == 0:
		scelta_calciatore = dir
		_sync_calciatore_ready.rpc(dir)
	elif not is_kicker and GlobalData.players_data[portiere_corrente]["id"] == sender and scelta_portiere == 0:
		scelta_portiere = dir
		
	_controlla_entrambi_pronti()

@rpc("authority", "call_local", "reliable")
func _sync_calciatore_ready(dir: int):
	scelta_calciatore = dir
	calciatore_node.get_node("AnimatedSprite2D").play("Tiro")
	if multiplayer.get_unique_id() != 1:
		messaggi.text += "\n[Il calciatore ha scelto!]"

func _controlla_entrambi_pronti() -> void:
	if scelta_calciatore != 0 and scelta_portiere != 0:
		timer_tiro.stop()
		_risolvi_tiro_server()

func _on_timer_tiro_timeout() -> void:
	if multiplayer.is_server(): _risolvi_tiro_server()

# =============================================================================
# RISOLUZIONE E RISULTATO (Server)
# =============================================================================
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

@rpc("authority", "call_local", "reliable")
func _sync_risultato(sc: int, sp: int, idx_calc: int, idx_port: int, nuovi_punteggi: Array) -> void:
	fase = Fase.RISULTATO
	punteggi = nuovi_punteggi
	scelta_calciatore = sc
	scelta_portiere   = sp

	if sc != 0:
		calciatore_node.get_node("AnimatedSprite2D").play("Tiro")
		palla_node.get_node("AnimatedSprite2D").play("Tiro")
		create_tween().tween_property(palla_node, "position", POSIZIONI_PORTA[sc], 0.8)
	
	if sp != 0:
		portiere_node.get_node("AnimatedSprite2D").play(ANIM_PORTIERE[sp])

	if sc == 0 and sp == 0: messaggi.text = "Timeout! P%d e P%d perdono 1 punto" % [idx_calc + 1, idx_port + 1]
	elif sc == 0: messaggi.text = "P%d non ha tirato!\nPunto a P%d" % [idx_calc + 1, idx_port + 1]
	elif sp == 0: messaggi.text = "P%d fermo!\nGOAL di P%d" % [idx_port + 1, idx_calc + 1]
	elif sc != sp: messaggi.text = "GOAL! P%d segna!\nTiro: %s | Parata: %s" % [idx_calc + 1, NOME_DIR[sc], NOME_DIR[sp]]
	else: messaggi.text = "PARATA! P%d blocca %s!" % [idx_port + 1, NOME_DIR[sc]]

	_aggiorna_ui()
	_controlla_nuovi_vincitori()

	if multiplayer.is_server(): timer_attesa.start(5.0)

func _process(delta: float) -> void:
	if not game_started or fase != Fase.SCELTA or not multiplayer.is_server(): return

	bot_timer -= delta
	if bot_timer <= 0.0:
		if GlobalData.players_data[calciatore_corrente]["is_bot"] and scelta_calciatore == 0:
			_server_submit_action(true, randi_range(1, 4))
		if GlobalData.players_data[portiere_corrente]["is_bot"] and scelta_portiere == 0:
			_server_submit_action(false, randi_range(1, 4))

# =============================================================================
# LOOP DI GIOCO E FINE
# =============================================================================
func _controlla_nuovi_vincitori() -> void:
	for i in range(4):
		if punteggi[i] >= PUNTI_VITTORIA and not (i in ordine_vittoria):
			ordine_vittoria.append(i)

func _on_timer_attesa_timeout() -> void:
	if not multiplayer.is_server() or fase == Fase.FINE: return

	if fase == Fase.MESSAGGIO:
		_sync_inizia_tiro.rpc(calciatore_corrente, portiere_corrente)
		return

	if ordine_vittoria.size() >= 3:
		_fine_gioco_server()
		return

	if calciatori_da_tirare.size() > 0: calciatori_da_tirare.remove_at(0)
	
	calciatori_da_tirare = calciatori_da_tirare.filter(func(g): return not (g in ordine_vittoria))

	if calciatori_da_tirare.size() > 0:
		calciatore_corrente = calciatori_da_tirare[0]
		_sync_messaggio_prossimo_tiro.rpc(calciatore_corrente)
	else:
		turno_corrente += 1
		if turno_corrente >= MAX_TURNI: _fine_gioco_server()
		else: _inizia_turno_server()

@rpc("authority", "call_local", "reliable")
func _sync_messaggio_prossimo_tiro(idx_calciatore: int) -> void:
	calciatore_corrente = idx_calciatore
	_mostra_messaggio("Tocca a P%d!" % (idx_calciatore + 1))
	if multiplayer.is_server(): timer_attesa.start(4.0)

func _mostra_messaggio(testo: String) -> void:
	fase = Fase.MESSAGGIO
	messaggi.text = testo

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

@rpc("authority", "call_local", "reliable")
func _sync_fine_gioco(classifica: Array, punteggi_finali: Array) -> void:
	fase = Fase.FINE
	punteggi = punteggi_finali
	timer_tiro.stop()
	timer_attesa.stop()

	var testo = "=== FINE PARTITA ===\n\n"
	for pos in range(classifica.size()):
		var g = classifica[pos]
		testo += "%d. P%d - %d pt\n" % [pos + 1, g + 1, punteggi[g]]
		
	messaggi.text = testo
	_aggiorna_ui()

	if multiplayer.is_server():
		await get_tree().create_timer(5.0).timeout
		_cambia_scena_rpc.rpc()

@rpc("authority", "call_local", "reliable")
func _cambia_scena_rpc() -> void:
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")

func _giocatori_attivi() -> Array[int]:
	var attivi: Array[int] = []
	for i in range(4):
		if not (i in ordine_vittoria): attivi.append(i)
	return attivi

func _aggiorna_ui() -> void:
	label_g1.text = "P1: " + str(punteggi[0])
	label_g2.text = "P2: " + str(punteggi[1])
	label_g3.text = "P3: " + str(punteggi[2])
	label_g4.text = "P4: " + str(punteggi[3])
