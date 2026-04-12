extends Node

# =========================================================
#  DATI DEL GIOCO (board game)
# =========================================================
var player_space_indices: Array[int] = [0, 0, 0, 0]
var current_player_index: int = 0
var is_first_board_load: bool = true
var current_turn: int = 1
var player_coins: Array = [10, 10, 10, 10]
var player_medals: Array = [0, 0, 0, 0]

# =========================================================
#  NETWORKING
# =========================================================
var peer = ENetMultiplayerPeer.new()
var is_server: bool = false
const DEFAULT_PORT = 8080

var connected_peers: Array[int] = []

# players_data è un array di 4 dizionari, uno per giocatore:
# { "id": int,        ← peer ID (1 per server, 0 per bot)
#   "is_bot": bool,
#   "name": String }
var players_data: Array[Dictionary] = []

# =========================================================
#  RISULTATI MINIGIOCO
# =========================================================
var minigame_winners: Array[int] = []

# =========================================================
#  FUNZIONI DI CONNESSIONE
# =========================================================
func host_game() -> void:
	is_server = true
	peer.create_server(DEFAULT_PORT, 4)
	multiplayer.multiplayer_peer = peer
	print("Server avviato sulla porta ", DEFAULT_PORT)

func join_game(ip: String) -> void:
	is_server = false
	peer.create_client(ip, DEFAULT_PORT)
	multiplayer.multiplayer_peer = peer
	print("Connessione a: ", ip)
