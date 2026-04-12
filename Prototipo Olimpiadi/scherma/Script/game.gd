extends Node

# =========================================================
#  RIFERIMENTI NODI
# =========================================================
@onready var schermitore_destro   = $SchermitoreDestro
@onready var schermitore_sinistro = $SchermitoreSinistro
@onready var punti_g_sinistro     = $CanvasLayer/puntiGsinistro
@onready var punti_g_destro       = $CanvasLayer/puntiGdestro
@onready var messaggi             = $CanvasLayer/messaggi
@onready var timer_colpo          = $colpo
@onready var timer_round          = $durataRound
@onready var timer_attesa         = $attesa

# =========================================================
#  COSTANTI E STATI
# =========================================================
const PUNTI_VITTORIA : int   = 10
const DURATA_ROUND   : float = 45.0
const DURATA_ATTESA  : float = 3.0
const DURATA_PAUSA   : float = 1.5
const RANGE_COLPO    : float = 220.0

const BOT_DELAY_MIN  : float = 0.5
const BOT_DELAY_MAX  : float = 1.5
const BOT_PARA_PROB  : float = 0.6

enum Fase { ATTESA_MESSAGGIO, CADUTA_INIZIALE, GIOCO, COLPO_IN_CORSO, PAUSA_DOPO_SCAMBIO, ROUND_FINITO, FINE_PARTITA }

var fase_attuale : Fase   = Fase.ATTESA_MESSAGGIO
var chi_attacca  : String = ""  
var dir_attacco  : String = ""

# =========================================================
#  STATO PARTITA E MULTIPLAYER
# =========================================================
var idx_sinistro : int = -1  
var idx_destro   : int = -1  

var punti_sinistro : int = 0
var punti_destro   : int = 0
var round_attuale  : int = 1

var vincitore_r1   : int = -1
var vincitore_r2   : int = -1
var vincitore_fin  : int = -1
var accoppiamenti  : Array = []

var pos_inizio_destro   : Vector2
var pos_inizio_sinistro : Vector2

var vel_x_destro   : float = 0.0
var vel_x_sinistro : float = 0.0

var input_dir = {"sinistro": 0.0, "destro": 0.0}

var bot_timer_attacco  : float = 0.0
var bot_sta_aspettando : bool  = false

# =========================================================
#  _READY E SETUP
# =========================================================
func _ready() -> void:
	randomize()
	
	pos_inizio_destro   = schermitore_destro.global_position
	pos_inizio_sinistro = schermitore_sinistro.global_position

	if GlobalData.players_data.is_empty():
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": i+1, "is_bot": i > 0})

	if multiplayer.is_server():
		timer_colpo.wait_time  = 2.0
		timer_colpo.one_shot   = true
		timer_round.wait_time  = DURATA_ROUND
		timer_round.one_shot   = true
		timer_attesa.wait_time = DURATA_ATTESA
		timer_attesa.one_shot  = true

		timer_colpo.timeout.connect(_on_colpo_timeout)
		timer_round.timeout.connect(_on_round_timeout)
		timer_attesa.timeout.connect(_on_attesa_timeout)

		await get_tree().create_timer(1.0).timeout
		_sorteggia_e_avvia()

# =========================================================
#  SORTEGGIO E GESTIONE ROUND (Server-Side)
# =========================================================
func _sorteggia_e_avvia() -> void:
	var indices = [0, 1, 2, 3]
	indices.shuffle()
	accoppiamenti = [ [indices[0], indices[1]], [indices[2], indices[3]], [-1, -1] ]
	round_attuale = 1
	client_avvia_round.rpc(round_attuale, accoppiamenti)

