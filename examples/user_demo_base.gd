extends Node

## Shared counters, assertions and the first sections of the dot-user self-test.

const SCOPE_KEY := "user://test_scope.key"
const PROFILE_DIR := "user://test_profiles"

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


## A stand-in for DotAuthIdentity, which is not installed here.
##
## dot-user duck-types the identity on purpose, so this is not a shim around a
## missing dependency — it is the whole contract: uid, display_name, is_guest.
class FakeIdentity extends RefCounted:
	var uid: String = ""
	var display_name: String = ""
	var is_guest: bool = false
	var claims: Dictionary = {}

	## What dot-auth's scoped introspection produces: no account id, the backbone's key.
	static func site(key: String, name: String) -> FakeIdentity:
		var i := FakeIdentity.new()
		i.uid = "tmc:%s" % key
		i.display_name = name
		i.claims = {"scoped_key": key}
		return i

	static func account(id: String, name: String) -> FakeIdentity:
		var i := FakeIdentity.new()
		i.uid = "backbone:%s" % id
		i.display_name = name
		return i

	static func guest(id: String, name: String) -> FakeIdentity:
		var i := FakeIdentity.new()
		i.uid = "guest:%s" % id
		i.display_name = name
		i.is_guest = true
		return i


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())




func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition



func _test_scope() -> void:
	_section("scoped identity")

	var key := DotHash.random_bytes(32)
	var server_a := DotUserScope.with_key("server:a", key)
	var server_b := DotUserScope.with_key("server:b", key)

	var a1 := server_a.derive("account-1")
	var a2 := server_a.derive("account-1")
	var b1 := server_b.derive("account-1")

	_check(a1.ok and a2.ok and b1.ok, "derivation succeeds")
	_check(a1.value == a2.value, "the same account on the same server is stable")

	# The whole point. Two operators comparing logs must not be able to tell that
	# these are the same person.
	_check(
		a1.value != b1.value,
		"the same account on a different server is a different id"
	)

	var other := server_a.derive("account-2")
	_check(a1.value != other.value, "different accounts differ on one server")

	_check(
		DotUserScope.is_well_formed(a1.value),
		"a derived id is well formed",
		str(a1.value)
	)
	_check(
		String(a1.value).length() == DotUserScope.ID_LENGTH,
		"and the documented length"
	)

	# Without a separator, ("ab", "cd") and ("abc", "d") share a MAC input and two
	# different players share one profile.
	var s1 := DotUserScope.with_key("ab", key).derive("cd")
	var s2 := DotUserScope.with_key("abc", key).derive("d")
	_check(
		s1.value != s2.value,
		"the scope separator stops a boundary collision",
		"%s vs %s" % [s1.value, s2.value]
	)
	_test_scope_keys(key, server_a, a1)


func _test_scope_keys(key: PackedByteArray, server_a: DotUserScope, a1: DotResult) -> void:
	# A different key is a different namespace. That is what makes the derivation
	# non-reversible by anyone who does not hold the key.
	var stranger := DotUserScope.with_key("server:a", DotHash.random_bytes(32))
	_check(
		stranger.derive("account-1").value != a1.value,
		"a different key derives a different id, so it cannot be recomputed"
	)

	_check(
		server_a.matches("account-1", a1.value),
		"an id verifies against its account"
	)
	_check(
		not server_a.matches("account-2", a1.value),
		"and does not verify against another"
	)

	var keyless := DotUserScope.new()
	keyless.scope = "server:a"
	_check(
		not keyless.derive("account-1").ok,
		"a scope with no key refuses rather than deriving something useless"
	)
	_check(
		not DotUserScope.with_key("", key).derive("a").ok,
		"an empty scope name is refused"
	)
	_check(
		not server_a.derive("").ok, "an empty account id is refused"
	)

	# The key has to survive a restart, or every profile is renamed.
	var exported := server_a.export_secret_key()
	var restored := DotUserScope.from_secret_key("server:a", exported)

	_check(restored.ok, "a scope key round-trips through storage")
	_check(
		restored.ok and (restored.value as DotUserScope).derive("account-1").value == a1.value,
		"and derives the same ids afterwards"
	)

	_check(
		not DotUserScope.from_secret_key("server:a", "c2hvcnQ").ok,
		"a too-short key is refused rather than silently weakening every id"
	)

	# describe() is pasted into bug reports.
	var described := server_a.describe()
	_check(
		not str(described).contains(exported),
		"describe() never leaks the key"
	)

	for bad in ["", "short", "has spaces in it here!!", "a".repeat(40)]:
		_check(
			not DotUserScope.is_well_formed(bad),
			"'%s' is not mistaken for an id" % bad.substr(0, 20)
		)
	_done()



