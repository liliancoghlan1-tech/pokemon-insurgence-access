# Third-party notices

The source code in this repository is MIT licensed (see `LICENSE`). The
prebuilt binaries shipped with the downloadable pack are not ours, and each one
keeps its own licence. They are listed here so that anyone redistributing this
pack knows what they are passing on.

## In the downloadable release only

### mkxp-z — the engine (`Insurgence-mkxpz.exe`)

mkxp-z is an open-source reimplementation of the RPG Maker XP runtime, licensed
under the **GNU General Public License, version 2**. Source:
<https://github.com/mkxp-z/mkxp-z>

This pack redistributes an unmodified mkxp-z binary built against **Ruby
1.8.7**, which is the interpreter era Pokémon Insurgence's scripts are written
for. A modern mkxp-z build uses Ruby 3.x and breaks the game's own code, so the
older build is required rather than preferred.

**Known gap, stated plainly:** this binary was taken from another Essentials
fangame's distribution, and it carries no version banner, so the exact upstream
commit it was built from has not been identified. The GPL asks a redistributor
to make the corresponding source available. Until that build is pinned down,
the offer here is: the engine is unmodified upstream mkxp-z, its source is at
the link above, and if you need the precise revision, open an issue and it will
be tracked down or the engine rebuilt from a known commit.

If you would rather not take a binary on those terms, the pack works with any
Ruby 1.8.7 mkxp-z build you compile yourself — rename it
`Insurgence-mkxpz.exe`, drop it in the game folder, and everything else in the
pack is unchanged.

### FluidSynth (`fluidsynth.dll`)

Software synthesiser, **LGPL 2.1**. Source: <https://github.com/FluidSynth/fluidsynth>
Redistributed unmodified. Insurgence's music is 1136 MIDI files, so without a
synthesiser the game is silent.

### GMGSx soundfont (`soundfont.sf2`)

The file's own embedded copyright field reads **"Public Domain"**
(`INAM: GMGSx.sf2`, `ICOP: Public Domain`). It supplies the instruments
FluidSynth plays the MIDI music with.

## Inherited from PokeEssentialsAccess

These ship with the upstream mod and this fork does not change them.

### Steam Audio (`phonon.dll`)

© Valve Corporation. <https://valvesoftware.github.io/steam-audio/>
Provides the binaural 3D sonar. Distributed as a separate download in the
release because of its size (~50 MB), and the mod runs without it — you lose
the 3D placement but keep the left/centre/right cues.

### prism (`prism.dll`)

Screen-reader access library, © Ethin Probst, **MPL-2.0**.
<https://github.com/ethindp/prism> — this is the piece that talks to NVDA,
JAWS, SAPI, ZDSR and braille displays.

`prism_pea.dll` is PokeEssentialsAccess's own bridge over it and is MIT, part
of the upstream project.

### PA3D_steam.dll

PokeEssentialsAccess's own Steam Audio bridge, MIT, part of the upstream
project.

## Pokémon Insurgence itself

Pokémon Insurgence is by the Insurgence team. **No part of the game is
distributed here** — no graphics, audio, text, maps or scripts. You supply your
own copy of the game.

The one nuance worth stating: `games/insurgence/victoryroad.rb`,
`crystalroute.rb` and the other puzzle files contain routing tables that were
*computed from* the game's map files — tile coordinates and which direction to
press. That is walkthrough data about the game, in the same sense a written
guide is, rather than any of the game's own content.
