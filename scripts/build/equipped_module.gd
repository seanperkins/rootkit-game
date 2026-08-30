class_name EquippedModule extends RefCounted

var module: Module
var rank: int = 1

func _init(m: Module, r: int = 1) -> void:
	module = m
	rank = r

func can_rank_up() -> bool:
	return rank < module.max_rank
