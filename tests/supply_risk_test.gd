extends SceneTree
## Late supplier deliveries: draws at PO creation, the hidden outcome, the notice time, saves and the agent event.

const Line = preload("res://simulation/production_line.gd")
const Save = preload("res://erp/save_game.gd")
const API = preload("res://agent/agent_api.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_disabled()
	_distribution()
	_determinism()
	_reveal()
	_settings()
	_persistence()
	_agent()
	print("Supply risk: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Factory loads: " + line.validation_error)
	return line


## Water goes to a tank, so receipts never wait for rack space.
func _buy(book) -> Dictionary:
	return book.purchases[book.purchase("SUP-03", "RM-WATER", 5.0).id]


## First PO of the given lateness outcome under the book's seed.
func _find(book, late: bool) -> Dictionary:
	for i in 200:
		var po := _buy(book)
		if po.risk.late == late and (not late or po.risk.lateness > 0.2):
			return po
	return {}


func _disabled() -> void:
	var book = _line().erp
	_check(book.supply_risk.enabled and is_equal_approx(book.supply_risk.probability, 0.25), "Supply risk is on by default at 25 %")
	book.supply_risk.enabled = false
	var po := _buy(book)
	_check(not po.has("risk") and is_equal_approx(po.due, book.now + 60.0), "Disabled: no draw, due at created + lead")


func _distribution() -> void:
	var book = _line().erp
	var count := 2000
	var late := 0
	var lateness := 0.0
	var notice := 0.0
	var ok := true
	for i in count:
		var po := _buy(book)
		var risk: Dictionary = po.risk
		_check(po.has("created") and is_equal_approx(po.lead, 60.0), "PO keeps its creation time and lead")
		ok = ok and is_equal_approx(risk.late_due, po.created + (1.0 + risk.lateness) * po.lead) \
			and risk.reveal_at >= po.created and risk.reveal_at <= po.created + 0.8 * po.lead + 1e-6 \
			and risk.lateness >= 0.0 and is_equal_approx(po.due, po.created + po.lead) and not risk.revealed
		notice += (risk.reveal_at - po.created) / po.lead
		if risk.late:
			late += 1
			lateness += risk.lateness
	_check(ok, "Every PO: late date = created + (1 + lateness) x lead, notice within 0-0.8 lead, due unchanged until notice")
	var share := float(late) / count
	_check(share > 0.22 and share < 0.28, "About 25 %% of POs are late (%.3f)" % share)
	# Lateness ~ N(1, 1) floored at 0 has mean 1.083.
	var mean := lateness / maxi(1, late)
	_check(mean > 0.97 and mean < 1.2, "Mean lateness about 1.08 lead times (%.3f)" % mean)
	_check(absf(notice / count - 0.4) < 0.03, "Notice is uniform on 0-0.8 lead, mean 0.4 (%.3f)" % (notice / count))


func _determinism() -> void:
	var a = _line().erp
	var b = _line().erp
	var same := true
	for i in 50:
		var x := _buy(a)
		var y := _buy(b)
		same = same and x.risk.hash() == y.risk.hash()
	_check(same, "Same seed and PO numbers give the same draws")
	var c = _line().erp
	c.set_supply_risk({"seed": 99})
	var differ := false
	for id in a.purchases:
		var z := _buy(c)
		differ = differ or z.risk.reveal_at != a.purchases[id].risk.reveal_at
	_check(differ, "Another seed gives other draws")


func _reveal() -> void:
	var line := _line()
	var book = line.erp
	var po := _find(book, true)
	var calm := _find(book, false)
	_check(not po.is_empty() and not calm.is_empty(), "Found a late and an on-time PO")
	if po.is_empty() or calm.is_empty():
		return
	var original: float = po.due
	line.set_playing(true)
	line.advance(maxf(0.0, po.risk.reveal_at - book.now - 1.5))
	_check(is_equal_approx(po.due, original) and not po.has("late_notice"), "Before the notice the PO shows its normal due time")
	line.advance(3.0)
	_check(po.has("late_notice") and is_equal_approx(po.due, po.risk.late_due) and is_equal_approx(po.original_due, original),
		"At the notice time the due date moves to the late date (%s -> %s)" % [original, po.due])
	line.advance(original - book.now + 2.0)
	_check(po.status == "Open", "Nothing arrives at the original due time")
	_check(calm.status == "Received" and not calm.has("late_notice"), "An on-time PO arrives at its due time")
	line.advance(po.due - book.now + 2.0)
	_check(po.status == "Received", "The late PO arrives at its late date")


func _settings() -> void:
	var book = _line().erp
	_check(not book.set_supply_risk({"probability": 1.5}).is_empty(), "Probability above 1 is refused")
	_check(not book.set_supply_risk({"color": 1}).is_empty(), "Unknown settings are refused")
	_check(book.set_supply_risk({"probability": 1.0}).is_empty(), "Probability 1 is accepted")
	var all_late := true
	for i in 20:
		all_late = all_late and _buy(book).risk.late
	_check(all_late, "Probability 1 makes every PO late")


func _persistence() -> void:
	var line := _line()
	var book = line.erp
	book.set_supply_risk({"seed": 7})
	var po := _find(book, true)
	var path := "user://supply_risk_test.save"
	_check(Save.save(line, path).is_empty(), "Save")
	var loaded := Save.load_line(path)
	_check(loaded.error.is_empty(), "Load: " + String(loaded.error))
	if loaded.error.is_empty():
		var other = loaded.line.erp
		_check(other.supply_risk.seed == 7 and other.purchases[po.id].risk.hash() == po.risk.hash(), "Settings and hidden draws survive a save")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _agent() -> void:
	var api := API.new()
	_check(api.handle({"cmd": "set_supply_risk", "args": {"probability": 1.0, "reveal_max": 0.0}}).get("error", "x") == "", "Agent sets supply risk")
	var bought := api.handle({"cmd": "purchase", "args": {"supplier": "SUP-03", "code": "RM-WATER", "quantity": 5}})
	_check(not bought.has("risk") and not str(bought).contains("late_due"), "The agent does not see the outcome at purchase")
	var run := api.handle({"cmd": "run_until", "args": {"max_seconds": 30, "stop_on": ["po_late"]}})
	var events: Array = run.get("events", [])
	_check(events.any(func(row: Dictionary) -> bool: return row.kind == "po_late" and row.po == bought.id and row.new_due >= row.original_due),
		"run_until stops on po_late with the new due time: %s" % str(run))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
