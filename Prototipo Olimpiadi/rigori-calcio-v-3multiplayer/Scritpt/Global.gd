extends Node

# --- DATI DEL GIOCO PRINCIPALE (non modificare) ---
var player_space_indices: Array[int] = [0, 0, 0, 0]
var current_player_index: int = 0
var is_first_board_load: bool = true

# --- NETWORKING ---
var peer = ENetMultiplayerPeer.new()
var is_server: bool = false
const DEFAULT_PORT = 8080

var connected_peers: Array[int] = []
var players_data: Array[Dictionary] = []

# --- VINCITORI MINIGIOCO ---
var minigame_winners: Array[int] = []

# --- DATI RIGORI ---
var punteggi: Array[int] = [0, 0, 0, 0]
var ordine_vittoria: Array[int] = []
var turno_corrente: int = 0
const MAX_TURNI: int = 4
const PUNTI_VITTORIA: int = 3
var portiere_corrente: int = 0
var calciatore_corrente: int = 0

# --- NETWORKING ---
func host_game():
	is_server = true
	peer.create_server(DEFAULT_PORT, 5)
	multiplayer.multiplayer_peer = peer
	print("Server avviato")

func join_game(ip: String):
	is_server = false
	peer.create_client(ip, DEFAULT_PORT)
	multiplayer.multiplayer_peer = peer
	print("Tentativo di connessione a: ", ip)
