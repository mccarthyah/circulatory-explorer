extends RefCounted
## Local, versioned visibility saves. The file is per user, not per project.
## Do not overwrite unreadable or newer files. Write a temporary file first and
## keep a backup while replacing the old one (Godot's Windows rename removes the
## destination before moving, so it cannot itself guarantee atomic replacement).

const DEFAULT_PATH := "user://visibility_presets.json"
const VERSION := 1
const REGIONS := ["all", "torso", "lower", "head", "heart", "cardiac"]
const MAX_BYTES := 4 * 1024 * 1024


func _path() -> String:
	var override := OS.get_environment("EXPLORER_VISIBILITY_PATH")
	return override if not override.is_empty() else DEFAULT_PATH


func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}


func _valid_name(name: String) -> bool:
	if name.is_empty() or name != name.strip_edges() or name.length() > 60:
		return false
	for c in name:
		if c.unicode_at(0) < 32 or c.unicode_at(0) == 127:
			return false
	return true


func _valid_state(state) -> bool:
	if not state is Dictionary or not state.get("hidden") is Array or state["hidden"].size() > 3000:
		return false
	for id in state["hidden"]:
		if not id is String or id.is_empty() or id.length() > 64:
			return false
	return true


func _read() -> Dictionary:
	var path := _path()
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak"):
		path += ".bak" # Recovery after interruption while replacing the file.
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": {"version": VERSION, "regions": {}}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("Could not read visibility saves (error %d)." % FileAccess.get_open_error())
	if file.get_length() > MAX_BYTES:
		return _error("Visibility saves file is too large; it was not changed.")
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("version") != VERSION or not parsed.get("regions") is Dictionary:
		return _error("Visibility saves file is invalid or from a newer version; it was not changed.")
	for region in parsed["regions"]:
		if region not in REGIONS or not parsed["regions"][region] is Dictionary:
			return _error("Visibility saves file contains invalid regions; it was not changed.")
		for name in parsed["regions"][region]:
			if not name is String or not _valid_name(name) or not _valid_state(parsed["regions"][region][name]):
				return _error("Visibility saves file contains invalid entries; it was not changed.")
	return {"ok": true, "data": parsed}


func list_names(region: String) -> Dictionary:
	if region not in REGIONS:
		return _error("Unknown view.")
	var result := _read()
	if not result.ok:
		return result
	var names: Array = result.data.regions.get(region, {}).keys()
	names.sort_custom(func(a, b): return String(a).naturalnocasecmp_to(String(b)) < 0)
	return {"ok": true, "names": names}


func load_preset(region: String, name: String) -> Dictionary:
	var result := _read()
	if not result.ok:
		return result
	var entries: Dictionary = result.data.regions.get(region, {})
	if not entries.has(name):
		return _error("That visibility save no longer exists in this view.")
	return {"ok": true, "state": entries[name].duplicate(true)}


func save_preset(region: String, name: String, state: Dictionary, overwrite: bool = false) -> Dictionary:
	name = name.strip_edges()
	if region not in REGIONS:
		return _error("Unknown view.")
	if not _valid_name(name):
		return _error("Enter a name between 1 and 60 characters, without control characters.")
	if not _valid_state(state):
		return _error("Could not save an invalid visibility state.")
	var result := _read()
	if not result.ok:
		return result
	var data: Dictionary = result.data
	if not data.regions.has(region):
		data.regions[region] = {}
	if data.regions[region].has(name) and not overwrite:
		return _error("A save with that name already exists. Confirm replacement first.")
	data.regions[region][name] = state.duplicate(true)
	return _write(data)


func delete_preset(region: String, name: String) -> Dictionary:
	var result := _read()
	if not result.ok:
		return result
	var data: Dictionary = result.data
	if not data.regions.has(region) or not data.regions[region].has(name):
		return _error("That visibility save no longer exists in this view.")
	data.regions[region].erase(name)
	return _write(data)


func _write(data: Dictionary) -> Dictionary:
	var path := ProjectSettings.globalize_path(_path())
	var temp := path + ".tmp"
	var backup := path + ".bak"
	var text := JSON.stringify(data, "  ") + "\n"
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _error("Visibility saves file would be too large; it was not changed.")
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return _error("Could not write visibility saves (error %d)." % FileAccess.get_open_error())
	file.store_string(text)
	file.flush()
	var err := file.get_error()
	file.close()
	if err != OK:
		DirAccess.remove_absolute(temp)
		return _error("Could not write visibility saves (error %d)." % err)
	var had_original := FileAccess.file_exists(path)
	if had_original:
		if FileAccess.file_exists(backup) and DirAccess.remove_absolute(backup) != OK:
			DirAccess.remove_absolute(temp)
			return _error("Could not clear an old visibility backup; the save was not changed.")
		if DirAccess.rename_absolute(path, backup) != OK:
			DirAccess.remove_absolute(temp)
			return _error("Could not back up visibility saves; the save was not changed.")
	if DirAccess.rename_absolute(temp, path) != OK:
		if had_original:
			DirAccess.rename_absolute(backup, path)
		DirAccess.remove_absolute(temp)
		return _error("Could not replace visibility saves; check the save directory.")
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	return {"ok": true}
