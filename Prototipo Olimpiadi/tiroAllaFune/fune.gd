extends Node2D

const PULL_STRENGTH: float = 5.0
const WIN_LIMIT_LEFT: float = 350.0
const WIN_LIMIT_RIGHT: float = 800.0

enum GameState { TUTORIAL, COUNTDOWN, PLAYING, ENDED }
var current_state = GameState.TUTORIAL

@export var immagine_fazzoletto: Texture2D
@export var immagine_team_sinistra: Texture2D
@export var immagine_team_destra: Texture2D

@onready var fazzoletto: Sprite2D = $Fazzoletto
@onready var status_label: Label = $UI/StatusLabel
@onready var countdown_label: Label = $UI/CountdownLabel
@onready var tutorial_panel: ColorRect = $UI/TutorialPanel
@onready var team_sx_label: Label = $UI/TutorialPanel/TeamSinistraText
@onready var team_dx_label: Label = $UI/TutorialPanel/TeamDestraText

var bot_timers: Dictionary = {}
var tween_fazzoletto: Tween

# L'indice del giocatore locale (0-3), -1 se è un server headless
var my_slot_index: int = -1 

func _ready() -> void:
	countdown_label.text = ""
	status_label.text = ""
	tutorial_panel.show()
	
	# PREVENZIONE CRASH (Test F6)
	if GlobalData.players_data.is_empty():
		print("ATTENZIONE: Avvio Standalone Fune. Generazione Bot in corso...")
		var peer = ENetMultiplayerPeer.new()
		peer.create_server(12345, 4)
		multiplayer.multiplayer_peer = peer
		for i in range(4):
			GlobalData.players_data.append({"id": 1 if i==0 else i+100, "is_bot": i>0, "name": "Tester" if i==0 else "BOT"})
	
	_applica_sprite_personalizzati()
	_assegna_slot_locale()
	_compila_testi_tutorial()
	
	if multiplayer.is_server():
		for i in range(GlobalData.players_data.size()):
			var p = GlobalData.players_data[i]
			if p.get("is_bot", false):
				bot_timers[i] = randf_range(0.15, 0.25)
		_server_avvia_routine()

func _assegna_slot_locale() -> void:
	var my_id = multiplayer.get_unique_id()
	for i in range(GlobalData.players_data.size()):
		var p = GlobalData.players_data[i]
		if p["id"] == my_id and not p.get("is_bot", false):
			my_slot_index = i
			break

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

func _compila_testi_tutorial() -> void:
	var testo_sx = "TEAM SINISTRA (Spazio per tirare):\n"
	var testo_dx = "TEAM DESTRA (Spazio per tirare):\n"
	
	var my_id = multiplayer.get_unique_id()
	
	for i in range(GlobalData.players_data.size()):
		var p = GlobalData.players_data[i]
		var nome = _get_player_name(i)
		
		if p["id"] == my_id and not p.get("is_bot", false):
			nome = "[color=yellow]" + nome + " (TU)[/color]"
			if i < 2:
				testo_sx = "[color=yellow]" + testo_sx + "[/color]"
			else:
				testo_dx = "[color=yellow]" + testo_dx + "[/color]"
		
		if i < 2: testo_sx += "- " + nome + "\n"
		else: testo_dx += "- " + nome + "\n"
			
	team_sx_label.text = testo_sx
	team_dx_label.text = testo_dx
	
	# Abilita il BBCode (colori) nei nodi Label se necessario (RichTextLabel)
	# Per compatibilità base lasciamo Label semplice, se usi RichText vedrai i colori.

func _applica_sprite_personalizzati() -> void:
	if immagine_fazzoletto:
		fazzoletto.texture = immagine_fazzoletto
		fazzoletto.modulate = Color.WHITE
		
	if immagine_team_sinistra:
		$TeamSinistra/Player0.texture = immagine_team_sinistra
		$TeamSinistra/Player1.texture = immagine_team_sinistra
		$TeamSinistra/Player0.modulate = Color.WHITE
		$TeamSinistra/Player1.modulate = Color.WHITE
		
	if immagine_team_destra:
		$TeamDestra/Player2.texture = immagine_team_destra
		$TeamDestra/Player3.texture = immagine_team_destra
		$TeamDestra/Player2.modulate = Color.WHITE
		$TeamDestra/Player3.modulate = Color.WHITE

# --- 1. LOGICA SERVER (COUNTDOWN) ---

