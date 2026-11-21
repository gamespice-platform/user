extends "res://examples/user_demo_base.gd"

## Exercises everything in gs-user, offline.
##
## [codeblock]
## godot --headless --path . res://examples/user_demo.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones where a mistake is a vulnerability or data
## loss rather than a crash: the scoped-id derivation, the display-name sanitising,
## and the degraded path where a store that cannot answer must not cause a returning
## player's profile to be overwritten.

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 13

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 153


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("gs-user self-test")
	print("")

	_cleanup()

	_test_scope()
	_test_names()
	_test_profile()
	await _test_store_contract(GSUserStoreMemory.new(), "memory")
	await _test_store_contract(GSUserStoreLocal.at(PROFILE_DIR), "local")
	await _test_local_store_specifics()
	await _test_manager_resolve()
	await _test_manager_degraded()
	await _test_manager_timeout()
	await _test_manager_names()
	await _test_manager_cache()
	await _test_read_only()
	await _test_backbone_transport()

	_cleanup()

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS]
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS]
	)
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _test_store_contract(store: GSUserStore, label: String) -> void:
	_section("store contract")
	print("store contract: %s" % label)

	var key := GSHash.random_bytes(32)
	var scope := GSUserScope.with_key("s", key)
	var user_key: String = scope.derive("account-1").value

	var opened: GSResult = await store.open()
	_check(opened.ok, "[%s] opens" % label)

	var missing: GSResult = await store.fetch(user_key)
	_check(missing.ok, "[%s] a missing profile is not a failure" % label)
	_check(
		missing.ok and missing.value == null,
		"[%s] and comes back as null" % label
	)

	var p := GSUserProfile.make(user_key, "s")
	p.display_name = "Ada"
	p.set_preference("theme", "dark")

	var stored: GSResult = await store.store(p)
	_check(stored.ok, "[%s] a profile stores" % label)

	var read: GSResult = await store.fetch(user_key)
	_check(read.ok and read.value != null, "[%s] and reads back" % label)

	if read.ok and read.value != null:
		var got: GSUserProfile = read.value
		_check(got.display_name == "Ada", "[%s] with its name" % label)
		_check(
			str(got.preference("theme", "")) == "dark",
			"[%s] and its preferences" % label
		)
		_check(got.updated_at > 0, "[%s] and a write timestamp" % label)

		# A caller mutating what it got back must not reach into the store.
		got.display_name = "Mallory"
		var again: GSResult = await store.fetch(user_key)
		_check(
			again.ok and (again.value as GSUserProfile).display_name == "Ada",
			"[%s] the store hands out copies, not references" % label
		)

	var invalid := GSUserProfile.make(user_key, "s")
	invalid.display_name = "x"
	var refused: GSResult = await store.store(invalid)
	_check(
		not refused.ok,
		"[%s] an invalid profile is refused rather than written" % label
	)

	var bad_key: GSResult = await store.fetch("../../etc/passwd")
	_check(
		not bad_key.ok,
		"[%s] a malformed key never reaches the store" % label
	)

	var removed: GSResult = await store.remove(user_key)
	_check(removed.ok, "[%s] a profile removes" % label)

	var gone: GSResult = await store.fetch(user_key)
	_check(gone.ok and gone.value == null, "[%s] and is then absent" % label)

	var again_removed: GSResult = await store.remove(user_key)
	_check(
		again_removed.ok,
		"[%s] removing an absent profile is success, not an error" % label
	)

	store.close()
	_done()


