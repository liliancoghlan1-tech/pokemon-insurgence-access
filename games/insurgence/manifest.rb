# Load order for the Pokemon Insurgence game modules (no .rb), loaded after core. Insurgence is a gen-6
# era game and the core covers it, so this profile holds only what is genuinely the game's own -- its
# secret bases, whose contents are placed into empty placeholder events at runtime and are therefore
# invisible to every engine-level rule the core has.
{
  :modules => %w[
    constants
    insurgence
    puzzles
    tesseract
    heartswap
    lasers
    crystalcaves
    crystalroute
    hyperspace
    victoryroad
  ],
  :plugins => :auto
}
