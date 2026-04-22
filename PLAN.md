# Cleanup Plan — Proxim Example Repo

Goal: turn this repo into a polished reference project for the Proxim Godot
addon, where the addon itself is a self-contained drop-in folder and the rest
of the repo is an example demonstrating it.

Three user personas drive every decision:

- **M — Multiplayer only.** Uses Proxim as a voice-chat + WebRTC signaling
  service; wants spatial audio disabled. Needs `ProximPeer` (core) +
  `ProximWebRTC` (transport). Does not call any `*_gain_node` / `*_panner_node`
  / `hot_listener_node` APIs.
- **P — Proximity only.** Already has their own multiplayer (ENet, Steam,
  Nakama, etc.). Uses `ProximPeer` only for the spatial audio API. Maps their
  own peer IDs onto Proxim `gameId`s themselves.
- **B — Both.** The full stack: `ProximPeer` + `ProximWebRTC` + spatial
  audio. This is what the example scene demonstrates.

---

## 1. Split the repo into `addons/proxim/` + example

The single most important change. Everything else follows from it.

**Proposed layout:**

```
proximity-example/
├── addons/
│   └── proxim/
│       ├── plugin.cfg                 # Godot addon manifest
│       ├── plugin.gd                  # registers ProximPeer autoload on enable
│       ├── proxim_peer.gd             # core: websocket + relay + audio API
│       ├── proxim_webrtc.gd           # optional: WebRTCMultiplayerPeer helper
│       └── README.md                  # addon-level docs (see §4)
├── example/                           # or keep at root — see note below
│   ├── main.tscn / main.gd
│   ├── player.tscn / player.gd
│   ├── button.tscn / button.gd
│   ├── fall_limit.gd
│   └── local_webrtc_peer.gd           # example-only WebRTC smoke test
├── webrtc/                            # GDExtension (example dep, not addon dep)
├── project.godot
├── README.md                          # example readme: how to run the demo
├── LICENSE
└── .gitignore
```

**`plugin.cfg` / `plugin.gd`:** Godot auto-registers plugins in `addons/*/`.
`plugin.gd` (an `EditorPlugin`) uses `add_autoload_singleton("ProximPeer", …)`
on `_enter_tree` and `remove_autoload_singleton` on `_exit_tree`, so users just
tick "Enable" in Project Settings → Plugins and the `ProximPeer` global appears.

**`proxim_webrtc.gd` stays opt-in** — it is not an autoload. Persona P never
touches it; personas M / B drop a `ProximWebRTC` node into their scene.

**Note on `example/` folder:** keep example files at the repo root (simpler for
anyone cloning and pressing F5) OR nest under `example/` (cleaner separation).
Recommendation: **keep at root for this repo**, since it's called
`proximity-example`. The clear rule becomes: anything under `addons/proxim/` is
the distributable; everything else is the demo.

---

## 2. Delete dead code / artifacts

Stale files still on disk or tracked in git that should go:

