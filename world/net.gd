# WebSocket server for viewers: TCPServer + WebSocketPeer.accept_stream. Text frames, JSON both ways.
extends Node

signal message(peer_id: int, msg: Dictionary)

var tcp := TCPServer.new()
var peers := {}   # id -> WebSocketPeer
var next_id := 1

func start(port: int) -> Error:
	var err := tcp.listen(port, "0.0.0.0")
	if err != OK:
		push_error("net: cannot listen on %d (%s)" % [port, err])
	return err

func poll() -> void:
	while tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1 << 16
		ws.outbound_buffer_size = 1 << 22
		ws.max_queued_packets = 4096
		if ws.accept_stream(tcp.take_connection()) == OK:
			peers[next_id] = ws
			next_id += 1
	var dead: Array = []
	for id in peers:
		var ws: WebSocketPeer = peers[id]
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while ws.get_available_packet_count() > 0:
					var pkt := ws.get_packet()
					var v = JSON.parse_string(pkt.get_string_from_utf8())
					if typeof(v) == TYPE_DICTIONARY:
						message.emit(id, v)
			WebSocketPeer.STATE_CLOSED:
				dead.append(id)
	for id in dead:
		peers.erase(id)

func send(id: int, msg: Dictionary) -> void:
	var ws: WebSocketPeer = peers.get(id)
	if ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))

func broadcast(msg: Dictionary) -> void:
	if peers.is_empty():
		return
	var text := JSON.stringify(msg)
	for id in peers:
		var ws: WebSocketPeer = peers[id]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(text)

func count() -> int:
	return peers.size()
