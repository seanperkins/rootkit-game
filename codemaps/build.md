> Generated: 2026-09-03 | Token-lean format for LLM context

# Build layer — `scripts/build/` (pure)

No scene tree, no globals, no engine calls beyond `Resource`/`RefCounted`.
Runs once per module pick, never per frame — combat reads only the flat result.

```
Module ──> EquippedModule (module + rank) ──> Exploit (vector/trigger/payload)
                                                 │
                              Loadout (5 exploits + auto-slot rules)
                                                 │  compile_all()
                                                 v
                              Compiler.build(exploit, mult) ──> ResolvedExploit
```

## `module.gd` (62 lines) — `class_name Module extends Resource`

```gdscript
enum Slot        { VECTOR, TRIGGER, PAYLOAD }
enum VectorKind  { BROADCAST, PACKET, CHAIN, BEAM, CONE, PULSE, MINE, ORBIT }
enum TriggerKind { INTERVAL, ON_KILL, ON_HIT, ON_DAMAGE_TAKEN,
                   ON_LOW_INTEGRITY, ON_FLIP, ON_LEVEL_UP }
```

`VectorKind` is **append-only, never reordered** — values are stored on modules,
so an insert silently repoints everything defined above it.
`enum Targeting { NEAREST, STRONGEST, FARTHEST }` is consulted only by CHAIN
and the homing re-acquire; BEAM, CONE and PACKET fire along the owner's facing.

`STAT_KEYS` (28) is the *only* legal set of stat keys — asserting against
"fields of ResolvedExploit" would admit `stats["tags"] = 1.0`:

```
damage corruption lifesteal cooldown radius pierce chain_count projectile_speed
botnet_cap botnet_lifetime botnet_damage_ratio
ward_armor ward_defense ward_clock_speed ward_duration
travel cadence_mult knockback slow_amount slow_duration shield orbit_count burst
split_count blast_radius execute_below homing shield_rearm
```

Fields: `id, display_name, slot, tags[], max_rank=5, stats{}, vector_kind,
trigger_kind`. Built via `Module.make(id, name, slot, stats, tags, vk, tk, max_rank)`.

## `exploit.gd` (107) — one weapon

| Member | Note |
|---|---|
| `vector`, `trigger` | `EquippedModule` or `null` |
| `payloads: Array` | `PAYLOAD_SLOTS = 1` — one slot, so a level-up card never asks *which* payload slot |
| `SLOT_COUNT = 3` | column indices: 0 VECTOR, 1 TRIGGER, 2 PAYLOAD |
| `is_incomplete()` | true if vector or trigger is null; only a missing VECTOR makes the resolve inert — a bare row fires as INTERVAL at `Compiler.BARE_CADENCE` 1.30 |

`slot_type(i)` / `slot_index_of(slot)` are a bijection: one column per slot type
is what lets a card offer a single button per exploit row.
Also: `equipped()`, `holds(id)`, `at(i)`, `set_at(i, em)`, `place(m)`,
`free_payload_slot()`, `has_free_slot_for(slot)`.

## `loadout.gd` (305) — the board and the auto-slot rules

`MAX_EXPLOITS = 5`. `enum Rule { NONE, RANK_UP, EMPTY_SLOT, NEW_EXPLOIT, REPLACE }`.

| API | Does |
|---|---|
| `start(packet, interval)` | seeds exploit 0; without it the rules are not total on an empty board |
| `legal_targets(m) -> Array[Target]` | every slot `m` may occupy; the player chooses |
| `best_target(targets)` (static) | the default the card highlights |
| `place_at(m, exploit_index, slot_index)` | the player's explicit choice |
| `resolve(m) -> Placement` / `apply(m, p)` | the automatic path |
| `compile_all() -> Array[ResolvedExploit]` | **the only runtime caller of `Compiler.build`** |
| `mult: Dictionary` | absolutes, fed from `PlayerStats.mults(SaveGame.multipliers())` |