- `PLAN.md` (the old one — already deleted in working tree)
- `docs/godot-quickstart.md`, `docs/overview.md`, `docs/protocol-reference.md`
  (already deleted in working tree — confirm they're gone after commit)
- `temp.gd`, `temp.gd.uid`
- `main.tscn632702377.tmp`, `main.tscn646360804.tmp` (Godot editor scratch)
- `ProximMultiplayerPeer.gd.uid` (orphaned uid for a renamed/deleted script)
- `players.gd` / `players.gd.uid` — `MultiplayerSynchronizer` stub with no
  references anywhere in the project. Delete.
- `webrtc/lib/~libwebrtc_native.windows.template_debug.x86_64.dll` — Windows
  lockfile artifact.

Unused code inside kept files:

- `proxim_webrtc.gd:12` — `@export var proxim_peer_path: NodePath` is never
  read (ProximPeer is accessed as an autoload global). Remove, and update the
  file-level docstring that references it.

---

## 3. `.gitignore` and build artifacts

`.gitignore` currently only excludes `.godot/` and `/android/`. Expand to:

```
.godot/
/android/
/build/
/logs/
*.tmp
*.tscn*.tmp
```

Then `git rm -r --cached build/ logs/` to stop tracking artifacts that are
already in history. The `build/windows.zip` and `build/windows/*.pck` don't
belong in the repo — if a playable demo is desired, attach it to a GitHub
Release instead. (This needs explicit confirmation before running — destructive
to the published demo link if anything references it.)

---

## 4. Documentation — three docs, each with a clear audience

**Repo root `README.md`** (audience: someone who cloned the example)
- What Proxim is (one paragraph + link)
- "Run the demo" — prereqs (Godot 4.5, Proxim app running), which scene, the
  four buttons in the modal
- A "What's in here" section pointing at `addons/proxim/` as the reusable bit
- Screenshot/GIF

**`addons/proxim/README.md`** (audience: a dev dropping the addon into their
own project) — the most important doc. Structure:

1. Install (copy `addons/proxim/` into your project, enable plugin, done)
2. **Three usage paths**, each with a ~15-line copy-pasteable snippet:
   - **Persona M (multiplayer only):** add `ProximWebRTC` node →
     `await $ProximWebRTC.create_host()` → `multiplayer.multiplayer_peer =
     $ProximWebRTC.get_multiplayer_peer()`. No audio calls anywhere.
   - **Persona P (proximity only):** call `ProximPeer.connect_to_app()` →
     `update_call_peer({"gameId": my_peer_id})` using **your own** multiplayer
     system's peer IDs → wire `add_panner_node` + `hot_panner_node` +
     `hot_listener_node` from your game loop.
   - **Persona B (both):** same as M plus the audio calls from P. Reference
     the example `main.gd` as the canonical implementation.
3. API reference (can be generated from the existing docstrings — they're
   already thorough)
4. FAQ: "Do I need the WebRTC GDExtension?" — only for persona M/B. Link to
   the Godot webrtc-native release page. Do **not** bundle the `webrtc/`
   folder inside the addon.

**Inline docstrings** in `proxim_peer.gd` / `proxim_webrtc.gd` — already in
good shape, keep them.

---

## 5. Example scene — tighten the demo

`main.tscn` currently has four buttons: WebRTC Host/Join (loopback test) and
Proxim Host/Join. Keep the loopback test — it's a useful "is WebRTC installed"
smoke check and a nice demonstration that `ProximWebRTC` is genuinely optional
— but label it as such. Suggested tweaks:

- Modal title "WebRTC (Local)" → "Local Test (no Proxim)" with a small helper
  line: "Verifies the WebRTC extension is installed."
- Modal title "Proxim" → "Proxim (voice + spatial)" with a helper line:
  "Requires the Proxim app to be running."

`main.gd:18-21` — the deep `$UI/Modal/Margin/VBox/…/WebRTCHostButton` paths are
brittle. Unique-name the four buttons (`%WebRTCHostButton` etc.) to make the
connections readable. Small ergonomic win, zero behavior change.

The proximity-mode toggle (button in-world, cycles `off → gain → panner`) is a
nice touch and should stay — it's exactly what someone evaluating the addon
wants to flip between.

---

## 6. `ProximPeer` — keep single-autoload API, minor polish

Already well-organized (sections by comment banners: Peers / Gain / Panner /
Listener / Proximity / Internal). Deliberately **not recommending** a split
into `ProximPeer` (core) + `ProximAudio` (helper) — the one-autoload surface
is friendlier for persona M who just doesn't call the audio methods.

Small items:

- Add a top-level comment enumerating which methods matter for M vs P vs B, so
  persona M can see at a glance "I can ignore everything from `# ── Gain
  node ──` onward."
- `_log` is duplicated between `proxim_peer.gd:43-46` and
  `proxim_webrtc.gd:20-23`. Not worth extracting for 3 lines × 2 files, but
  noting it.

---

## 7. License

Add an MIT (or similar permissive) `LICENSE` at the repo root **and** a copy
inside `addons/proxim/` so the addon is self-contained when extracted. The
`webrtc/LICENSE.*` files are already in place for the GDExtension's deps.

---

## Suggested execution order

1. Add `.gitignore` entries, stop tracking `build/` + `logs/` (ask first).
2. Delete dead files (§2).
3. Create `addons/proxim/` and move `proxim_peer.gd` + `proxim_webrtc.gd` in.
   Add `plugin.cfg` + `plugin.gd`; remove the `autoload` line from
   `project.godot` (the plugin will re-register it).
4. Remove the unused `proxim_peer_path` export.
5. Write `addons/proxim/README.md` with the three persona snippets.
6. Polish `main.tscn` labels + unique-name the modal buttons.
7. Write repo-root `README.md` and `LICENSE`.
8. Verify all three paths still work end-to-end (Local WebRTC, Proxim host,
   Proxim join) before tagging a release.

---

## Open questions

- **Bundle the WebRTC GDExtension in the addon, or require users to install
  it separately?** Recommendation: separate — keeps the addon tiny, lets users
  track webrtc-native releases independently. `addons/proxim/README.md` will
  link to where to get it.
- **Should `ProximWebRTC.create_client` auto-assign gameId, or let the caller
  pass one?** Currently it picks a random 5-digit ID. For persona M/B this is
  fine; for persona P (using their own multiplayer) the mapping is their
  problem anyway. Leave as-is.
- **Versioning strategy for the addon.** Proposal: tag `v0.1.0` once the
  cleanup lands, use `plugin.cfg` `version=` field, and release addon-only
  zips from GitHub Releases (`addons/proxim/` zipped) alongside the full
  example repo.
