extends CharacterBody2D

# Lo schermitore NON legge input direttamente.
# Tutti i comandi arrivano da game.gd tramite chiamate dirette (sul server)
# o tramite sync RPC (sui client).

@onready var anim : AnimatedSprite2D = $AnimatedSprite2D

const SPEED   : float = 250.0
const GRAVITY : float = 900.0

var sul_pavimento : bool = false
var può_muoversi  : bool = false
var in_attacco    : bool = false
var in_parata     : bool = false

func _ready() -> void:
	anim.play("posizioneIniziale")

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += GRAVITY * delta
		sul_pavimento = false
	else:
		velocity.y = 0
		if not sul_pavimento:
			sul_pavimento = true
			if not può_muoversi:
				anim.play("fermo")

	move_and_slide()

# --- API pubblica (chiamata da game.gd) ---

func set_velocita(vx: float) -> void:
	velocity.x = vx

func set_input_abilitato(valore: bool) -> void:
	può_muoversi = valore
	if not valore:
		velocity.x = 0
		if sul_pavimento and not in_attacco and not in_parata:
			anim.play("fermo")

func esegui_attacco(direzione: String) -> void:
	if in_attacco:
		return
	in_attacco = true
	velocity.x = 0
	anim.play("attaccoAlto" if direzione == "Alto" else "attaccoBasso")

func termina_attacco() -> void:
	if not in_attacco:
		return
	in_attacco = false
	if sul_pavimento:
		anim.play("fermo")

func esegui_parata(direzione: String) -> void:
	if in_parata and get_direzione_parata() == direzione:
		return
	in_parata = true
	velocity.x = 0
	anim.play("paraAlto" if direzione == "Alto" else "paraBasso")

func termina_parata() -> void:
	if not in_parata:
		return
	in_parata = false
	if sul_pavimento and not in_attacco:
		anim.play("fermo")

func get_direzione_parata() -> String:
	if anim.animation == "paraAlto":  return "Alto"
	if anim.animation == "paraBasso": return "Basso"
	return ""

func aggiorna_animazione_movimento(dir: float) -> void:
	if in_attacco or in_parata:
		return
	if dir < 0:
		anim.play("camminataAvanti")
	elif dir > 0:
		anim.play("camminataIndietro")
	else:
		anim.play("fermo")

func reset_stato() -> void:
	in_attacco    = false
	in_parata     = false
	può_muoversi  = false
	sul_pavimento = false
	velocity      = Vector2.ZERO
	anim.play("posizioneIniziale")
