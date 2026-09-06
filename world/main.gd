# Entry point. Headless (or --server) => canonical world server. Otherwise => the viewer.
extends Node

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless" or args.has("--server"):
		var server := preload("res://world/server.gd").new()
		server.smoke_mode = args.has("--dev")   # throwaway world: fresh seed, genesis = now, port 9002, stubbed model
		add_child(server)
	else:
		add_child(preload("res://viewer/viewer.gd").new())
