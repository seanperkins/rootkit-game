> Generated: 2026-09-04 | Token-lean format for LLM context

# Build layer — `scripts/build/` (pure)

No scene tree, no globals, no engine calls beyond `Resource`/`RefCounted`. Runs once per module pick, never per frame — combat reads only the flat result.

```
Module ──> EquippedModule (module + rank) ──> Exploit (vector/trigger/payload)
                                                 │
                              Loadout (5 exploits + auto-slot rules)
                                                 │  compile_all()
                                                 v
                              Compiler.build(exploit, mult) ──> ResolvedExploit
```

## `module.gd` — `class_name Module extends Resource`

```gdscript
enum Slot        { VECTOR, TRIGGER, PAYLOAD }
enum VectorKind  { BROADCAST, PACKET, CHAIN, BEAM, CONE, PULSE, MINE, ORBIT }
enum TriggerKind { INTERVAL, ON_KILL, ON_HIT, ON_DAMAGE_TAKEN,
                   ON_LOW_INTEGRITY, ON_FLIP, ON_LEVEL_UP }
```

Both are **append-only, never reordered** — values are stored on modules, so an insert silently repoints everything defined above it. `enum Targeting { NEAREST, STRONGEST, FARTHEST }` is consulted only by CHAIN and the homing re-acquire; BEAM/CONE/PACKET fire along the owner's facing, the rest resolve from the player's position.

`STAT_KEYS` (28) is the *only* legal set of stat keys — asserting against "fields of ResolvedExploit" would admit `stats["tags"] = 1.0`:

```
damage corruption lifesteal cooldown radius pierce chain_count projectile_speed
botnet_cap botnet_lifetime botnet_damage_ratio
ward_armor ward_defense ward_clock_speed ward_duration
travel cadence_mult knockback slow_amount slow_duration shield orbit_count burst
split_count blast_radius execute_below homing shield_rearm
```

Fields: `id, display_name, slot, tags[], max_rank=5, stats{}, vector_kind, trigger_kind, is_fused, targeting`. A fused module (from `RecipeTable`, never drawn from `ModuleTable`) is a VECTOR that also carries a `trigger_kind`, so its row needs no TRIGGER. Built via `Module.make(id, name, slot, stats, tags, vk, tk, max_rank)`.

## `exploit.gd` — one weapon

