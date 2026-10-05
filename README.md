# Dungeon

A multiplayer arena FPS built with **Godot 4.6** and **GDScript**.

Players choose between melee and ranged characters, join a multiplayer session, and compete across different game modes including **Deathmatch** and **Point Capture**.

The project focuses on multiplayer gameplay, server-authoritative combat, player movement, items, and match management.

## Features

* **Multiplayer** — Create or join matches using session codes
* **Two Playstyles**

  * Shovel melee combat with blocking
  * Bow with chargeable attacks and rapid-fire shots
* **Multiple Game Modes**

  * Deathmatch
  * Point Capture
  * Rotating match playlist
* **Usable Items**

  * Speed boost
  * Iceball
  * Mudball
  * Firework
  * Healing
* **Movement System**

  * Sprinting
  * Jumping
  * Sliding
  * Jump pads
* **Match System**

  * Free-for-all or team matches
  * Score limits
  * Optional time limits
  * Round transitions
  * Team-based spawning
* **Audio System**

  * Music and SFX controls
  * Positional sound effects
  * Persistent volume settings

## Multiplayer Architecture

The game uses a **host-authoritative multiplayer model**.

Players handle their own movement and send requests to the host for gameplay actions. The host validates important game events and controls the shared game state.

**Client**

* Player movement and camera
* Attack requests
* Local animations and effects

**Host**

* Damage and healing
* Knockback
* Kills and respawns
* Item and projectile spawning
* Capture points
* Scores and match results

This prevents individual clients from directly deciding important game state.

## Technology

* **Godot 4.6**
* **GDScript**
* **CharacterBody3D**
* **MultiplayerSynchronizer**
* **MultiplayerSpawner**
* **RPC-based networking**
* **WebRTC / Tube**
* **ENet fallback**

## Project Structure

```text
Scenes/
├── Player/
├── World/
├── Items/
└── UI/

scripts/
├── Player/
├── Network/
├── World/
├── Items/
└── UI/

Assets/
├── Models/
├── Textures/
└── Sounds/

addons/
├── Tube/
└── Terrain3D/
```

## Running the Project

1. Open the project in **Godot 4.6**.
2. Press **Play**.
3. Enter a player name.
4. Create a session or join one using a session code.
5. Choose a character and start the match.

## Development

This project is also being used as a learning project for multiplayer game development and game architecture.

For a more detailed walkthrough of the code and systems, see [`STUDY_GUIDE.md`](STUDY_GUIDE.md).