func _test_names() -> void:
	_section("display names")

	_check(DotUserName.sanitise("  Ada  ") == "Ada", "spaces are trimmed")
	_check(
		DotUserName.sanitise("Ada    Lovelace") == "Ada Lovelace",
		"runs of spaces collapse"
	)

	# A newline in a name splits one log line into two, one of which the player wrote.
	_check(
		not DotUserName.sanitise("Ada\nAdmin").contains("\n"),
		"newlines are removed"
	)
	_check(
		DotUserName.sanitise("Ada\nAdmin") == "Ada Admin",
		"and become a space rather than joining two words",
		DotUserName.sanitise("Ada\nAdmin")
	)

	# U+202E reverses the text after it, so a name rewrites the sentence it is in.
	var bidi := "Ada%sniamdA" % String.chr(0x202E)
	_check(
		not DotUserName.sanitise(bidi).contains(String.chr(0x202E)),
		"bidirectional overrides are stripped"
	)

	# Two names that render identically is impersonation a moderator cannot see.
	var zero_width := "Ad%sa" % String.chr(0x200B)
	_check(
		DotUserName.sanitise(zero_width) == "Ada",
		"zero-width characters are stripped"
	)

	var zalgo := "Ada" + String.chr(0x0301).repeat(30)
	_check(
		DotUserName.sanitise(zalgo) == "Ada",
		"stacked combining marks are stripped"
	)

	_check(DotUserName.clean("Ada").ok, "an ordinary name is accepted")
	_check(not DotUserName.clean("A").ok, "a one-character name is refused")
	_check(
		not DotUserName.clean("a".repeat(40)).ok, "an over-long name is refused"
	)
	_check(
		not DotUserName.clean("   ").ok,
		"a name that is empty once sanitised is refused"
	)
	_check(
		not DotUserName.clean("!!!...").ok,
		"a name with no letters is refused, so nobody is invisible on a scoreboard"
	)
	_test_name_limits()


func _test_name_limits() -> void:
	# The byte bound and the character bound have to agree, or one of them is
	# unreachable and nobody notices until a name of the wrong shape gets through.
	var widest := String.chr(0x1F600).repeat(DotUserName.MAX_LENGTH)
	_check(
		DotUserName.clean(widest).ok,
		"the widest name inside the character limit is accepted"
	)
	_check(
		widest.to_utf8_buffer().size() <= DotUserName.MAX_BYTES,
		"and is within the byte bound, which the character limit implies",
		"%d bytes, cap %d" % [widest.to_utf8_buffer().size(), DotUserName.MAX_BYTES]
	)
	_check(
		not DotUserName.clean(
			String.chr(0x1F600).repeat(DotUserName.MAX_LENGTH + 1)
		).ok,
		"and one character more is refused"
	)

	# Name squatting.
	_check(
		DotUserName.comparison_key("Ada Lovelace")
			== DotUserName.comparison_key("adalovelace"),
		"case and spaces do not make a distinct name"
	)
	_check(
		DotUserName.comparison_key("Ada") == DotUserName.comparison_key("Ad4"),
		"nor do lookalike digits"
	)
	_check(
		DotUserName.comparison_key("Ada") != DotUserName.comparison_key("Bob"),
		"but genuinely different names stay different"
	)

	var fallback := DotUserName.fallback_for("abcdefghijklmnopqrstuv")
	_check(
		fallback == DotUserName.fallback_for("abcdefghijklmnopqrstuv"),
		"a fallback name is stable for a player"
	)
	_check(
		DotUserName.validate(fallback).ok, "and is itself a valid name"
	)
	_done()



