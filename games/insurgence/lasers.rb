# EREBUS GYM (maps 542 and 543) -- the mirror-and-beam grid.
#
# A beam leaves a fixed emitter and walks one tile at a time, continuing ONLY where an event stands: the
# hundreds of "laser" events are the track, and the first empty tile ends it. An event named "c" is a
# mirror -- an elbow joining two of its four faces -- and the beam turns there or is swallowed if it
# arrives at a closed face. Rotating one steps it clockwise: top-left, top-right, bottom-right,
# bottom-left. Stand beside it, face it, press the action key, and answer the prompt.
#
# The emitters and the reflection table are read straight out of pbDrawLasers and getDirectionReflect
# (179_ChallengeChampionship.rb:4199 and :4314), which is also where these coordinates come from --
# currX=12, currY=14, and currY=10 on map 542, which alone has a second beam from 14,26.
#
# Map 486 is an Erebus Gym too and carries mirrors, but it has no track under its emitter and sets no
# switches, so it is not a live puzzle and is deliberately not registered: a room that announced a beam
# dying on its first tile would be noise.
#
# NOTHING HERE SOLVES IT. The readout gives what is on the screen -- where the mirrors are, which way each
# is turned, and the line the beam draws -- and stops there.
# THE SOLUTIONS. Each grid has exactly ONE -- the search over every reachable assignment of mirror
# settings returns a single answer on both maps -- so these are the settings, not a route among several.
# They were solved offline against the map files with the game's own reflection table, then replayed to
# confirm both beams land on their receivers.
#
# Mirrors NOT listed are off the beam's path and can sit at any setting; the walkthrough leaves them out
# rather than sending her across the room to turn something that changes nothing.
SOLVED_542 = { [12,15] => 1, [16,15] => 3, [20,15] => 2, [24,15] => 0, [16,21] => 1, [20,21] => 0,
               [18,31] => 2, [22,31] => 0, [14,35] => 1, [18,35] => 0 }
SOLVED_543 = { [12,18] => 1, [18,18] => 3, [24,18] => 1, [30,18] => 3, [12,24] => 2, [18,24] => 0,
               [6,30] => 2, [12,30] => 0, [18,30] => 2, [24,30] => 3, [6,36] => 1, [18,36] => 0,
               [24,36] => 1, [30,36] => 0 }

PokeAccess::Game.define("insurgence") do
  # beams: [start x, start y, direction] with 2 = down, the game's own numbering. The first tile the beam
  # examines is one step on from the start, exactly as the engine's loop does it.
  puzzle(542,
    :kind        => :laser,
    :beams       => [[12, 10, 2], [14, 26, 2]],
    :receivers   => [[24, 11], [22, 26]],
    :walkthrough => lambda { PokeAccess::Laser.walkthrough(SOLVED_542) },
    :solved      => lambda { $game_switches[516] && $game_switches[517] })

  puzzle(543,
    :kind        => :laser,
    :beams       => [[12, 14, 2]],
    :receivers   => [[24, 15], [24, 14]],
    :walkthrough => lambda { PokeAccess::Laser.walkthrough(SOLVED_543) },
    :solved      => lambda { $game_switches[515] })
end

# The mirrors, to the scanner and the cane: named with the way they are currently turned, and listable so
# she can walk to one instead of sweeping the room for an unnamed tile event.
PokeAccess::Locator.register_event_reader { |ev| PokeAccess::Laser.label(ev) }
PokeAccess::Locator.register_category(:mirrors,
  :label     => :tcat_mirrors,
  :available => lambda { PokeAccess::Laser.any_targets? },
  :targets   => lambda { PokeAccess::Laser.targets })