func _test_local_store_specifics() -> void:
	_section("local store")

	var store := GSUserStoreLocal.at(PROFILE_DIR)
	var scope := GSUserScope.with_key("s", GSHash.random_bytes(32))

	var opened: GSResult = await store.open()
	if not _check(opened.ok, "the directory is created"):
		return

	var keys := PackedStringArray()

	for i in range(3):
		var user_key: String = scope.derive("account-%d" % i).value
		keys.append(user_key)

		var p := GSUserProfile.make(user_key, "s")
		p.display_name = "Player %d" % (i + 1)
		var stored: GSResult = await store.store(p)
		_check(stored.ok, "profile %d writes" % i)

	var listed: GSResult = await store.list_keys()
	_check(listed.ok, "the directory lists")
	_check(
		listed.ok and (listed.value as PackedStringArray).size() == 3,
		"with every profile",
		"%d" % (listed.value as PackedStringArray).size() if listed.ok else "?"
	)

	# A truncated file is a failure, never an absence. Reporting it as "no profile"
	# would make the manager write a fresh one over whatever could be recovered.
	var damaged := "%s/%s.json" % [PROFILE_DIR, keys[0]]
	var f := FileAccess.open(damaged, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()

	var corrupt: GSResult = await store.fetch(keys[0])
	_check(
		not corrupt.ok,
		"a corrupt profile is a failure, not an absence"
	)

	# Anything else in the directory is somebody else's file.
	var stray := FileAccess.open("%s/notes.txt" % PROFILE_DIR, FileAccess.WRITE)
	stray.store_string("hello")
	stray.close()

	var relisted: GSResult = await store.list_keys()
	_check(
		relisted.ok and not Array(relisted.value).has("notes"),
		"a stray file is not listed as a profile key"
	)

	store.close()
	_done()



func _make_manager(backend: String = "memory") -> GSUserManager:
	var manager := GSUserManager.new()
	manager.register_service = false
	manager.load_layered_config = false
	manager.config_file = ""
	manager.server_id = "selftest"

	var config := GSUserConfig.new()
	config.backend = backend
	config.directory = PROFILE_DIR
	config.scope = "server:selftest"
	config.scope_key_file = SCOPE_KEY
	config.allow_guest_profiles = true
	manager.config = config

	add_child(manager)
	return manager


func _test_manager_resolve() -> void:
	_section("manager: resolving")

	var manager := _make_manager()
	var ready: GSResult = await manager.setup()

	if not _check(ready.ok, "the manager sets up", str(ready.error)):
		manager.queue_free()
		return

	_check(
		FileAccess.file_exists(SCOPE_KEY),
		"a scope key is generated and persisted on first run"
	)

	var ada := FakeIdentity.account("acc-1", "Ada")
	var first: GSResult = await manager.resolve(ada)

	if not _check(first.ok, "a first-time player resolves", str(first.error)):
		manager.queue_free()
		return

	var profile: GSUserProfile = first.value

	_check(profile.display_name == "Ada", "taking their account name")
	_check(profile.visit_count == 1, "with one visit recorded")
	_check(
		GSUserScope.is_well_formed(profile.user_key),
		"and a scoped key, not an account id"
	)
	_check(
		not profile.user_key.contains("acc-1"),
		"the account id does not appear in the key"
	)
	_check(
		GSUserManager.is_persistable(profile),
		"and the profile is a real one"
	)

	var saved: GSResult = await manager.save(profile)
	_check(saved.ok, "it saves")

	# A different scope must not see it. This is the property the whole design is for.
	var other := _make_manager()
	other.config.scope = "server:elsewhere"
	other.config.scope_key_file = SCOPE_KEY
	var other_ready: GSResult = await other.setup()

	if other_ready.ok:
		other.store = manager.store
		var elsewhere: GSResult = await other.resolve(ada)
		_check(
			elsewhere.ok and (elsewhere.value as GSUserProfile).user_key
				!= profile.user_key,
			"the same player on another scope is a different profile"
		)

	other.queue_free()
	await _test_manager_issued(manager, ada)


func _test_manager_issued(manager: GSUserManager, ada: FakeIdentity) -> void:
	# A key the backbone issued is used as it is. A key derived here from this server's
	# own secret is one the backbone can never resolve, so every avatar and profile it
	# holds would be unreachable.
	var issued := "Abc_def-123456789012zz"
	var from_site: GSResult = manager.key_for(FakeIdentity.site(issued, "Bea"))
	_check(
		from_site.ok and str(from_site.value) == issued,
		"a key the backbone issued is the profile key, not re-derived",
		str(from_site.value) if from_site.ok else str(from_site.error)
	)
	var site_profile: GSResult = await manager.resolve(FakeIdentity.site(issued, "Bea"))
	_check(
		site_profile.ok and (site_profile.value as GSUserProfile).user_key == issued,
		"and the profile resolves under it"
	)
	_check(
		not manager.key_for(FakeIdentity.site("../../etc", "X")).ok,
		"an issued key that could leave the store's directory is refused"
	)

	var guest := FakeIdentity.guest("device-1", "Visitor")
	var guest_resolved: GSResult = await manager.resolve(guest)
	_check(guest_resolved.ok, "a guest resolves when guests are allowed")

	manager.config.allow_guest_profiles = false
	var refused: GSResult = await manager.resolve(FakeIdentity.guest("d2", "V"))
	_check(
		not refused.ok, "and is refused when they are not"
	)
	manager.config.allow_guest_profiles = true

	# A returning player gets what was stored, not a fresh profile.
	manager.clear_cache()
	var second: GSResult = await manager.resolve(ada)
	_check(second.ok, "a returning player resolves")
	_check(
		second.ok and (second.value as GSUserProfile).visit_count == 2,
		"and their visit count carries over",
		"%d" % (second.value as GSUserProfile).visit_count if second.ok else "?"
	)

	manager.queue_free()
	_done()


func _test_manager_degraded() -> void:
	_section("manager: a store that cannot answer")

	var manager := _make_manager()
	var ready: GSResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var memory := manager.store as GSUserStoreMemory
	var ada := FakeIdentity.account("acc-degraded", "Ada")

	var first: GSResult = await manager.resolve(ada)
	var real: GSUserProfile = first.value
	real.set_preference("theme", "dark")
	var saved: GSResult = await manager.save(real)
	_check(saved.ok, "a real profile is stored first")

	manager.clear_cache()
	memory.fail_next_fetch = true

	var degraded: GSResult = await manager.resolve(ada)

	_check(degraded.ok, "a failed read still lets the player in")
	_check(
		manager.degraded_count == 1,
		"and is counted so an operator can see it"
	)

	var stand_in: GSUserProfile = degraded.value

	_check(
		not GSUserManager.is_persistable(stand_in),
		"the stand-in is marked as session-only"
	)

	# The whole point: storing the stand-in would overwrite the real profile the
	# store could not read, turning a network blip into data loss.
	var refused: GSResult = await manager.save(stand_in)
	_check(
		not refused.ok,
		"and saving it is refused rather than overwriting the real one"
	)

	manager.clear_cache()
	var recovered: GSResult = await manager.resolve(ada)
	_check(
		recovered.ok
			and str((recovered.value as GSUserProfile).preference("theme", "")) == "dark",
		"so when the store recovers, the real profile is intact"
	)

	manager.queue_free()
	_done()


func _test_manager_names() -> void:
	_section("manager: names")

	var manager := _make_manager()
	var ready: GSResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var ada := FakeIdentity.account("acc-name", "Ada")
	var resolved: GSResult = await manager.resolve(ada)
	var profile: GSUserProfile = resolved.value

	# An account's name comes from the account. A player who can override it can
	# appear as somebody else.
	var refused := manager.set_display_name(profile, "Administrator")
	_check(
		not refused.ok,
		"an authenticated player cannot rename themselves by default"
	)
	_check(
		profile.display_name == "Ada", "and their name is unchanged"
	)

	var guest := FakeIdentity.guest("dev-name", "Visitor")
	var guest_resolved: GSResult = await manager.resolve(guest)
	var guest_profile: GSUserProfile = guest_resolved.value

	var allowed := manager.set_display_name(guest_profile, "  Grace  ", true)
	_check(allowed.ok, "a guest can name themselves")
	_check(
		guest_profile.display_name == "Grace",
		"and the name is sanitised on the way in",
		guest_profile.display_name
	)

	var hostile := manager.set_display_name(
		guest_profile, "Ada%sniamdA" % String.chr(0x202E), true
	)
	_check(
		hostile.ok and not guest_profile.display_name.contains(String.chr(0x202E)),
		"a name with a bidirectional override is cleaned, not stored"
	)

	# Impersonation by confusable name.
	var squatter := FakeIdentity.guest("dev-squat", "Someone")
	var squat_resolved: GSResult = await manager.resolve(squatter)
	var squat_profile: GSUserProfile = squat_resolved.value

	var taken := manager.set_display_name(squat_profile, "Ada", true)
	_check(
		not taken.ok,
		"a name another player here is using is refused"
	)

	var lookalike := manager.set_display_name(squat_profile, "Ad4", true)
	_check(
		not lookalike.ok,
		"including a lookalike of it"
	)
	await _test_manager_policy(manager, profile, squat_profile)


func _test_manager_policy(manager: GSUserManager, profile: GSUserProfile, squat_profile: GSUserProfile) -> void:
	# The policy hook, which is where a word filter belongs.
	manager.name_filter = func(name: String, _p: GSUserProfile) -> GSResult:
		if name.to_lower().contains("banned"):
			return GSResult.fail(GSError.CODE_FORBIDDEN, "Not that one.")
		return GSResult.success(true)

	_check(
		not manager.set_display_name(squat_profile, "bannedword", true).ok,
		"the name filter can refuse a name"
	)
	_check(
		manager.set_display_name(squat_profile, "Katherine", true).ok,
		"and lets everything else through"
	)

	# A client can ask as fast as it can send packets, and each one is a store write.
	manager.config.allow_name_changes = true
	var limited := false

	for i in range(30):
		var res: GSResult = await manager.save(profile)
		if not res.ok and res.code() == GSError.CODE_RATE_LIMITED:
			limited = true
			break

	_check(limited, "profile writes are rate limited per player")

	manager.queue_free()
	_done()


func _test_manager_cache() -> void:
	_section("manager: caching")

	var manager := _make_manager()
	var ready: GSResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var ada := FakeIdentity.account("acc-cache", "Ada")
	var first: GSResult = await manager.resolve(ada)

	var before := manager.store.fetch_count
	var second: GSResult = await manager.resolve(ada)

	_check(
		manager.store.fetch_count == before,
		"a cached profile does not touch the store",
		"%d fetches" % (manager.store.fetch_count - before)
	)
	_check(
		first.value == second.value,
		"and is the same object, so a change in flight is not lost"
	)

	var released: GSResult = await manager.release(
		(first.value as GSUserProfile).user_key
	)
	_check(released.ok, "releasing a player succeeds")

	# Still cached, so a reconnect or a map change does not re-read for everybody.
	var reconnect: GSResult = await manager.resolve(ada)
	_check(
		manager.store.fetch_count == before,
		"a reconnect inside the cache window still does not touch the store"
	)

	# An active player is never evicted; their profile is in use.
	manager.config.max_cached = 1

	for i in range(5):
		var other: GSResult = await manager.resolve(
			FakeIdentity.account("filler-%d" % i, "Filler")
		)

	_check(
		manager.cached_count() >= 1,
		"eviction keeps the cache populated",
		"%d" % manager.cached_count()
	)

	var described := manager.describe_lines()
	_check(described.size() >= 4, "describe_lines produces something usable")

	manager.queue_free()
	_done()


func _test_read_only() -> void:
	_section("manager: read-only")

	var manager := _make_manager()
	manager.config.read_only = true
	manager.config.save_on_leave = false

	var ready: GSResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var resolved: GSResult = await manager.resolve(
		FakeIdentity.account("acc-ro", "Ada")
	)

	_check(resolved.ok, "a player still resolves on a read-only server")

	var refused: GSResult = await manager.save(resolved.value)
	_check(
		not refused.ok,
		"but saving is refused, rather than appearing to work and vanishing"
	)

	manager.queue_free()
	_done()


class HangingStore extends GSUserStoreMemory:
	func fetch(_user_key: String) -> GSResult:
		for _i in range(1000000):
			await Engine.get_main_loop().process_frame
		return GSResult.fail(GSError.CODE_STATE, "never")


func _test_manager_timeout() -> void:
	_section("manager: a store that never answers")

	var manager := _make_manager()
	var ready: GSResult = await manager.setup()
	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	manager.config.resolve_timeout_sec = 0.5
	manager.store = HangingStore.new()
	manager.clear_cache()

	var started := Time.get_ticks_msec()
	var res: GSResult = await manager.resolve(FakeIdentity.account("acc-slow", "Slow"))
	var took := Time.get_ticks_msec() - started
	_check(res.ok, "the player is let in on a session-only profile", str(res.error) if not res.ok else "")
	_check(took < 3000, "within resolve_timeout_sec rather than for ever", "%d ms" % took)
	_check(took >= 400, "and not before it", "%d ms" % took)

	manager.queue_free()
	_done()



## The backbone store's HTTP client has to be IN THE TREE to send anything.
##
## [GSHttp] is a Node whose requests are HTTPRequest children, and the store is a
## RefCounted. It used to build an orphan client, so every fetch and every save failed
## with engine error 3 (Unconfigured) before reaching the network, and every player on a
## server using it got a session-only profile. Nothing here needs a backbone: a closed
## loopback port answers "connection refused", which is a different error from the one
## an orphan client gives.
func _test_backbone_transport() -> void:
	_section("backbone store transport")

	var no_url := GSUserStoreBackbone.at("", "tmci_test")
	var refused: GSResult = await no_url.open()
	_check(not refused.ok and no_url.http == null, "no URL is refused, and builds no client")

	var store := GSUserStoreBackbone.at("http://127.0.0.1:9", "tmci_test")
	store.timeout_sec = 3.0
	var opened: GSResult = await store.open()
	_check(opened.ok, "a loopback URL with a token opens")
	_check(
		store.http != null and store.http.is_inside_tree(),
		"and its HTTP client is in the tree before the first request"
	)

	var res: GSResult = await store.fetch("AbCdEfGhIjKlMnOpQrStUv")
	var why := str(res.error) if res.error != null else ""
	_check(not res.ok, "an unreachable backbone is a failure, never an absent profile")
	_check(
		not why.contains("Unconfigured"),
		"and the request reached the network (%s)" % why.substr(0, 120)
	)

	var client := store.http
	store.close()
	await get_tree().process_frame
	_check(not is_instance_valid(client), "closing frees the client the store built")

	# A manager's _ready and its host's setup() both open the store. Two overlapping
	# opens each queued the same client onto the root, and the second add_child was an
	# engine error on every boot.
	var slow := SlowOpenStore.new()
	var results: Array = []
	var opener := func() -> void: results.append(await slow.open())
	opener.call()
	opener.call()
	for _i in 30:
		if results.size() == 2:
			break
		await get_tree().process_frame
	_check(
		results.size() == 2 and slow.attempts == 1 and (results[0] as GSResult).ok
			and (results[1] as GSResult).ok,
		"two overlapping opens share one attempt (%d results, %d attempts)" % [
			results.size(), slow.attempts
		]
	)

	_done()


## A store whose open suspends for a frame, as the backbone store's does.
class SlowOpenStore extends GSUserStoreMemory:
	var attempts := 0

	func _open() -> GSResult:
		attempts += 1
		await (Engine.get_main_loop() as SceneTree).process_frame
		return GSResult.success(true)
