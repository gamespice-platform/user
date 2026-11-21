class_name GSUserStoreMemory
extends GSUserStore

## Profiles in a dictionary, lost on exit.
##
## For tests, for a scrim server that should not accumulate anything, and as the
## thing every other implementation is checked against: the self-test runs the same
## sequence through this and through [GSUserStoreLocal] and requires the same
## answers, so a bug in the file handling shows up as a difference rather than as a
## plausible-looking result.
##
## Also the honest default for a server with [code]persist_profiles[/code] off. The
## alternative, a store that silently does nothing, makes "my name did not save" a
## bug report instead of a setting.

var _profiles: Dictionary = {}

## Made to fail on the next call, for testing the recovery paths.
##
## A store that never fails is a store whose failure handling is never exercised, and
## the failure handling here is the part that matters: a blip must not wipe a
## returning player's profile.
var fail_next_fetch: bool = false
var fail_next_store: bool = false


func _store_name() -> String:
	return "GSUserStoreMemory"


func _fetch(user_key: String) -> GSResult:
	if fail_next_fetch:
		fail_next_fetch = false
		return GSResult.fail(
			GSError.CODE_IO, "Simulated fetch failure.", user_key
		)

	if not _profiles.has(user_key):
		# Absent, not failed. See GSUserStore._fetch.
		return GSResult.success(null)

	# Rebuilt from the stored dictionary rather than handed out by reference, so a
	# caller mutating what it got back cannot alter the store behind its own API.
	return GSUserProfile.from_dict(_profiles[user_key])


func _store(profile: GSUserProfile) -> GSResult:
	if fail_next_store:
		fail_next_store = false
		return GSResult.fail(
			GSError.CODE_IO, "Simulated store failure.", profile.user_key
		)

	_profiles[profile.user_key] = profile.to_dict()
	return GSResult.success(true)


func _remove(user_key: String) -> GSResult:
	_profiles.erase(user_key)
	return GSResult.success(true)


func size() -> int:
	return _profiles.size()


func clear() -> void:
	_profiles.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["profiles"] = _profiles.size()
	return out
