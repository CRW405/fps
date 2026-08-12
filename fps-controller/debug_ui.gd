extends CanvasLayer

@export var visible_by_default := true

var player : PlayerController


func _ready() -> void:
	player = get_parent() as PlayerController
	visible = visible_by_default


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_debug"):
		visible = not visible

	if not visible or not player: return
	_refresh_display()


func _refresh_display() -> void:
	var state := player.get_debug_state()
	var lines := PackedStringArray()
	for key in state:
		lines.append("%s: %s" % [String(key).capitalize(), _format_value(state[key])])
	%StateLabel.text = "\n".join(lines)


func _format_value(value) -> String:
	if value is Vector3:
		return "(%.2f, %.2f, %.2f)" % [value.x, value.y, value.z]
	if value is float:
		return "%.2f" % value
	return str(value)
