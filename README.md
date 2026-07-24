# GarrysCraft (Previously known as mcgm)

Experimental Minecraft Java <-> Garry's Mod bridge.

The authority lives in the GMod server. Minecraft clients connect directly to a
TCP listener hosted by the addon, using Minecraft offline mode, so no Microsoft
authentication is performed.

##Bugs and quirks
-Garry's Mod player must be online for Minecraft players to join

## What works in this prototype

- Minecraft Java 1.12.2 offline-mode handshake/login path. (if somone wants to try to get 1.13 working please make a PR although it must also still support 1.12)
- Minecraft server list status/ping.
- Chat forwarding (Both sides)
- Position forwarding:
  - Minecraft movement packets are tracked in GMod.
  - Minecraft players are shown in GMod as simple moving proxy models.
  - GMod players are spawned into Minecraft as player entities and teleported
    as they move.
  - Minecraft tab list contains `[MC]` and `[GMod]` entries.
- Cross-game interaction: (buggy)
  - GMod bullets and damage can hurt Minecraft proxies.
  - Minecraft users can attack visible GMod placeholders.
  - Minecraft chat from MC users is rebroadcast with a `[MC]` prefix.
  - Minecraft chat commands `/crowbar`, `/blast`, `/where`, and `/sync`
    affect GMod or refresh the shared arena.
- Shared arena:
  - GMod players are spawned onto the bridge platform by default.
  - Nearby GMod platform/prop hitboxes are projected into Minecraft as blocks.
- Experimental prop projection:
  - Nearby GMod physics props are sampled and sent as simple Minecraft block
    changes.
  shared blocks
## Requirements

Stock GMod Lua cannot open a raw TCP server. Install a LuaSocket-compatible GMod
binary module that exposes `require("socket")`.

The addon still runs inside the GMod server process; the socket module is only
the network primitive that Lua itself does not provide.

## Install

Copy this repository into a GMod addon folder, for example:

```text
garrysmod/addons/mcgm/
```

Then start the GMod server with the addon installed.

Or use the helper script:

```bash
chmod +x scripts/run-gmod-bridge.sh
GMOD_DIR="$HOME/gmod-ds" ./scripts/run-gmod-bridge.sh
```

If your server is somewhere else, change `GMOD_DIR`.

If you do not have the GMod dedicated server yet:

```bash
chmod +x scripts/install-gmod-server.sh
./scripts/install-gmod-server.sh
./scripts/run-gmod-bridge.sh
```

Install the socket module required by the Minecraft listener:

```bash
./scripts/install-gmod-luasocket.sh
```

Minecraft clients should connect with Java Edition 1.12.2 to:

```text
<gmod-server-ip>:25565
```

## Configuration

Edit [lua/mcgm/config.lua](lua/mcgm/config.lua).

Important settings:

- `port`: Minecraft listener port.
- `world_scale`: GMod units per Minecraft block.
- `enable_prop_blocks`: turns the prop-to-block experiment on/off.
- `prop_block_state`: Minecraft 1.12 block-state id used for projected props.
- `prop_scan_interval`: how often props are projected.
- `floor_block_state`: Minecraft 1.12 block-state id used for sampled floor.
- `minecraft_proxy_health`: health for Minecraft players represented in GMod.
- `minecraft_command_range`: range for Minecraft-originated GMod actions.
- `force_gmod_spawn_to_bridge`: move GMod players to the shared arena on spawn.
- `hitbox_sync_interval`: how often GMod prop/platform hitboxes are sent to MC.