func _test_profile() -> void:
	_section("profiles")

	var key := DotHash.random_bytes(32)
	var user_key: String = DotUserScope.with_key("s", key).derive("a").value

	var p := DotUserProfile.make(user_key, "s")
	p.display_name = "Ada"

	_check(p.validate().ok, "a fresh profile validates")

	var loose := DotUserProfile.make(user_key, "s")
	loose.user_key = "backbone:12345"
	_check(
		not loose.validate().ok,
		"a profile keyed on an account id is refused, not silently accepted"
	)

	_check(p.set_preference("sensitivity", 0.35).ok, "a preference is stored")
	_check(
		abs(float(p.preference("sensitivity", 0.0)) - 0.35) < 0.0001,
		"and reads back"
	)

	# Bounded, because the profile is relayed to everyone in the match.
	_check(
		not p.set_preference("big", "x".repeat(1000)).ok,
		"an oversized preference value is refused"
	)
	_check(
		not p.set_preference("k".repeat(100), 1).ok,
		"an over-long preference name is refused"
	)

	for i in range(DotUserProfile.MAX_PREFERENCES + 4):
		p.set_preference("pref_%d" % i, i)

	_check(
		p.preferences.size() <= DotUserProfile.MAX_PREFERENCES,
		"the preference count is capped",
		"%d" % p.preferences.size()
	)
	_check(p.validate().ok, "and the profile is still valid at the cap")

	var round_tripped := DotUserProfile.from_dict(p.to_dict())
	_check(round_tripped.ok, "a profile round-trips through a dictionary")
	_check(
		round_tripped.ok
			and (round_tripped.value as DotUserProfile).display_name == "Ada",
		"keeping its name"
	)
	_check(
		round_tripped.ok
			and (round_tripped.value as DotUserProfile).preferences.size()
				== p.preferences.size(),
		"and its preferences"
	)
	_test_profile_views(p)


func _test_profile_views(p: DotUserProfile) -> void:
	# Preferences are private. A profile that relayed them would leak every player's
	# settings to everyone else in the match.
	var public := p.to_public_dict()
	_check(not public.has("preferences"), "the public view omits preferences")
	_check(not public.has("locale"), "and the locale")
	_check(
		public.has("display_name") and public.has("avatar_id"),
		"but keeps what a scoreboard needs"
	)

	# A file that has been hand-edited, or written by another build.
	_check(
		not DotUserProfile.from_dict({}).ok,
		"a dictionary with no key is refused"
	)

	var newer := p.to_dict()
	newer["version"] = DotUserProfile.SCHEMA_VERSION + 5
	_check(
		not DotUserProfile.from_dict(newer).ok,
		"a profile from a newer build is refused rather than silently downgraded"
	)

	var older := p.to_dict()
	older["version"] = 0
	older.erase("onboarded")
	var migrated := DotUserProfile.from_dict(older)
	_check(migrated.ok, "a profile with a missing field is migrated, not rejected")
	_check(
		migrated.ok and (migrated.value as DotUserProfile).version
			== DotUserProfile.SCHEMA_VERSION,
		"and comes back at the current version"
	)
	_done()



## Runs the same sequence against any store.
##
## Both implementations answer identically or one of them is wrong; running the
## sequence twice is how a bug in the file handling shows up as a difference rather
## than as a plausible-looking result.
