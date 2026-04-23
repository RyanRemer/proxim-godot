# Proxim — Godot example

Small Godot 4.5 demo project for the Proxim addon. Demonstrates WebRTC
multiplayer over Proxim's signaling channel plus spatial voice chat
(gain falloff or full 3D panner) in one scene.

The reusable part is [`addons/proxim/`](addons/proxim/). Everything else
in this repo is the demo. **Look at the README.md file in that directory for more instructions**

## Run the demo

1. Install Godot 4.5.
2. Start the Proxim companion app (it listens on `ws://127.0.0.1:5656`).
3. Open this project in Godot and press **F5**.

The start screen has two panels:

- **Local Test (no Proxim)** — host/join a WebRTC loopback inside a single
  running instance. A quick smoke check that the WebRTC extension is
  installed. No Proxim app required.
- **Proxim (voice + spatial)** — host or join through the Proxim app.
  Voice chat comes free. In-world, walk up to the button on the far
  platform and press **E** to cycle the proximity mode:
  `off → gain → panner`.

**Controls:** WASD move · Space jump · Tab toggle mouse · E interact · Esc quit.

## What's in here

- [`addons/proxim/`](addons/proxim/) — the reusable addon. Drop this folder
  into any Godot 4 project to use Proxim. See
  [`addons/proxim/README.md`](addons/proxim/README.md) for the three usage
  paths (multiplayer transport, proximity chat, or both).
- `main.tscn` / `main.gd` — the example scene wiring the full stack.
- `player.tscn` / `player.gd` — FPS-style controller, camera pose feeds the
  spatial audio listener.
- `button.tscn` / `button.gd` — in-world button that cycles the proximity
  mode.
- `local_webrtc_peer.gd` — loopback WebRTC peer used only by the Local Test
  panel.
- `webrtc/` — pre-bundled
  [godot-webrtc-native](https://github.com/godotengine/webrtc-native)
  GDExtension binaries so the demo runs without a separate install step.
  If you use `addons/proxim/` in your own project, install the extension
  there too.
