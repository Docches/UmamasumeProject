extends Node

# --- DATI CONDIVISI MULTIPLAYER ---
var players_data: Array = []
var minigame_winners: Array = []

# --- DATI TABELLONE ---
var player_space_indices: Array = [0, 0, 0, 0]
var player_medals: Array = [0, 0, 0, 0] 
var player_coins: Array = [0, 0, 0, 0]
var current_turn: int = 1
var current_player_index: int = 0

# --- DATI SPECIFICI: RIGORI ---
var turno_corrente: int = 0
var portiere_corrente: int = -1
var calciatore_corrente: int = -1
var punteggi: Array = [0, 0, 0, 0]
var ordine_vittoria: Array = []
var MAX_TURNI: int = 4
var PUNTI_VITTORIA: int = 3

func _ready() -> void:
	# Connettiamo il segnale di disconnessione a livello globale e permanente
	if multiplayer:
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_peer_disconnected(id: int) -> void:
	# 1. Questa logica deve essere eseguita SOLO dal server
	if not multiplayer.is_server(): 
		return
		
	var args = OS.get_cmdline_user_args()
	
	# 2. Il Master Orchestratore non deve MAI autodistruggersi
	if "--master" in args:
		return
		
	# 3. Se siamo in una Stanza di gioco (Game Instance)
	if "--server_instance" in args:
		var active_peers = multiplayer.get_peers()
		
		# In Godot 4, l'ID che si è appena disconnesso non è già più in get_peers()
		if active_peers.size() == 0:
			print("--- [CRITICO] Stanza svuotata. Autodistruzione processo VPS per liberare RAM.")
			get_tree().quit()