Invariants enforced by `legal_targets`:
- A module id may occupy **any number** of slots; ranks are per *slot*, so the
  same module twice is two independent copies. Only the slot already holding it
  offers a rank-up. (This is why `Compiler` folds `ward_*`/`lifesteal` by MAX.)
- The **last INTERVAL trigger cannot be displaced** (`_is_last_interval`) — an
  all-event loadout could otherwise never fire.

## `compiler.gd` (269) — `Compiler.build(ex, mult) -> ResolvedExploit`

Fold order: **flat module fold → cadence product → global multipliers → clamps.**

| Const | Value | Why |
|---|---|---|
| `MIN_COOLDOWN` | 0.05 | absolute floor |
| `MIN_CADENCE_FRACTION` | 0.12 | proportional floor, as a fraction of the vector's own base — an absolute floor makes every fast build converge on one number |
| `MAX_PROJECTILE_SPEED` | 960.0 | `60 × (PROJECTILE_RADIUS 4 + ENEMY_RADIUS 12)`; the smallest combined radius, not the cell size |
| `VECTOR_RADIUS_RANK` | 0.25 | fraction of a rank a VECTOR's radius collects |
| `MUL_FOLD_KEYS` | `[cadence_mult]` | accumulate by product |
| `MAX_FOLD_KEYS` | `ward_armor ward_defense ward_clock_speed ward_duration lifesteal slow_amount slow_duration shield shield_rearm execute_below` | magnitudes bought once; summing across slots buys uptime free |
| `MULT_KEYS` | `attack→[damage, corruption]`, `haste→[cooldown]`, `reach→[radius, travel]` | total and non-overlapping; `lifesteal` and `projectile_speed` deliberately excluded |

Everything else sums. `_rank_factor(f, rank)` scales a stat by rank;
`ward_duration` and `shield_rearm` are UNRANKED (rank buys magnitude, never
uptime) and a VECTOR's radius collects `VECTOR_RADIUS_RANK` of a rank.
`validate(m) -> Array[String]` checks a module against `STAT_KEYS`.

## `resolved_exploit.gd` (126) — the flat struct combat reads

`cadence_mult` is the **only** field defaulting to `1.0`; anything that resets
fields generically breaks quietly on it.
`pierce`, `chain_count`, `botnet_cap`, `orbit_count`, `burst` are **untyped on
purpose** — they accumulate as float so two 0.5 contributions make 1, and
`Compiler.build` applies `floori()` once at the end.
`burst = 0` means one emission. `travel` is separate from `radius` so a payload
contributing `radius` cannot silently change a packet's flight distance.
`tags: Dictionary` is a set (`StringName -> true`), not weights.
`equals(o)` enumerates the scalars BY HAND (including `shield` and
`shield_rearm`, pinned by `test_build`) plus `tags.keys()` and `inert`.

## `player_stats.gd` (67) — the player's own sheet, deliberately two groups

```gdscript
BASE      = { integrity:100.0, armor:0.0, defense:0.0, clock_speed:220.0, pickup_radius:30.0 }
BASE_MULT = { attack:1.0, haste:1.0, reach:1.0 }
ARMOR_FLOOR = 0.2     # armor never blocks >80% of a hit
DEFENSE_K   = 60.0    # defense value at which reduction is exactly 50%
```

```gdscript
mitigate(incoming, armor, defense) ->
    maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))
```
Both `maxf(0.0, …)` guards are load-bearing: `save.json` is user-editable, and
at `defense == -60` the denominator is 0.0 — GDScript yields INF rather than
erroring.

- `sheet(deltas)` — additive player stats, read **directly by run.gd**, never by
  the compiler. Unknown keys dropped, so a stale save cannot invent a stat.
- `mults(deltas)` — converts `SaveGame.multipliers()` **deltas** (+0.40) into the
  absolutes the compiler wants (×1.40). Every caller must go through it.

Keeping the two groups apart is what makes the "player stat sold in the shop,
silently delivered as an exploit stat" class of bug structurally impossible.

# Release / CI — `.github/workflows/release.yml`

Trigger: `push` tags `v*`, or `workflow_dispatch` (rehearses signing
without publishing; either job may run first/again via `--clobber`).

