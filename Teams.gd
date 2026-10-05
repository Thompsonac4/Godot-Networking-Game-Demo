# INFO Shared team names and colors

@tool
class_name Teams
extends RefCounted

## Shared team palette and helpers.
##
## This is a `class_name` script rather than an autoload on purpose: autoloads
## are not available to `@tool` scripts in the editor, and the team spawner
## needs these colours while you are laying out a map.

const NONE := 0
const RED := 1
const BLUE := 2
const GREEN := 3
const YELLOW := 4

## Teams in pick order. The first N are the ones in play for N teams.
const ORDER := [RED, BLUE, GREEN, YELLOW]
const MIN_COUNT := 2
const MAX_COUNT := 4

## Group that map-placed team spawn points join.
const SPAWN_GROUP := "TeamSpawn"

const NAMES := {
	NONE: "Unassigned",
	RED: "Red",
	BLUE: "Blue",
	GREEN: "Green",
	YELLOW: "Yellow",
}

const COLORS := {
	NONE: Color(0.86, 0.86, 0.86),
	RED: Color(0.93, 0.28, 0.27),
	BLUE: Color(0.29, 0.56, 0.96),
	GREEN: Color(0.36, 0.83, 0.42),
	YELLOW: Color(0.97, 0.81, 0.24),
}


# Display name for a team id
static func team_name(team: int) -> String:
	return String(NAMES.get(team, NAMES[NONE]))


# Color for a team id
static func color(team: int) -> Color:
	return COLORS.get(team, COLORS[NONE])


## The teams in play for a given team count, e.g. 3 -> [RED, BLUE, GREEN].
static func active(count: int) -> Array[int]:
	var result: Array[int] = []
	for i in clampi(count, MIN_COUNT, MAX_COUNT):
		result.append(int(ORDER[i]))
	return result