@rpc("authority", "call_local", "reliable")
func client_avvia_round(round_num: int, acc: Array) -> void:
	round_attuale = round_num
	accoppiamenti = acc
	
	punti_sinistro = 0
	punti_destro   = 0
	vel_x_destro   = 0.0
	vel_x_sinistro = 0.0
	input_dir = {"sinistro": 0.0, "destro": 0.0}
	chi_attacca    = ""
	dir_attacco    = ""

	idx_sinistro = accoppiamenti[round_attuale - 1][0]
	idx_destro   = accoppiamenti[round_attuale - 1][1]

	schermitore_destro.global_position   = pos_inizio_destro
	schermitore_sinistro.global_position = pos_inizio_sinistro
	schermitore_destro.reset_stato()
	schermitore_sinistro.reset_stato()

	_aggiorna_ui_punti()

	var nome_round = "SEMIFINALE 1" if round_attuale == 1 else ("SEMIFINALE 2" if round_attuale == 2 else "FINALE")
	messaggi.text = "%s\n%s  ←→  %s\nPrima a %d punti vince!" % [nome_round, _nome_giocatore(idx_sinistro), _nome_giocatore(idx_destro), PUNTI_VITTORIA]

	fase_attuale = Fase.ATTESA_MESSAGGIO
	
	var my_id = multiplayer.get_unique_id()
	var in_game = false
	for ruolo in [idx_sinistro, idx_destro]:
		if GlobalData.players_data[ruolo]["id"] == my_id: in_game = true
	
	if not in_game and my_id != 1:
		messaggi.text += "\n\n[ SEI IN PANCHINA, ATTENDI IL TUO TURNO ]"

	if multiplayer.is_server():
		timer_attesa.wait_time = DURATA_ATTESA
		timer_attesa.start()

func _on_attesa_timeout() -> void:
	match fase_attuale:
		Fase.ATTESA_MESSAGGIO:
			client_set_fase.rpc(Fase.CADUTA_INIZIALE)
			client_set_messaggio.rpc("")
		Fase.PAUSA_DOPO_SCAMBIO:
			client_set_messaggio.rpc("")
			client_set_fase.rpc(Fase.GIOCO)
			client_abilita_input.rpc(true)
		Fase.ROUND_FINITO:
			_prossimo_round_o_fine()
		Fase.FINE_PARTITA:
			_chiudi_partita()

# =========================================================
#  INPUT LOCALE (Client) -> Invia al Server
# =========================================================
var last_dir = 0.0

func _process(delta: float) -> void:
	if fase_attuale == Fase.GIOCO and not multiplayer.is_server():
		var ruolo = _get_mio_ruolo()
		if ruolo != "":
			var dir : float = 0.0
			if Input.is_action_pressed("muoviAvantiSin"):
				dir = 1.0 if ruolo == "sinistro" else -1.0
			elif Input.is_action_pressed("muoviIndietroSin"):
				dir = -1.0 if ruolo == "sinistro" else 1.0

			if dir != last_dir:
				server_request_movimento.rpc_id(1, ruolo, dir)
				last_dir = dir
				
	if multiplayer.is_server():
		if fase_attuale == Fase.CADUTA_INIZIALE:
			if schermitore_destro.sul_pavimento and schermitore_sinistro.sul_pavimento:
				client_set_fase.rpc(Fase.GIOCO)
				client_abilita_input.rpc(true)
				timer_round.start()
				
		elif fase_attuale == Fase.COLPO_IN_CORSO:
			_gestisci_bot_parata(delta)
			
		elif fase_attuale == Fase.GIOCO:
			client_set_messaggio.rpc("⏱ %d" % int(ceil(timer_round.time_left)))
			_aggiorna_movimento_server()
			_gestisci_bot_attacco(delta)

func _unhandled_input(event: InputEvent) -> void:
	var ruolo = _get_mio_ruolo()
	if ruolo == "" or (fase_attuale != Fase.GIOCO and fase_attuale != Fase.COLPO_IN_CORSO): return

	if fase_attuale == Fase.GIOCO:
		if event.is_action_pressed("colpisciAltoSin"): server_request_attacco.rpc_id(1, ruolo, "Alto")
		elif event.is_action_pressed("colpisciBassoSin"): server_request_attacco.rpc_id(1, ruolo, "Basso")

	if event.is_action_pressed("paraAltoSin"): server_request_parata.rpc_id(1, ruolo, "Alto", true)
	elif event.is_action_pressed("paraBassoSin"): server_request_parata.rpc_id(1, ruolo, "Basso", true)
	elif event.is_action_released("paraAltoSin") or event.is_action_released("paraBassoSin"):
		server_request_parata.rpc_id(1, ruolo, "", false)

