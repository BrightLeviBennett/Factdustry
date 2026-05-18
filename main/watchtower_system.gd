extends Node
class_name WatchtowerSystem

## Watchtower aura logic. Each placed Watchtower has a 10-tile radius;
## any turret with its anchor inside that radius gets a +5 tile attack
## range bonus. The bonus scales linearly with the watchtower's network
## efficiency — a brownout'd watchtower contributes proportionally less,
## clamped to a minimum of 0 (no negative bonus).
##
## Public API:
##   get_turret_range_bonus_tiles(turret_anchor: Vector2i) -> float
##   The combat system calls this and adds the result to the turret's
##   base attack_range when computing range_pixels.

const RANGE_TILES := 10.0          # influence radius
const BONUS_TILES := 5.0            # max +range a turret picks up

@onready var main: Node2D = get_node_or_null("/root/Main")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


## Sums every active watchtower whose anchor is within 10 tiles of
## `turret_anchor`, scaled by each tower's current power efficiency.
## Multiple stacking watchtowers are additive — a turret in the overlap
## of two fully-powered towers gets +10 tiles.
func get_turret_range_bonus_tiles(turret_anchor: Vector2i) -> float:
	if main == null:
		return 0.0
	var total: float = 0.0
	var power_sys = main.get_node_or_null("PowerSystem")
	for cell in main.placed_buildings:
		var wt_anchor: Vector2i = main.building_origins.get(cell, cell)
		if wt_anchor != cell:
			continue
		if main.placed_buildings.get(wt_anchor, &"") != &"watchtower":
			continue
		# Only LUMINA watchtowers buff LUMINA turrets. Cross-faction
		# auras would let captured enemy towers leech the player's
		# turrets and vice-versa — feels wrong for a player-owned aura.
		if main.get_building_faction(wt_anchor) != main.Faction.LUMINA:
			continue
		# Distance in tiles between the anchors. Both are 1×1 cells so
		# anchor-to-anchor distance is fine.
		var d_tiles: float = Vector2(turret_anchor).distance_to(Vector2(wt_anchor))
		if d_tiles > RANGE_TILES:
			continue
		# Scale by network efficiency. < 0.5 efficiency still buffs
		# proportionally; 0 = no bonus.
		var eff: float = 1.0
		if power_sys and power_sys.has_method("get_electrical_efficiency"):
			eff = clampf(power_sys.get_electrical_efficiency(wt_anchor), 0.0, 1.0)
		total += BONUS_TILES * eff
	return maxf(0.0, total)
