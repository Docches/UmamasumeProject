extends Node2D

@export var stone_team_1: PackedScene
@export var stone_team_2: PackedScene

@onready var house_center: Marker2D = $HouseCenter # Assicurati che il nodo Marker2D si chiami così

var current_stone: RigidBody2D = null
var active_stone: RigidBody2D = null 
var check_stop: bool = false 

var clicked = false
var initialPosition: Vector2
const MAX_POWER: float = 300.0
const SWEEP_FORCE: float = 6.0 
const MAX_SWEEP_SPEED: float = 12.0 
var current_impulse: Vector2 = Vector2.ZERO

var current_turn: int = 0 
var stones_thrown: int = 0
const MAX_STONES: int = 6 # Metti 16 per una manche intera (8 per squadra)
const HOUSE_RADIUS: float = 150.0 # Raggio massimo per fare punto. Modificalo in base alla tua grafica

func _ready() -> void:
	spawn_stone()

func spawn_stone() -> void:
	if stones_thrown >= MAX_STONES:
		return 
		
	if stone_team_1 == null or stone_team_2 == null:
		push_error("Assegna entrambe le scene delle stone nell'Inspector.")
		return
		
	var scene_to_spawn: PackedScene
	if current_turn == 0:
		scene_to_spawn = stone_team_1
	else:
		scene_to_spawn = stone_team_2
		
	current_stone = scene_to_spawn.instantiate()
	current_stone.add_to_group("stones")
	
	# Memorizziamo di quale squadra è questa stone specifica
	current_stone.set_meta("team", current_turn) 
	
	add_child(current_stone)
	
	var screen_size = get_viewport_rect().size
	current_stone.position = Vector2(100, screen_size.y / 2.0)
	
	stones_thrown += 1

func _physics_process(_delta: float) -> void:
	if check_stop:
		# --- LOGICA SPAZZAMENTO ---
		if active_stone != null:
			var sweep_dir = Vector2.ZERO
			
			if Input.is_action_pressed("up"):
				sweep_dir.y -= 1
			if Input.is_action_pressed("down"):
				sweep_dir.y += 1
				
			if sweep_dir != Vector2.ZERO:
				active_stone.apply_central_force(sweep_dir * SWEEP_FORCE)
				
				var current_vel = active_stone.linear_velocity
				current_vel.y = clamp(current_vel.y, -MAX_SWEEP_SPEED, MAX_SWEEP_SPEED)
				active_stone.linear_velocity = current_vel

		# Controllo arresto globale
		var all_stopped = true
		var all_stones = get_tree().get_nodes_in_group("stones")
		
		for s in all_stones:
			if s.linear_velocity.length() >= 5.0:
				all_stopped = false
				break 
				
		if all_stopped:
			for s in all_stones:
				s.linear_velocity = Vector2.ZERO 
			
			active_stone = null 
			check_stop = false
			current_turn = (current_turn + 1) % 2
			
			# Se abbiamo lanciato tutte le stone, calcola chi ha vinto
			if stones_thrown >= MAX_STONES:
				calcola_punteggio()
			else:
				spawn_stone()
		return 

	# Controllo lancio
	if current_stone == null:
		return 

	if Input.is_action_just_pressed("action"):
		initialPosition = get_global_mouse_position()
		clicked = true

	if clicked:
		var current_mouse = get_global_mouse_position()
		current_impulse = (initialPosition - current_mouse).limit_length(MAX_POWER)
		queue_redraw() 

	if Input.is_action_just_released("action") and clicked:
		clicked = false
		current_stone.apply_central_impulse(current_impulse)
		
		active_stone = current_stone 
		current_stone = null 
		current_impulse = Vector2.ZERO
		queue_redraw() 
		
		get_tree().create_timer(0.5).timeout.connect(func(): check_stop = true)

func _draw() -> void:
	if clicked and current_stone != null:
		var num_punti = 6 
		var dot_color = Color.RED if current_turn == 0 else Color.YELLOW
			
		for i in range(1, num_punti + 1):
			var frazione = float(i) / float(num_punti)
			var punto_pos = current_stone.position + (current_impulse * frazione)
			
			draw_circle(punto_pos, 4.0, dot_color)

func calcola_punteggio() -> void:
	var all_stones = get_tree().get_nodes_in_group("stones")
	var stone_valide = []
	
	# 1. Trova le stone dentro la "house"
	for s in all_stones:
		var distanza = s.global_position.distance_to(house_center.global_position)
		if distanza <= HOUSE_RADIUS:
			stone_valide.append({"nodo": s, "distanza": distanza, "team": s.get_meta("team")})
			
	# Se nessuna stone è nell'area valida
	if stone_valide.is_empty():
		print("Manche nulla (0 - 0). Nessuna stone a punto.")
		return
		
	# 2. Ordina l'array di dizionari in base alla distanza (dal più vicino al più lontano)
	stone_valide.sort_custom(func(a, b): return a["distanza"] < b["distanza"])
	
	# 3. Conta i punti
	var team_vincente = stone_valide[0]["team"]
	var punti = 0
	
	for s in stone_valide:
		if s["team"] == team_vincente:
			punti += 1
		else:
			# Alla prima stone dell'avversario incontrata, interrompiamo il conteggio
			break 
			
	var nome_team = "Team 1" if team_vincente == 0 else "Team 2"
	print("Vince il ", nome_team, " con ", punti, " punti!")