| Member | Note |
|---|---|
| `vector`, `trigger` | `EquippedModule` or `null` |
| `payloads: Array` | `PAYLOAD_SLOTS = 1` — one slot, so a level-up card never asks *which* one |
| `SLOT_COUNT = 3` | column indices: 0 VECTOR, 1 TRIGGER, 2 PAYLOAD |
| `head_is_fused()` | true when `vector.module.is_fused` — the TRIGGER column is absorbed and stays empty |
| `is_incomplete()` | `vector == null`, or (`trigger == null` and the head isn't fused) |
| `is_fully_ranked()` | every equipped module at its own `max_rank` — `Loadout.can_fuse`'s gate |

Only a missing VECTOR makes the resolve inert (`Compiler.build` sets `r.inert`); a vector with no trigger still fires, as INTERVAL at `Compiler.BARE_CADENCE` — the weapon works the moment it's placed and the trigger card is an upgrade, not a prerequisite. `slot_type(i)`/`slot_index_of(slot)` are a bijection: one column per slot type is what lets a card offer a single button per row. Also: `equipped()`, `holds(id)`, `at(i)`, `set_at(i, em)`, `place(m)`, `free_payload_slot()`, `has_free_slot_for(slot)`.

## `loadout.gd` — the board and the auto-slot rules

`MAX_EXPLOITS = 5`. `enum Rule { NONE, RANK_UP, EMPTY_SLOT, NEW_EXPLOIT, REPLACE }`. `Target(exploit, slot, action, victim)` is what `legal_targets` offers the player; `Placement(rule, exploit_index, victim)` is what `resolve`/`apply` carry for the automatic path.

| API | Does |
|---|---|
| `start(packet)` | seeds exploit 0 with one VECTOR and **no trigger** — the bare row fires on `Compiler.BARE_CADENCE` from frame one |
| `legal_targets(m) -> Array[Target]` | every slot `m` may legally occupy |
| `best_target(targets)` (static) | default the card highlights: RANK_UP > EMPTY_SLOT > REPLACE |
| `place_at(m, exploit_index, slot_index)` | the player's explicit choice; a displaced module's rank is destroyed |
| `resolve(m) -> Placement` / `apply(m, p)` | automatic: rank-up → first empty compatible slot → found a new VECTOR-only exploit → displace the lowest-rank same-slot-type module |
| `compile_all() -> Array[ResolvedExploit]` | **the only runtime caller of `Compiler.build`** — called by `run.gd:_recompile` after every card pick and by the UI's card-comparison preview |
| `can_fuse(exploit_index, fused)` / `fuse(...)` | recipe completion — see Fusion below |
| `mult: Dictionary` | absolutes, fed from `PlayerStats.mults(SaveGame.multipliers())` |

**A module id occupies exactly one slot across the whole loadout, not per exploit** (`test_build.uniqueness_is_loadout_wide`). `_slot_holding(id)` finds that home; `legal_targets` offers a rank-up only there and refuses every other slot while it exists. Ordinary REPLACE also frees a displaced module's id, but destroys its rank and stat contribution outright. Fusion is the deliberate alternative for a still-equipped, maxed id: it converts the id (plus its two exploit-mates) into a fused module whose own stats are tuned to at least match what the triple produced, per `RecipeTable` — see Fusion below. Ranks are per slot, so `Compiler` still folds `ward_*`/`lifesteal`/`shield*` by MAX: one exploit can carry the same stat on two different modules (e.g. a TRIGGER and a PAYLOAD) at once.

**The board must always keep one row that fires unconditionally.** `_fires_unconditionally(ex)` is true for a VECTOR with no trigger (bare, paid at `BARE_CADENCE`), an INTERVAL trigger, or a fused head whose own `trigger_kind` is INTERVAL. `_auto_fire_count()` counts such rows; `strands_auto_fire(m, exploit_index)` refuses a non-INTERVAL TRIGGER into the board's *last* one — an event trigger can't bootstrap (ON_KILL fires when it kills). `resolve`/`legal_targets` gate placement through `strands_auto_fire`; `fuse` gates through `can_fuse`'s own resulting-count check instead (see Fusion below), since fusing never places a TRIGGER module.

**Fusion** (`can_fuse`/`fuse`): every module on the target exploit must be at max rank (`Exploit.is_fully_ranked`) — a recipe ends three modules' lives rather than shortcutting past levelling them — and the resulting auto-fire count (losing the row's own unconditional fire, gaining the fused head's if it is itself INTERVAL) must stay `>= 1`. `fuse` clears trigger and payload, then assigns the fused module into VECTOR **last**, so a refused fusion leaves the row untouched.

## `compiler.gd` — `Compiler.build(ex, mult) -> ResolvedExploit`

Fold order: **flat module fold (vector, payloads sorted by id, trigger) → cadence product → global multipliers → clamps/floors.**

| Const | Value | Why |
|---|---|---|
| `MIN_COOLDOWN` | 0.05 | absolute floor; binds only a null-vector exploit, where the proportional floor collapses to 0.0 |
| `MIN_CADENCE_FRACTION` | 0.12 | proportional floor, a fraction of the vector's OWN base — every vector floors at the same ratio to a *different* base |
| `MAX_PROJECTILE_SPEED` | 960.0 | `60 × (PROJECTILE_RADIUS 4 + ENEMY_RADIUS 12)` |
| `MAX_EXECUTE` | 0.5 | above this an execute becomes the damage model, not a finisher |
| `MAX_HOMING` | 4.0 | turn-rate ceiling — above it a projectile snaps on-target within a tick |
| `VECTOR_RADIUS_RANK` | 0.25 | fraction of a rank a VECTOR's own `radius`/`blast_radius` collects |
| `BARE_CADENCE` | 1.50 | cadence penalty for a vector with no trigger — half again the period so a fresh board still fires; a real trigger (1.00) is still a real improvement |
| `MUL_FOLD_KEYS` | `[cadence_mult]` | the only key that accumulates by product |
| `MAX_FOLD_KEYS` | `ward_armor ward_defense ward_clock_speed ward_duration lifesteal slow_amount slow_duration shield shield_rearm execute_below` | magnitudes bought once; summing across slots would buy uptime free |
| `MULT_KEYS` | `attack -> [damage, corruption]`, `reach -> [radius, travel]` | total, non-overlapping; `lifesteal`/`projectile_speed` deliberately excluded. **No `haste` key** — see `player_stats.gd` |

Everything else sums. `_rank_factor(f, rank)` scales a cadence-cost factor (`f >= 1`) LINEARLY (`1+(f-1)*rank`) — compounding it would diverge (1.52^5 = 8.1×) — and a reduction factor (`f < 1`) GEOMETRICALLY (`DetMath.powi(f, rank)`), since a linear reduction would go negative past a threshold rank while geometric decay only approaches zero. A VECTOR's own `cooldown`/`travel` never scale with rank; `ward_duration`/`shield_rearm` are always unranked (magnitude, never uptime). A bare row (vector, no trigger, head not fused) sets `trigger_kind = INTERVAL` and `cadence_mult *= BARE_CADENCE` in place of folding a trigger module.

`validate(m) -> Array[String]` — beyond `STAT_KEYS` membership: `corruption`/`slow_amount` stats require the matching tag; `max_rank >= 1`; `cadence_mult >= 0.01` when present; only a VECTOR may carry `cooldown`, `execute_below` or `homing`; only a TRIGGER may carry `cadence_mult`; only a TRIGGER (or a fused module) may carry `burst`; every VECTOR must carry `cooldown >= MIN_COOLDOWN / MIN_CADENCE_FRACTION` (≈0.417).

## `resolved_exploit.gd` — the flat struct combat reads

`cadence_mult` is the **only** field defaulting to `1.0`; anything that resets fields generically breaks quietly on it. `pierce`, `chain_count`, `botnet_cap`, `orbit_count`, `burst`, `split_count` are **untyped on purpose** — they accumulate as float so two 0.5 contributions make 1, and `Compiler.build` applies `floori()` once at the end (`burst = 0`/`split_count = 0` both mean one emission). `travel` is separate from `radius` so a payload contributing `radius` cannot silently change a packet's flight distance; `blast_radius` is separate again for a detonation. `tags: Dictionary` is a set (`StringName -> true`), not weights. `equals(o)` enumerates every scalar BY HAND — including `shield`/`shield_rearm`, pinned by `test_build.equals_sees_shield_and_shield_rearm` — plus `tags.keys()` and `inert`.

## `player_stats.gd` — the player's own sheet, deliberately two groups

```gdscript
BASE      = { integrity:128.0, armor:0.0, defense:15.0, clock_speed:220.0, pickup_radius:80.0 }
BASE_MULT = { attack:1.0, reach:1.0 }
ARMOR_FLOOR = 0.2     # armor never blocks >80% of a hit
DEFENSE_K   = 60.0    # defense value at which reduction is exactly 50%
```

`BASE_MULT` has **two** entries, not three: `haste` is gone — it used to multiply every vector's cooldown, making a shop purchase the strongest cadence lever in the game and putting "fires faster" outside the TRIGGER column that owns cadence. The `cooling` shop line that funded it now buys sheet `clock_speed` instead; a stale save asking for `haste` is dropped by `mults()` like any other unknown key.

```gdscript
mitigate(incoming, armor, defense) ->
    maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))
```
Both `maxf(0.0, …)` guards are load-bearing: `save.json` is user-editable, and at `defense == -60` the denominator is 0.0 — GDScript yields INF rather than erroring.

- `sheet(deltas)` — additive player stats, read **directly by run.gd**, never by the compiler. Unknown keys dropped, so a stale save invents none.
- `mults(deltas)` — converts `SaveGame.multipliers()` **deltas** (+0.40) into the absolutes the compiler wants (×1.40). Every caller must go through it.

Keeping the two groups apart makes "a player stat sold in the shop, silently delivered as an exploit stat" structurally impossible.

# Release / CI — `.github/workflows/release.yml`

Trigger: `push` tags `v*`, or `workflow_dispatch` (rehearses signing without publishing; every job creates the release if missing and uploads with `--clobber`, so either can run first or again).

| Job | Runner | Produces |
|---|---|---|
| `build` | ubuntu-latest | `ROOTKIT-$TAG-windows.zip`, `ROOTKIT-$TAG-linux.tar.gz` |
| `macos` | macos-latest | `ROOTKIT-$TAG-macos.zip`, signed+notarised+stapled |
| `feed` | ubuntu-latest, needs `build`+`macos` | `latest.json` — SHA-256 of each archive signed with `UPDATE_SIGN_KEY`, via `tools/update_feed.sh <tag> --merge` |

## `macos` job — export, sign, notarise, staple

- Install Godot + export templates from the `godotengine/godot` release zip; symlink `.../Godot.app/Contents/MacOS/Godot` to `/usr/local/bin/godot`.
- Stamp tag into `config/version`; snap `export_presets.cfg`'s `xcode/sdk_name` to `xcodebuild -showsdks`'s SDK (preset pins an older one).
- Clone private `seanperkins/rootkit-macos-certs` over read-only deploy key `MACOS_CERTS_DEPLOY_KEY` (`ssh-keyscan` + `IdentitiesOnly yes`).
- Decrypt `macos-signing.p12` (`MACOS_CERT_PASSWORD`) into a fresh temp keychain; `list-keychains -d user -s "$KC" …` adds it to the **user search list** (codesign resolves off the list, not just `default-keychain -s`) + `set-key-partition-list`.
- Export (`godot --export-release macos`); copy the updater helper (`packaging/updater/macos.sh`) into `Contents/Resources/updater.sh` **before** signing, so the signature covers whatever the bundle ships. Sign (`codesign --force --deep --options runtime --timestamp --entitlements tools/macos.entitlements --sign "$MACOS_IDENTITY"`, default `Developer ID Application: Sean Perkins (HH3SJBAS42)`), verify.
- Notarise+staple: `ASC_KEY_CONTENT` (base64 `.p8`, python3-decoded — BSD `base64` has no `--decode`) → zip via `ditto -c -k`, `notarytool submit --key-id 4XBH56T7RS --issuer 22e2fb14-d32b-4837-92b0-6280da32716d --wait`, then staple+spctl.
- Package+publish: `ditto -c -k --sequesterRsrc --keepParent` zip, `gh release upload … --clobber`.
- Cleanup (`if: always()`): deletes deploy key, cloned vault, decoded `.p8`, temp keychain, whichever step failed.

**Guards**: `HAS_SIGNING` is job `env` (`secrets` isn't readable from `if:`); every `macos` step gates on it, self-skipping until the vault is configured. `build`'s Publish, `macos`'s Package-and-publish and the whole `feed` job also require `startsWith(github.ref, 'refs/tags/v')`.

## `tools/configure_macos_ci.sh` — one-time vault setup

Input: a `.p12` exported by hand from Keychain Access (`Developer ID Application: Sean Perkins`, not the Frost Solutions item).

- Re-wraps under a fresh 24-byte (`openssl rand -hex 24`) passphrase before the vault sees it; file-based throughout (OpenSSL 3.6 `pkcs12 -export` can't read PEM from stdin).
- Read: modern `pkcs12 -nodes` first, retries `-legacy` (Keychain exports legacy RC2/3DES). Export: `-legacy -macalg sha1` always — the only encoding `security import` accepts.
- Verifies before push: `crl2pkcs7 | pkcs7 -print_certs` for `"Developer ID Application"` + a `PRIVATE KEY` block, locally, not in CI.
- Deploy-key idempotence: `gh repo deploy-key list … --jq 'length'` — `gh` exits 0 on an empty list, so a naive `$?` check skips a fresh vault.
- OpenSSL 3.x preflight (`OPENSSL="${OPENSSL:-openssl}"`) — `/usr/bin/openssl` is LibreSSL, no `-legacy`.
- Sets 4 secrets: `MACOS_CERTS_DEPLOY_KEY`, `MACOS_CERT_PASSWORD`, `ASC_KEY_CONTENT` (base64 `.p8`), `MACOS_IDENTITY`.

## Test runner — `tools/run_tests.sh`

61 suites + perf gate (`perf_milestone0`, unless `--fast`) = 62 headless runs by default; naming suites on the command line (e.g. `test_build test_slots perf_milestone0`) runs only those. `test_transport_loopback`, `test_relay` and `test_transport_punch` are the real-UDP group (real sockets on 127.0.0.1, Bash sandbox denies them — run sandbox off). `tools/probe_punch.gd` is a **manual** probe, not in `SUITES`. Any `SCRIPT ERROR`/`Parse Error` on stderr fails the suite regardless of its own printed verdict.