func _get_mio_ruolo() -> String:
	var my_id = multiplayer.get_unique_id()
	if not _è_bot(idx_sinistro) and GlobalData.players_data[idx_sinistro]["id"] == my_id: return "sinistro"
	if not _è_bot(idx_destro) and GlobalData.players_data[idx_destro]["id"] == my_id: return "destro"
	return ""

# =========================================================
#  RICEZIONE INPUT SUL SERVER
# =========================================================
@rpc("any_peer", "call_local", "unreliable")
func server_request_movimento(ruolo: String, dir: float):
	if multiplayer.is_server() and fase_attuale == Fase.GIOCO:
		input_dir[ruolo] = dir

@rpc("any_peer", "call_local", "reliable")
func server_request_attacco(ruolo: String, direzione: String):
	if multiplayer.is_server() and fase_attuale == Fase.GIOCO:
		_tenta_attacco(ruolo, direzione)

@rpc("any_peer", "call_local", "reliable")
func server_request_parata(ruolo: String, direzione: String, attiva: bool):
	if multiplayer.is_server():
		client_sync_parata.rpc(ruolo, direzione, attiva)

# =========================================================
#  FISICA E LOGICA (Server)
# =========================================================
func _aggiorna_movimento_server() -> void:
	if not _è_bot(idx_sinistro) and not schermitore_sinistro.in_attacco and not schermitore_sinistro.in_parata:
		vel_x_sinistro = input_dir["sinistro"] * schermitore_sinistro.SPEED
	else: vel_x_sinistro = 0.0

	if not _è_bot(idx_destro) and not schermitore_destro.in_attacco and not schermitore_destro.in_parata:
		vel_x_destro = input_dir["destro"] * schermitore_destro.SPEED
	else: vel_x_destro = 0.0

	if schermitore_sinistro.può_muoversi:
		schermitore_sinistro.set_velocita(vel_x_sinistro)
		schermitore_sinistro.aggiorna_animazione_movimento(vel_x_sinistro)

	if schermitore_destro.può_muoversi:
		schermitore_destro.set_velocita(vel_x_destro)
		schermitore_destro.aggiorna_animazione_movimento(-vel_x_destro)

	client_sync_posizioni.rpc(schermitore_sinistro.global_position, schermitore_destro.global_position, vel_x_sinistro, vel_x_destro)

func _tenta_attacco(chi: String, direzione: String) -> void:
	var dist = abs(schermitore_destro.global_position.x - schermitore_sinistro.global_position.x)
	if dist > RANGE_COLPO: return

	chi_attacca = chi
	dir_attacco = direzione
	bot_sta_aspettando = false

	client_esegui_attacco.rpc(chi, direzione)
	client_abilita_input.rpc(false)
	timer_colpo.start()

	var idx_difensore = idx_sinistro if chi == "destro" else idx_destro
	if _è_bot(idx_difensore):
		bot_timer_attacco = randf_range(BOT_DELAY_MIN, BOT_DELAY_MAX)
		bot_sta_aspettando = true

# =========================================================
#  BOT INTELLIGENCE
# =========================================================
func _gestisci_bot_attacco(_delta: float) -> void:
	for ruolo in ["sinistro", "destro"]:
		var idx = idx_sinistro if ruolo == "sinistro" else idx_destro
		if not _è_bot(idx): continue
			
		var sch = schermitore_sinistro if ruolo == "sinistro" else schermitore_destro
		if sch.in_attacco or sch.in_parata or not sch.può_muoversi: continue

		var dist = abs(schermitore_destro.global_position.x - schermitore_sinistro.global_position.x)
		if dist > RANGE_COLPO:
			input_dir[ruolo] = 1.0 if ruolo == "sinistro" else -1.0
		else:
			input_dir[ruolo] = 0.0
			if randf() < 0.015: _tenta_attacco(ruolo, "Alto" if randf() < 0.5 else "Basso")