| Job | Runner | Produces |
|---|---|---|
| `build` | ubuntu-latest | `ROOTKIT-$TAG-windows.zip`, `-linux.zip` |
| `macos` | macos-latest | `ROOTKIT-$TAG-macos.zip`, signed+notarised+stapled |

## `macos` job — export, sign, notarise, staple

- Install Godot, `ln -sf .../Godot /usr/local/bin/godot` (`$GITHUB_PATH`
  writes land only in *later* steps, not the rest of this one).
- Stamp tag into `config/version`; snap `export_presets.cfg`'s
  `xcode/sdk_name` to `xcodebuild -showsdks`'s SDK (preset pins an older one).
- Clone private `seanperkins/rootkit-macos-certs` over read-only deploy key
  `MACOS_CERTS_DEPLOY_KEY` (`ssh-keyscan` + `IdentitiesOnly yes`).
- Decrypt `macos-signing.p12` (`MACOS_CERT_PASSWORD`) into a fresh temp
  keychain; `list-keychains -d user -s "$KC" …` adds it to the **user
  search list** (codesign resolves off the list, not just
  `default-keychain -s`, else invisible) + `set-key-partition-list`.
- Export (`godot --export-release macos`), sign (`codesign --options
  runtime --entitlements tools/macos.entitlements --sign "$MACOS_IDENTITY"`,
  default `Developer ID Application: Sean Perkins (HH3SJBAS42)`), verify.
- Notarise+staple: `ASC_KEY_CONTENT` (base64 `.p8`, python3-decoded — BSD
  `base64` has no `--decode`) → `notarytool submit --key-id 4XBH56T7RS
  --issuer 22e2fb14-d32b-4837-92b0-6280da32716d --wait`, then staple+spctl.
- Package+publish: zip, `gh release upload … --clobber`.
- Cleanup (`if: always()`): deletes deploy key, cloned vault, decoded
  `.p8`, temp keychain, whichever step failed.

**Guards**: `HAS_SIGNING` is job `env` (`secrets` isn't readable from
`if:`); every `macos` step gates on it, self-skipping until the vault is
configured. `build`'s Publish and `macos`'s Package-and-publish also
require `startsWith(github.ref, 'refs/tags/v')`.

## `tools/configure_macos_ci.sh` — one-time vault setup

Input: `.p12` exported by hand via Keychain Access (`security export` CLI
has **no identity filter**).

- Re-wraps under a fresh 24-byte-hex passphrase before the vault sees it;
  file-based throughout (OpenSSL 3.6 `pkcs12 -export` can't read PEM stdin).
- Read: modern `pkcs12 -nodes` first, retries `-legacy` on input (Keychain
  exports legacy RC2/3DES). Export: `-legacy -macalg sha1` always — the
  only encoding `security import` accepts; bare `-legacy`/openssl-3
  defaults fail with "MAC verification failed".
- Verifies before push: `crl2pkcs7 | pkcs7 -print_certs` for
  `"Developer ID Application"` + a `PRIVATE KEY` block, locally, not in CI.
- Deploy-key idempotence: `gh repo deploy-key list … --jq 'length'` — `gh`
  exits 0 on an empty list, so a naive `$?` check skips a fresh vault.
- OpenSSL 3.x preflight (`OPENSSL="${OPENSSL:-openssl}"`) — `/usr/bin/openssl`
  is LibreSSL, no `-legacy`.
- Sets 4 secrets: `MACOS_CERTS_DEPLOY_KEY`, `MACOS_CERT_PASSWORD`,
  `ASC_KEY_CONTENT` (base64 `.p8`), `MACOS_IDENTITY`.

## Test runner — `tools/run_tests.sh`

58 suites + perf gate (`perf_milestone0`, unless `--fast`) = 59 headless
runs. `test_relay_frame/_rooms`, `test_relay`, `test_transport_punch` are
the real-UDP group (real sockets on 127.0.0.1, Bash sandbox denies them —
run sandbox off). `tools/probe_punch.gd` is a **manual** probe, not in `SUITES`.
