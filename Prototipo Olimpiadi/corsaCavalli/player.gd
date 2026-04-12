extends CharacterBody2D

# IL CAVALLO ORA E' SOLO UN PUPAZZO VISIVO.
# Non ha bisogno di logica, viene mosso e calcolato dal Gestore della Gara.

func _ready():
	# Blocchiamo qualsiasi velleità del cavallo di muoversi o elaborare fisica da solo
	set_physics_process(false)
	set_process(false)