func _gestisci_bot_parata(delta: float) -> void:
	if not bot_sta_aspettando: return
	bot_timer_attacco -= delta
	if bot_timer_attacco > 0: return

	bot_sta_aspettando = false
	if randf() < BOT_PARA_PROB:
		var dir_para = dir_attacco
		if randf() < 0.2: dir_para = "Basso" if dir_attacco == "Alto" else "Alto"
		var ruolo_difensore = "sinistro" if chi_attacca == "destro" else "destro"
		client_sync_parata.rpc(ruolo_difensore, dir_para, true)

# =========================================================
#  RISOLUZIONE E FINE ROUND
# =========================================================
func _on_colpo_timeout() -> void:
	if fase_attuale != Fase.COLPO_IN_CORSO: return

	var difensore_para : bool
	var dir_para       : String

	if chi_attacca == "destro":
		difensore_para = schermitore_sinistro.in_parata
		dir_para       = schermitore_sinistro.get_direzione_parata()
	else:
		difensore_para = schermitore_destro.in_parata
		dir_para       = schermitore_destro.get_direzione_parata()

	var parata_ok = difensore_para and (dir_para == dir_attacco)

	client_reset_azioni.rpc()

	if parata_ok:
		client_set_messaggio.rpc("⚔️ Parata!")
	else:
		if chi_attacca == "destro": punti_destro += 1
		else: punti_sinistro += 1
		client_aggiorna_punti.rpc(punti_sinistro, punti_destro)
		client_set_messaggio.rpc("🎯 Punto!")

	chi_attacca = ""
	dir_attacco = ""

	if punti_destro >= PUNTI_VITTORIA or punti_sinistro >= PUNTI_VITTORIA:
		_fine_round()
		return

	client_set_fase.rpc(Fase.PAUSA_DOPO_SCAMBIO)
	timer_attesa.wait_time = DURATA_PAUSA
	timer_attesa.start()

func _on_round_timeout() -> void:
	if fase_attuale == Fase.GIOCO or fase_attuale == Fase.COLPO_IN_CORSO:
		timer_colpo.stop()
		_fine_round()

func _fine_round() -> void:
	timer_round.stop()
	client_abilita_input.rpc(false)
	client_set_fase.rpc(Fase.ROUND_FINITO)

	var vincitore_idx : int
	if punti_sinistro > punti_destro: vincitore_idx = idx_sinistro
	elif punti_destro > punti_sinistro: vincitore_idx = idx_destro
	else: vincitore_idx = [idx_sinistro, idx_destro][randi() % 2]

	match round_attuale:
		1: vincitore_r1  = vincitore_idx
		2: vincitore_r2  = vincitore_idx
		3: vincitore_fin = vincitore_idx

	var msg = "Vince %s!\n%d - %d\n\nProssimo round..." % [_nome_giocatore(vincitore_idx), punti_sinistro, punti_destro]
	client_set_messaggio.rpc(msg)

	timer_attesa.wait_time = DURATA_ATTESA
	timer_attesa.start()

func _prossimo_round_o_fine() -> void:
	round_attuale += 1
	if round_attuale == 3:
		accoppiamenti[2][0] = vincitore_r1
		accoppiamenti[2][1] = vincitore_r2
		client_avvia_round.rpc(round_attuale, accoppiamenti)
	elif round_attuale > 3:
		client_set_fase.rpc(Fase.FINE_PARTITA)
		timer_attesa.wait_time = DURATA_ATTESA
		timer_attesa.start()
	else:
		client_avvia_round.rpc(round_attuale, accoppiamenti)

func _chiudi_partita() -> void:
	client_mostra_risultati_finali.rpc(vincitore_fin, _secondo(), _perdente(0), _perdente(1))

# =========================================================
#  RPC CLIENT (UI E AZIONI VISIVE)
# =========================================================
@rpc("authority", "call_local", "reliable")
func client_set_fase(f: Fase) -> void:
	fase_attuale = f

