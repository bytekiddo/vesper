# The HUD: top bar, status line, event ticker, citizen panel, newspaper. Pure presentation; the viewer feeds it.
extends CanvasLayer

var top_label: Label
var status_label: Label
var events_label: Label
var panel: PanelContainer
var panel_text: RichTextLabel
var panel_title: Label
var news_panel: PanelContainer
var news_text: RichTextLabel
var news_list: ItemList
var journal := {"name": "", "issues": []}
var on_close: Callable

func build(close_cb: Callable) -> void:
	on_close = close_cb
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(top)
	var row := HBoxContainer.new()
	top.add_child(row)
	top_label = Label.new()
	top_label.text = "Vesper"
	top_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(top_label)
	var news_btn := Button.new()
	news_btn.text = "Newspaper"
	news_btn.pressed.connect(func(): news_panel.visible = not news_panel.visible)
	row.add_child(news_btn)
	status_label = Label.new()
	status_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	status_label.position = Vector2(8, -28)
	status_label.modulate = Color(1, 1, 1, 0.8)
	add_child(status_label)
	events_label = Label.new()
	events_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	events_label.position = Vector2(8, -140)
	events_label.custom_minimum_size = Vector2(520, 100)
	events_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	events_label.modulate = Color(1, 1, 1, 0.85)
	add_child(events_label)

	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _opaque())
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -420
	panel.offset_top = 36
	panel.visible = false
	add_child(panel)
	var pv := VBoxContainer.new()
	panel.add_child(pv)
	var ph := HBoxContainer.new()
	pv.add_child(ph)
	panel_title = Label.new()
	panel_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(panel_title)
	var close := Button.new()
	close.text = "x"
	close.pressed.connect(func(): panel.visible = false; on_close.call())
	ph.add_child(close)
	panel_text = RichTextLabel.new()
	panel_text.bbcode_enabled = true
	panel_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_text.selection_enabled = true
	pv.add_child(panel_text)

	news_panel = PanelContainer.new()
	news_panel.add_theme_stylebox_override("panel", _opaque())
	news_panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	news_panel.offset_right = 560
	news_panel.offset_top = 36
	news_panel.offset_bottom = -150
	news_panel.visible = false
	add_child(news_panel)
	var nv := VBoxContainer.new()
	news_panel.add_child(nv)
	news_list = ItemList.new()
	news_list.custom_minimum_size = Vector2(0, 120)
	news_list.item_selected.connect(show_issue)
	nv.add_child(news_list)
	news_text = RichTextLabel.new()
	news_text.bbcode_enabled = true
	news_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	news_text.selection_enabled = true
	nv.add_child(news_text)

func _opaque() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.15, 0.96)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

func set_status(text: String) -> void:
	status_label.text = text

func update(clock: Dictionary, budget: Dictionary, stats: Dictionary, events: Array, history: Array, map: Dictionary, alive: int, catching_up: bool, connected: bool, world: Dictionary = {}) -> void:
	var w := int(map.get("w", 0))
	var h := int(map.get("h", 0))
	var nb: int = map.get("buildings", []).size()
	var growth := ""
	if history.size() > 1:
		var first: Dictionary = history[0]
		growth = "  (day %d: %d people, %d buildings, %dx%d)" % [int(first.day), int(first.pop), int(first.buildings), int(first.w), int(first.h)]
	var sky := ("   ·   %s, %s" % [str(world.get("season", "")), str(world.get("weather", ""))]) if world.has("season") else ""
	top_label.text = "  VESPER   %s %s  %s%s   |   population %d   |   map %dx%d, %d buildings%s   |   budget $%.2f / $%.0f this month  (%s)%s" % [
		clock.get("weekday", ""), str(clock.get("date", "")), clock.get("hhmm", ""), sky, alive, w, h, nb, growth, float(budget.get("month_total", 0.0)),
		float(budget.get("budget", 400)), str(budget.get("model", "")), "   |   the town is dreaming through an outage (catching up)" if catching_up else ""]
	var lines := PackedStringArray()
	for e in events.slice(maxi(0, events.size() - 6)):
		lines.append("• " + str(e.text))
	events_label.text = "\n".join(lines)
	if connected:
		status_label.text = "tick %d   conversations %d   births %d   deaths %d   arrivals %d   departures %d   consciousness calls %d" % [
			int(clock.get("tick", 0)), int(stats.get("conversations", 0)), int(stats.get("births", 0)), int(stats.get("deaths", 0)), int(stats.get("arrivals", 0)), int(stats.get("departures", 0)), int(stats.get("tier2_calls", 0))]

func show_citizen(c: Dictionary) -> void:
	panel.visible = true
	panel_title.text = "%s, %d (%s) — %s" % [c.name, int(c.age), c.pronouns, c.occupation]
	var t := "[b]Mood:[/b] %s    [b]Now:[/b] %s\n[b]Thought:[/b] [i]%s[/i]\n\n" % [c.mood, c.action, c.thought]
	t += "[b]Innate:[/b] %s\n[b]Learned:[/b] %s\n[b]Lifestyle:[/b] %s\n[b]Currently:[/b] %s\n[b]Home:[/b] %s   [b]Work:[/b] %s   [b]Arrived:[/b] %s\n\n" % [c.innate, c.learned, c.lifestyle, c.currently, c.home, c.work, c.arrived]
	t += "[b]Plan for today[/b] %s\n" % ("(their own)" if c.plan_is_tier2 else "(habit)")
	for b in c.plan:
		t += "  %s  %s — %s\n" % [b.at, b.place, b.action]
	t += "\n[b]Relationships[/b]\n"
	for r in c.relationships:
		t += "  %s — %s (%.2f) %s\n" % [r.name, r.kind, float(r.score), r.note]
	if c.conv.size() > 0:
		t += "\n[b]Talking now[/b]\n"
		for l in c.conv:
			t += "  %s\n" % l
	t += "\n[b]Recent memories[/b]\n"
	var mems: Array = c.memories
	mems.reverse()
	for m in mems:
		t += "  [color=#aaaaaa]%s[/color] [%s %d] %s\n" % [m.when, m.kind, int(m.imp), m.text]
	t += "\n[b]Conversation log[/b]\n"
	var chats: Array = c.conversations
	chats.reverse()
	for ch in chats:
		t += "  [color=#aaaaaa]%s[/color] %s\n" % [ch.when, ch.text]
	panel_text.text = t

func update_news(j: Dictionary) -> void:
	journal = j
	news_list.clear()
	for issue in journal.get("issues", []):
		news_list.add_item(str(issue.title))
	var name := str(journal.get("name", ""))
	if journal.get("issues", []).size() > 0:
		show_issue(0)
	else:
		news_text.text = "[i]%s[/i]\n\nNo issue has been printed yet. The Chronicler names the paper on its first run." % (name if name != "" else "The newspaper has no name yet.")

func show_issue(i: int) -> void:
	var issues: Array = journal.get("issues", [])
	if i < 0 or i >= issues.size():
		return
	var text := str(issues[i].text)
	var out := PackedStringArray()   # tiny markdown: headings and bold
	for line in text.split("\n"):
		if line.begins_with("# "):
			out.append("[font_size=18][b]%s[/b][/font_size]" % line.substr(2))
		elif line.begins_with("## "):
			out.append("[font_size=14][b]%s[/b][/font_size]" % line.substr(3))
		else:
			out.append(line.replace("**", "[b]"))
	news_text.text = "\n".join(out)