func _server_avvia_routine() -> void:
	await get_tree().create_timer(4.5).timeout
	client_nascondi_tutorial.rpc()
	
	current_state = GameState.COUNTDOWN
	client_sync_state.rpc(GameState.COUNTDOWN)
	
	for i in range(3, 0, -1):
		client_sync_countdown.rpc(str(i))
		await get_tree().create_timer(1.0).timeout
		
	client_sync_countdown.rpc("SPAMMA SPAZIO!")
	current_state = GameState.PLAYING
	client_sync_state.rpc(GameState.PLAYING)
	
	await get_tree().create_timer(1.0).timeout
	if current_state == GameState.PLAYING:
		client_sync_countdown.rpc("")

# --- 2. INPUT E FISICA ---

func _unhandled_input(event: InputEvent) -> void:
	if current_state != GameState.PLAYING or my_slot_index == -1: return
		
	if event.is_action_pressed("ui_accept", false) and not event.is_echo():
		server_receive_pull.rpc_id(1)

@rpc("any_peer", "call_local", "reliable")
func server_receive_pull() -> void:
	if current_state != GameState.PLAYING or not multiplayer.is_server(): return
	var sender_id = multiplayer.get_remote_sender_id()
	
	var slot = -1
	for i in range(GlobalData.players_data.size()):
		if GlobalData.players_data[i]["id"] == sender_id:
			slot = i
			break
			
	if slot != -1:
		_server_process_pull(slot)

func _process(delta: float) -> void:
	if current_state != GameState.PLAYING or not multiplayer.is_server(): return
		
	for bot_index in bot_timers.keys():
		bot_timers[bot_index] -= delta
		if bot_timers[bot_index] <= 0.0:
			_server_process_pull(bot_index)
			bot_timers[bot_index] = randf_range(0.18, 0.28)

func _server_process_pull(slot: int) -> void:
	if current_state != GameState.PLAYING: return
		
	if slot == 0 or slot == 1:
		fazzoletto.position.x -= PULL_STRENGTH
	elif slot == 2 or slot == 3:
		fazzoletto.position.x += PULL_STRENGTH
		
	client_sync_fazzoletto.rpc(fazzoletto.position.x)
	_server_check_win_condition()

# --- 3. GESTIONE VITTORIA E UI (CLIENT) ---

func _server_check_win_condition() -> void:
	if fazzoletto.position.x <= WIN_LIMIT_LEFT:
		_server_declare_winner("SINISTRA", [0, 1])
	elif fazzoletto.position.x >= WIN_LIMIT_RIGHT:
		_server_declare_winner("DESTRA", [2, 3])

func _server_declare_winner(team_side: String, winner_slots: Array) -> void:
	current_state = GameState.ENDED
	client_sync_state.rpc(GameState.ENDED)
	
	GlobalData.minigame_winners = winner_slots.duplicate()
	
	var nomi_vincitori = _get_player_name(winner_slots[0]) + " & " + _get_player_name(winner_slots[1])
	
	client_show_winner_ui.rpc(nomi_vincitori)
	
	await get_tree().create_timer(4.0).timeout
	client_ritorna_al_tabellone.rpc()

@rpc("authority", "call_local", "unreliable_ordered")
func client_sync_fazzoletto(new_x: float) -> void:
	if tween_fazzoletto and tween_fazzoletto.is_running():
		tween_fazzoletto.kill()
		
	tween_fazzoletto = create_tween()
	tween_fazzoletto.tween_property(fazzoletto, "position:x", new_x, 0.08).set_trans(Tween.TRANS_SINE)

@rpc("authority", "call_local", "reliable")
func client_nascondi_tutorial() -> void:
	tutorial_panel.hide()

@rpc("authority", "call_local", "reliable")
func client_sync_state(new_state: int) -> void:
	current_state = new_state
	match current_state:
		GameState.COUNTDOWN: status_label.text = "PREPARATI..."
		GameState.PLAYING: status_label.text = "TIRA!"

@rpc("authority", "call_local", "reliable")
func client_sync_countdown(text: String) -> void:
	countdown_label.text = text

@rpc("authority", "call_local", "reliable")
func client_show_winner_ui(nomi_vincitori: String) -> void:
	status_label.text = "🏆 VITTORIA PER " + nomi_vincitori + "! 🏆"
	countdown_label.text = ""

@rpc("authority", "call_local", "reliable")
func client_ritorna_al_tabellone() -> void:
	get_tree().change_scene_to_file("res://tabellone/tabellone.tscn")
