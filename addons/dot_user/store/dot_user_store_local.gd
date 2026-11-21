class_name DotUserStoreLocal
extends DotUserStore

## Profiles as JSON files under a directory. The default, and it works unconfigured.
##
## One file per profile rather than one file for all of them. A single file is simpler
## until two things happen, and both of them do: a server with a few thousand
## returning players rewrites the whole file on every change, and a crash midway
## through that rewrite loses every profile rather than one.
##
## [b]The filename is the profile key, and the key is checked before it becomes a
## path.[/b] A scoped id is base64url, which is filesystem-safe by construction, and
## [method DotUserScope.is_well_formed] is enforced in [DotUserStore] before any
## implementation sees it. That is the guard against a key containing
## [code]../[/code] and the store writing outside its directory. [DotPaths.safe_relative]
## re-checks it here, because a boundary worth defending is worth defending twice when
## the second check is one call.

const LOCAL_CHANNEL := "user.store.local"

## Directory holding the profiles.
var directory: String = "user://profiles"

## Write via a temporary file and rename over the target.
##
## Without it a crash during a write leaves a truncated JSON file, which fails to
## parse on the next read. With the manager's "a failed read keeps what is in force"
## rule that is survivable, but the profile is still gone.
##
## [DotSaveStoreFile] does the temporary file, the rename and the browser's filesystem
## flush. Re-implementing it here was the first version of this file and was wrong
## twice: it forgot that [method DirAccess.rename] does not overwrite on every platform,
## and it forgot [method DotWeb.sync_filesystem], so every profile written on a web build
## was lost when the tab closed.
var atomic_writes: bool = true

var _files: DotSaveStoreFile


static func at(path: String) -> DotUserStoreLocal:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var s := new()
	s.directory = path
	return s


func _store_name() -> String:
	return "DotUserStoreLocal"


func _open() -> DotResult:
	var made := DotPaths.ensure_dir(directory)

	if not made.ok:
		return made.wrap("Could not open the profile directory.")

	DotLog.debug(LOCAL_CHANNEL, "profile store open", {"directory": directory})
	return DotResult.success(true)


## The file store under this one, with the folder and write mode as they stand now.
func files() -> DotSaveStoreFile:
	if _files == null:
		_files = DotSaveStoreFile.new()
		_files.suffix = ".json"
		_files.key_check = func(key: String) -> bool: return DotPaths.safe_relative(key + ".json").ok
	_files.directory = directory
	_files.atomic = atomic_writes
	return _files


func _path_for(user_key: String) -> DotResult:
	var relative := DotPaths.safe_relative("%s.json" % user_key)

	if not relative.ok:
		return relative.wrap("That profile key is not a usable filename.")

	return DotResult.success(files().path_for(user_key))


func _fetch(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	var file: String = path.value

	if not FileAccess.file_exists(file):
		return DotResult.success(null)

	var read := DotPaths.read_json(file)

	if not read.ok:
		# A file that exists and will not parse is a real failure, not an absence.
		# Reporting it as "no profile" would make the manager create a fresh one and
		# write it over the damaged file, destroying whatever could have been
		# recovered by hand.
		return read.wrap("A stored profile could not be read.")

	var data: Variant = read.value

	if not (data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"A stored profile is not an object.",
			file
		)

	return DotUserProfile.from_dict(data as Dictionary)


func _store(profile: DotUserProfile) -> DotResult:
	var path := _path_for(profile.user_key)

	if not path.ok:
		return path

	var written := files().write(profile.user_key, JSON.stringify(profile.to_dict(), "\t"))

	if not written.ok:
		return written.wrap("Could not write the profile.")

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(true)

	var removed := files().remove(user_key)

	if not removed.ok:
		return removed.wrap("Removing the profile")

	return DotResult.success(true)


## Every profile key the directory holds.
##
## For an admin tool and for migrations, not for the join path: it lists a directory,
## which is exactly the kind of work the store contract says must not happen while a
## player is waiting.
func list_keys() -> DotResult:
	if not is_open():
		var opened := await open()
		if not opened.ok:
			return opened

	var keys := PackedStringArray()

	for key in files().keys():
		# Anything else in the directory is somebody else's file, or a leftover
		# temporary. Listing it would hand a malformed key to a caller that
		# reasonably assumes this returns keys.
		if DotUserScope.is_well_formed(key):
			keys.append(key)

	return DotResult.success(keys)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	out["atomic"] = atomic_writes
	return out
