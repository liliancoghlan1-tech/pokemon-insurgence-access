# CRYSTAL CAVES (map 445) -- the boulder room, as a walkthrough.
#
# Twenty-nine hand-built push boulders. Arriving from map 443 she lands at 42,21 with FORTY-FOUR tiles to
# stand on and no way out; four shoves open the room and the door to map 444.
#
# These are not Strength boulders. They are the same event shape as the Fiery Caverns one: stand on the
# tile behind, walk into it, and it steps one tile the way she is facing while she stays put. The four
# shoves below are the whole solution, found by breadth-first search over (player region, boulder set)
# using the game's own rules, so they are the FEWEST -- there is no shorter way through.
#
# They reset every time she leaves the map, which is why this belongs in the mod rather than in a note:
# the room has to be re-solved on every visit. She has already had to be driven through it once.
#
# Written as CHAINS rather than as four steps, because two of the shoves are the same boulder pushed
# twice. A flat list could only see the second shove after the first had happened -- so a fresh room
# announced "3 still to do" for a four-shove job, and the count did not move when she made the first one.
# A chain knows where its boulder started and where it has to end, finds it wherever it currently sits,
# and counts the shoves left from there. That also makes the whole thing self-correcting: shove one the
# wrong way and the count for that chain simply goes back up.
PokeAccess::Game.define("insurgence") do
  # [[boulder's starting tile], direction to press, how many tiles it has to travel]
  CC445_CHAINS = [
    [[46, 30], 2, 2],
    [[21, 45], 8, 1],
    [[19, 43], 4, 1]
  ]
  # direction => [step the boulder takes, where she stands to push it]
  CC445_DELTA = { 2 => [[0, 1], [0, -1]], 8 => [[0, -1], [0, 1]],
                  4 => [[-1, 0], [1, 0]], 6 => [[1, 0], [-1, 0]] }

  puzzle(445,
    :kind        => :walkthrough,
    :walkthrough => lambda {
      live = {}
      ($game_map.events.each_value do |ev|
        live[[ev.x, ev.y]] = true if (ev.name.to_s rescue "") == "boulder"
      end rescue nil)
      out = []
      CC445_CHAINS.each do |from, dir, count|
        step, behind = CC445_DELTA[dir]
        # Where is this chain's boulder now? Somewhere between where it started and where it must finish.
        at = nil
        (0...count).each do |i|
          t = [from[0] + step[0] * i, from[1] + step[1] * i]
          if live[t]
            at = [t, i]
            break
          end
        end
        next if at.nil?          # already home, or shoved off the line entirely
        # One line per shove still owed, so the count is the real number of shoves left.
        (at[1]...count).each do |i|
          t = [from[0] + step[0] * i, from[1] + step[1] * i]
          out.push(PokeAccess::I18n.t(:wt_shove,
                                      :where => PokeAccess::I18n.t(:laser_at,
                                                                   :x => (t[0] + behind[0]).to_s,
                                                                   :y => (t[1] + behind[1]).to_s),
                                      :dir => PokeAccess::I18n.t(PokeAccess::Laser::DIR_KEY[
                                        { 8 => 0, 6 => 1, 2 => 2, 4 => 3 }[dir]])))
        end
      end
      out
    })
end
