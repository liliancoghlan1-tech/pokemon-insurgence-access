# Pokémon Insurgence Accessibility Pack

This makes **Pokémon Insurgence** playable with a screen reader.

It is a fork of [PokeEssentialsAccess](https://github.com/tiflojuegos-com/PokeEssentialsAccess)
by tiflojuegos-com, plus the engine swap that gets it to load into Insurgence at
all, plus a long list of fixes and additions made while actually playing the
game through to the Hall of Fame.

**[Download the latest release](../../releases/latest)** · [what this fork changes](CHANGES.md) · [licences](THIRD-PARTY-NOTICES.md)

---

## What you need first

1. **Pokémon Insurgence 1.2.5 for Windows**, already downloaded and unzipped.
   This pack does **not** contain the game. If you have it working as an
   ordinary (silent) game, you are ready.
2. **A screen reader running**: NVDA, JAWS, ZDSR, or Windows SAPI voices. Start
   it *before* you start the game.

## There are two downloads

1. `Pokemon-Insurgence-Accessibility-Pack.zip` — the whole mod.
2. `phonon-3d-sound.zip` — one large file, the 3D audio library.

The second one is separate only because of its size. The mod works without it,
but you lose the binaural sonar that places people, doors and walls around you
in the stereo field; the simpler left, centre and right cues still play.

To include it: unzip it, and put the `phonon.dll` it contains into the pack
folder, right next to `Install.bat`. The installer will then put it in the
right place for you.

## Installing

Run **`Install.bat`**. It asks for the path of your Pokémon Insurgence folder —
the folder that contains `Game.exe` and `Game.rgssad` — and copies everything
in. It finishes by telling you whether 3D sound was installed.

By hand instead: copy everything inside the `Game files` folder into your
Pokémon Insurgence folder, keeping the folder structure, and put `phonon.dll`
into the `accessibility\lib` folder inside the game folder.

To add 3D sound after installing, that is the whole job: drop `phonon.dll` into
`<your game folder>\accessibility\lib` and restart the game.

Nothing already in the game folder is deleted, and the game's own `Game.exe` is
not touched, so you can undo all of this by deleting the files it added.

## Playing

Start the game with **`Play Pokemon Insurgence.bat`**, which the installer puts
in your game folder.

Do **not** start `Game.exe`. That is the game's original engine, which cannot
load the mod. The pack brings its own engine, `Insurgence-mkxpz.exe`, and that
is what the launcher runs.

Your saves live in `C:\Users\<your name>\Saved Games\Pokemon Insurgence`, the
same place the original engine uses, so an existing save carries straight over.

### The first launch

The game shows a message about fonts at startup. Press Enter three times to get
past it. It is harmless, but it returns every launch.

To stop it for good: open your Pokémon Insurgence folder, go into the `Fonts`
folder, select all eight `.ttf` files, right-click and choose **Install for all
users**. Windows will ask for administrator permission. That is all the game is
checking for.

After that you are at the title menu: New Game, Save Files, Controls, Options.
Enter confirms.

## The keys

| Key | What it does |
| --- | --- |
| `I` | Work out the route to the selected target |
| `J` / `L` | Previous / next target in the list |
| `K` | Announce the selected target |
| `T` | Read whatever has focus — a move, item, Pokémon, trainer — and, inside a puzzle, the state of the puzzle |
| `H` | Read your team's HP in battle |
| `G` | In battle, terrain conditions; outside battle, weather and time |
| `M` | Read your current coordinates |
| `O` | Open the mod's own settings menu |

With a modifier:

| Key | What it does |
| --- | --- |
| `Shift+J` / `Shift+L` | Change target category: people, objects, exits, and so on |
| `Shift+K` | Rename the selected target |
| `Ctrl+K` | Open the target's tag menu |
| `Shift+I` | Audible guidance towards the target, on or off |
| `Ctrl+I` | Step-by-step guidance on or off — it speaks the leg you are walking ("6 up") and the next one as you finish it |
| `Shift+T` | Repeat the last line of dialogue |
| `Shift+H` | Read the opposing team's HP |
| `Shift+M` | Rename the current map |
| `Ctrl+M` | Show or hide targets you cannot reach |
| `Ctrl+G` | Drop a named marker on the tile you are standing on. Markers get their own category in the locator |

Anywhere:

| Key | What it does |
| --- | --- |
| `Ctrl+Alt+F8` | Turn the mod off and on again, and retry the screen reader |
| `Ctrl+Alt+F9` | Write a diagnostic file to `accessibility\data\diag.txt` |
| `Ctrl+Alt+F10` | Speak a quick diagnostic, useful if something has gone quiet |

The game's own keys are awkward on some keyboards. Movement, confirm and cancel
can all be reassigned from the mod's menu (the `O` key).

## What this fork adds

The short version: the upstream mod does not install into Insurgence at all,
and once it does, plenty of Insurgence still does not read. Routing that
understands staircases, ledges, warps, surfing and boulder shoves; doors named
properly and routed through; NPCs named by their job instead of by sprite
filename; the laser gym, Hyperspace Hole, Crystal Caves and all of Victory
Road; minigame briefings; and optional encounter-rate and experience assists.

**[The full list, with the reasoning, is in CHANGES.md](CHANGES.md)** — 68
files changed against upstream v0.4.5, about 13,400 lines added.

## If something goes wrong

**There is no 3D sonar, but everything is spoken.**
`phonon.dll` is missing — see "There are two downloads" above.

**Nothing speaks at all.**
Windows Defender sometimes deletes `accessibility\lib\prism.dll`, which is the
piece that talks to the screen reader. Check whether that file is still there.
If not, restore it from the pack and add the game folder to Defender's
exclusions. Also check the screen reader was running *before* the game started,
and press `Ctrl+Alt+F8` to make it retry.

**The game will not start at all.**
Open `mkxp.json` in the game folder with Notepad and change
`"consoleOutput": false` to `"consoleOutput": true`. Launch again and a window
will print what the engine is doing, including any error.

**It starts but nothing is accessible.**
The mod did not load. Check that `accessibility\preload_access.rb` exists, and
that `mkxp.json` lists both `insurgence_compat.rb` and
`accessibility/preload_access.rb` in `preloadScript`, **in that order**.

**Something is not read, or a map says there is no route.**
Press `Ctrl+Alt+F9`. It writes `accessibility\data\diag.txt`, which is the file
to attach when you report it.

## Honest limits

- Built and tested on **Insurgence 1.2.5**. Another version may move things the
  Insurgence-specific readers depend on.
- **Insurgence is the only game this has been played on.** The changes under
  `core/` are not Insurgence-specific and they hook methods that exist in the
  other fangames the upstream mod supports, so in principle they apply there
  too — but "in principle" is all that can honestly be claimed. Nobody has sat
  down and played another game with this fork. If you try one and something
  reads worse than it does with upstream PokeEssentialsAccess, that is worth an
  issue, and it is not a surprise.
- **It will not disturb your other games.** Each game folder holds its own copy
  of the mod, and this pack only ever installs into the Insurgence folder you
  point it at. If you already run PokeEssentialsAccess on other fangames, those
  installs are untouched and keep whatever version they have.
- The **postgame** has had far less use than the main story.
- The mod speaks six languages, but the lines added by this fork — the puzzle
  readers, the walkthrough, the newer navigation wording — exist in **English
  only**. Switching the mod to another language makes those particular lines
  fall back to English rather than go missing.
- Insurgence replaces two screens the upstream mod normally hooks, the Pokédex
  form list and the move relearner's move list, so those two have no dedicated
  reader.
- The **mode-7 camera is off** — it crashes this engine during the intro, so it
  had to go. If you have some sight, a handful of maps will look flat rather
  than tilted. Nothing is removed from the game itself.

## Repository layout

| Path | What it is |
| --- | --- |
| `core/` | The mod proper — reading, navigation, puzzles, audio. Forked from upstream |
| `games/insurgence/` | The Insurgence profile: laser gym, Victory Road, Crystal Caves, Hyperspace, secret base. All new |
| `games/catalog.json` | Game detection. `generic` must stay **last** or it swallows the rest |
| `game-files/` | What goes into the game folder: the compat shim, `mkxp.json`, the installer and the launcher |
| `lang/` | The six language files |
| `assets/` | Sounds, and the small native libraries |
| `docs/` | Upstream's technical documentation |

`assets/x64/phonon.dll` and `assets/x86/phonon.dll` are **not in this
repository** — they are ~50 MB each and belong to Valve. They ship in the
release download. If you are working from a clone, take them from an upstream
PokeEssentialsAccess release.

## Credits and licence

**PokeEssentialsAccess** is by **tiflojuegos-com** and is released under the MIT
licence. This fork is released under the same licence, with their copyright
notice retained as that licence requires. They wrote the mod; this repository
is that mod plus the work needed to get one particular game working with it.

**Pokémon Insurgence** is by the Insurgence team. This pack contains no part of
the game.

The engine is **mkxp-z**, an open-source reimplementation of the RPG Maker XP
runtime, under the GPL. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
for every bundled binary and its licence.