@rpc("authority", "call_local", "reliable")
func client_set_messaggio(testo: String) -> void:
	messaggi.text = testo

@rpc("authority", "call_local", "reliable")
func client_abilita_input(valore: bool) -> void:
	schermitore_destro.set_input_abilitato(valore)
	schermitore_sinistro.set_input_abilitato(valore)

@rpc("authority", "call_local", "reliable")
func client_aggiorna_punti(psin: int, pdes: int) -> void:
	punti_sinistro = psin
	punti_destro   = pdes
	_aggiorna_ui_punti()

@rpc("authority", "call_local", "reliable")
func client_reset_azioni() -> void:
	schermitore_destro.termina_attacco()
	schermitore_sinistro.termina_attacco()
	schermitore_destro.termina_parata()
	schermitore_sinistro.termina_parata()

@rpc("authority", "call_local", "reliable")
func client_esegui_attacco(chi: String, direzione: String):
	fase_attuale = Fase.COLPO_IN_CORSO
	if chi == "destro": schermitore_destro.esegui_attacco(direzione)
	else: schermitore_sinistro.esegui_attacco(direzione)

@rpc("authority", "call_local", "reliable")
func client_sync_parata(ruolo: String, direzione: String, attiva: bool):
	var sch = schermitore_sinistro if ruolo == "sinistro" else schermitore_destro
	if attiva and direzione != "": sch.esegui_parata(direzione)
	elif not attiva and sch.in_parata and fase_attuale != Fase.COLPO_IN_CORSO: sch.termina_parata()

@rpc("authority", "call_local", "unreliable")
func client_sync_posizioni(pos_sin: Vector2, pos_des: Vector2, vx_sin: float, vx_des: float) -> void:
	schermitore_sinistro.global_position = pos_sin
	schermitore_destro.global_position   = pos_des
	schermitore_sinistro.aggiorna_animazione_movimento(vx_sin)
	schermitore_destro.aggiorna_animazione_movimento(-vx_des)

@rpc("authority", "call_local", "reliable")
func client_mostra_risultati_finali(vince: int, secondo: int, perdente1: int, perdente2: int) -> void:
	fase_attuale = Fase.FINE_PARTITA

	if multiplayer.is_server():
		GlobalData.minigame_winners = [vince]

	messaggi.text = "TORNEO FINITO!\n1° %s\n2° %s\n3° %s\n4° %s" % [_nome_giocatore(vince), _nome_giocatore(secondo), _nome_giocatore(perdente1), _nome_giocatore(perdente2)]
	
	if multiplayer.is_server():
		await get_tree().create_timer(4.0).timeout
		ritorna_al_tabellone.rpc()

@rpc("authority", "call_local", "reliable")
func ritorna_al_tabellone():
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")

# =========================================================
#  HELPERS E UTILITY
# =========================================================
func _è_bot(idx: int) -> bool:
	if idx < 0 or idx >= GlobalData.players_data.size(): return true
	return GlobalData.players_data[idx].get("is_bot", false)

func _nome_giocatore(idx: int) -> String:
	if idx < 0 or idx >= GlobalData.players_data.size(): return "???"
	var d = GlobalData.players_data[idx]
	var n = "P" + str(d["id"])
	if d.get("is_bot", false): n = "Bot " + str(idx + 1)
	return n

func _secondo() -> int:
	return accoppiamenti[2][1] if accoppiamenti[2][0] == vincitore_fin else accoppiamenti[2][0]

func _perdente(round_idx: int) -> int:
	var sin = accoppiamenti[round_idx][0]
	var des = accoppiamenti[round_idx][1]
	return des if (round_idx == 0 and vincitore_r1 == sin) or (round_idx == 1 and vincitore_r2 == sin) else sin

func _aggiorna_ui_punti() -> void:
	punti_g_sinistro.text = "%s: %d" % [_nome_giocatore(idx_sinistro), punti_sinistro]
	punti_g_destro.text   = "%s: %d" % [_nome_giocatore(idx_destro),   punti_destro]
