extends SceneTree

## The relay process: godot --headless -s relay/relay_main.gd -- --port 43211
## Runs on the droplet under systemd (relay/rootkit-relay.service).

var _server := RelayServer.new()

func _initialize() -> void:
	var port := SessionRules.RELAY_PORT
	var punch_port := SessionRules.PUNCH_DISCOVERY_PORT
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--punch-port" and i + 1 < args.size():
			punch_port = int(args[i + 1])
	var err := _server.start(port, punch_port)
	if err != OK:
		push_error("relay: could not bind UDP %d (%s)" % [port, error_string(err)])
		quit(1)
		return
	print("relay: listening on UDP %d" % port)

func _process(_dt: float) -> bool:
	_server.poll(Time.get_ticks_msec())
	return false
