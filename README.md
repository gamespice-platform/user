Player profiles that follow a person between servers, without letting those servers work out it is the same person. A profile holds a display name, an avatar reference and preferences. Storage is pluggable: a JSON directory, an in-memory store, or an open HTTP back end anyone can self-host. A profile is resolved once on join and cached.

## Install

1. Get [Godot 4.7](https://godotengine.org/download).
2. Either use [dot-bootstrap](https://github.com/gamespice-platform/bootstrap), which clones every project and links the addons, or copy `addons/dot_user/` and [dot-core](https://github.com/gamespice-platform/core)'s `addons/dot_core/` into your project and enable both in *Project > Project Settings > Plugins*.

dot-core is the only dependency. [dot-auth](https://github.com/gamespice-platform/auth), [dot-server](https://github.com/gamespice-platform/server) and [dot-user-avatar](https://github.com/gamespice-platform/user-avatar) work with it and none is imported.

## Use

```gdscript
var manager := DotUserManager.new()
manager.server_id = "eu-west-1"
add_child(manager)

# identity is anything with uid, display_name and is_guest, such as DotAuthIdentity,
# dot-server's DotGuestIdentity, or your own.
var resolved := await manager.resolve(identity)
if resolved.ok:
    var profile: DotUserProfile = resolved.value
    print(profile.display_name)
```

Nothing is an autoload. `DotUserManager` registers itself in `DotRegistry` as `dot_user_manager`, which is how dot-server and dot-user-avatar find it.

## Scoped ids

A server never sees the account id. Handing it to every server would let operators compare logs and trace where a person has been. It sees a scoped id instead:

```
scoped_id = base64url(HMAC-SHA256(key, scope + U+001F + account_id))[:22]
```

It is stable for that player on that server, so bans and profiles work, different on every other scope, so operators cannot correlate, and not reversible, because the key never leaves whoever mints identities. A player who wants to be recognised across a set of servers opts into a shared scope. A standalone server with no issuer generates its own key on first run.

## What is in it

| Class | What it is |
| --- | --- |
| `DotUserScope` | The derivation above, plus verification and key persistence. |
| `DotUserName` | Display-name sanitising and validation. |
| `DotUserProfile` | The record: versioned, migratable, with a public subset. |
| `DotUserStore` | Where profiles live: `Memory`, `Local` (JSON files) or `Backbone` (HTTP). |
| `DotUserManager` | Resolve on join, cache, write back, rename, rate-limit. |
| `DotUserConfig` | Settings, layered. |

## Settings

`DotUserConfig` layers exported defaults, a JSON file, `DOT_USER_*` environment, then `--user-*` command line.

| Setting | Default | Meaning |
| --- | --- | --- |
| `backend` | `local` | `local`, `memory` or `backbone`. |
| `directory` | `user://profiles` | Where the local store writes. |
| `backbone_url`, `backbone_token` | empty | The HTTP back end. |
| `scope`, `scope_key_file` | empty, `user://user_scope.key` | The scope and where its key is kept. |
| `allow_guest_profiles` | false | Whether guests get stored profiles. |
| `allow_name_changes` | false | Whether authenticated players may rename themselves. |
| `refuse_duplicate_names` | true | Refuse a name already in use. |
| `create_missing` | true | Create a profile on first join. |
| `save_on_leave` | true | Save when the player leaves. |
| `read_only` | false | Never write. |
| `cache_ttl_sec` | 300 | How long a cached profile is trusted. |
| `max_cached` | 4096 | Profiles kept in the cache. |
| `writes_per_minute` | 6 | Profile writes allowed per player; 0 is unlimited. |
| `resolve_timeout_sec` | 5 | How long a resolve may take. |

## Display names

A display name is shown to everyone and chosen by the person it is shown for, so `DotUserName` strips bidirectional overrides, zero-width characters, stacked combining marks and control characters, collapses whitespace, and refuses names that are empty, over-long or all punctuation. Whether a name is offensive is a community decision; `DotUserManager.name_filter` is the hook.

An authenticated player cannot rename themselves by default, because overriding the account name lets them pose as somebody else. Guests have no account name and can pick one.

## Storage

- Lookups on the join path never wait on a slow load, and a resolved profile stays cached after the player leaves.
- A failed read never destroys a profile. If the store cannot answer, the player gets a session-only profile that `save()` refuses to persist, so a network blip cannot overwrite the real one.

## Testing

Import the project once, then run `examples/user_demo.tscn` headless with Godot. It exits non-zero on failure.

## Status and licence

Part of the [Gamespice](https://gamespice.net) platform: a family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/gamespice-platform/user/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the [Gamespice](https://gamespice.net) platform is the web back end; you can use your own instead of Gamespice's.
