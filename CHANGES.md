# What this fork changes

Measured against a clean checkout of **PokeEssentialsAccess v0.4.5**, the
release this was forked from:

**68 files changed — about 13,400 lines added, about 2,000 changed or removed.**

Everything here was built while playing Pokémon Insurgence from a new game to
the Hall of Fame with a screen reader, so the list is a record of what actually
stopped a blind player getting through, in the order it stopped them.

---

## Getting the mod to load at all

The upstream mod cannot install into Insurgence. It loads through mkxp-z's
`preloadScript` hook, and Insurgence ships the original RPG Maker engine
(`RGSS102E.dll`, data sealed in `Game.rgssad`, no `mkxp.json`), so there is no
hook to load into.

- **An mkxp-z engine built for Ruby 1.8.7**, the interpreter era Insurgence's
  scripts are written for. A modern mkxp-z is Ruby 3.x and breaks the game's
  own code. The game's `Game.exe` is left untouched and the swap is reversible
  by deleting the files the pack added.
- **`game-files/insurgence_compat.rb`** — Insurgence's mode-7 camera
  (`MGC_Hmode7.dll`) crashes this engine, and the crash lands *during the
  intro*, so a new game was impossible. This disables the camera projection
  only. No map, event, NPC or script is removed; the effect is purely visual.
- **Working music** — 1136 MIDI files, so FluidSynth and a soundfont are
  included and wired up in `mkxp.json`.
- **`games/catalog.json`** — a new `insurgence` entry so the installer detects
  the game and picks the right profile.

## Core changes — these are not Insurgence-specific

45 files under `core/`. They would apply to any Essentials fangame the upstream
mod supports.

### Navigation

The router previously understood walking and nothing else, which meant large
parts of any game reported "no route" even though a sighted player walks
straight through them.

- **`core/nav/pathfinder.rb`** — every mechanism is now an edge in the graph,
  resolved in one place (`move_target`) that A*, the flood fill and the surf
  sweep all share:
  - **bump-triggered forced moves** (diagonal staircases) — walking into what
    reads as a wall carries you diagonally. Measured across 4,700 maps: 1,146
    of these exist, 1,076 in Insurgence alone.
  - **multi-branch events** — a staircase has one branch per direction in a
    single event page, and the old code kept only the last, silently discarding
    one direction up the stairs. 477 events affected.
  - **internal warps** — a walk-onto transfer landing on the same map: a cave
    floor, an inner doorway. 1,182 usable ones found. The old router walked
    through these as if they were floor, which produced routes that teleported
    you part-way.
- **`core/nav/dive.rb`, `locator_surfaces.rb`, `terrain.rb`** — surfing. The
  router could not plot a course on water at all. It now can, knows getting on
  the water is a confirm-and-answer-yes rather than a step, knows it cannot
  swim up a waterfall, and the guidance keeps running across the shoreline
  instead of stopping at it.
- **`core/nav/foreign_map.rb`, `warpnet.rb`, `gates.rb`** — routing *through*
  doors to another map. Pick a gym leader and the directions walk you through
  the building to them, one leg at a time, and the target survives the door.
  `gates.rb` handles doors a story event has not unlocked yet.
- **`core/nav/map_meta.rb`, `locator_naming.rb`** — door naming. Essentials
  names every interior after the town it sits in, so every door in a town read
  "exit to Suntouched City". They now read "entrance to PokeMall", "Pokémon
  Centre", "Suntouched City, south side", "way through to x 38, y 44" inside a
  maze, and "way to Rezzai Desert, not open yet".
- **`core/nav/roamers.rb`** + four new sounds — hidden roamers. Some missions
  hide an invisible moving thing whose only cue is a puff of dust with no sound
  at all. It now makes a sound where it is.
- **`core/field/seen.rb`** — a "not looked at" category listing things on this
  map you have walked past without interacting with.
- **`core/nav/guide.rb`** — step-by-step guidance that re-plans from the real
  tile every tick, so a staircase or a warp self-corrects instead of announcing
  "off the route".

### Reading

- **`core/dialogue/dialogue.rb`** — a bug ate the first word of any line
  starting with a formatting code.
- **`core/dialogue/pages.rb`** (new) — long conversations fell further and
  further behind your key presses, because each line was queued instead of
  interrupting.
- **`core/nav/locator_naming.rb`** — NPCs were announced as sprite filenames.
  They are now named by their job — "Shop attendant", "Scientist", "Miner" —
  read out of the game's own trainer data.
- **`core/menus/menus.rb`** — shop item descriptions read while you browse the
  shelf.
- **`core/menus/pokedex_entry.rb`** (new reader) — the Pokédex entry you get on
  *catching* something new is a separate screen from the browsable Pokédex and
  was never read.
- **`core/party/gen6/summary_g6.rb`** — ability descriptions on the summary
  screen. **`core/battle/gen6/battle_g6.rb`** — the opponent's gender.
- **`core/field/minigames.rb`** — one-off spoken briefings for minigames, which
  are otherwise taught entirely by watching the screen. The same sliding-tile
  puzzle has *seven* variants with different controls and nothing on screen
  says which one you opened; the controls were read out of the game's own
  `pbMain`, not guessed. Voltorb Flip too.

### Puzzles

- **`core/puzzles/laser.rb`, `push.rb`, `walkthrough.rb`** (all new) — a
  general laser-grid reader, Strength boulder shoves planned as part of a
  route, and a walkthrough layer that speaks the remaining steps of a puzzle
  you are standing in, worked out from live state every time, so doing
  something out of order just changes the next line. On by default, switchable
  off in the mod's own menu under General.

### Optional assists

**`core/field/assist.rb`** (new), all **off** by default, in the mod's menu
under Assists:

- wild encounter rate — normal, half, quarter, none
- experience — normal, double, triple
- shared experience on or off

The reason they exist: a blind player walks a great deal further than a sighted
one for the same journey, and every step is another encounter roll.

## Insurgence-specific — `games/insurgence/`, 5,233 lines, all new

- **`victoryroad.rb`** (2,709 lines) — Victory Road end to end, nine maps, all
  three ice-slide floors, the ledges and the doors. It is a *policy*, not a
  path: all 24,689 standable tiles on the road carry the press that gets you to
  the League fastest from there, so there is no wrong place to start. Solved
  offline against the map files with ice slides, ledge jumps, surf launches and
  bump-triggered doors each modelled the way the game runs them.
- **`crystalroute.rb`, `crystalcaves.rb`** (1,103) — Crystal Caves, including
  the Tesseract crossings.
- **`lasers.rb`** — the Erebus Gym laser grid: every mirror, its setting, and
  the line the beam currently draws.
- **`hyperspace.rb`, `tesseract.rb`, `heartswap.rb`** — Hyperspace Hole rings,
  Tesseract shift spots and Heart Swap statues understood as doors, including
  whether each is open yet.
- **`insurgence.rb`** — the secret base reader, so your base contents appear in
  the scanner.

## Language files

`lang/*.txt` — the six language files carry the new strings. The lines added by
this fork exist in **English only**; the other five fall back to English for
those particular lines rather than going missing.
