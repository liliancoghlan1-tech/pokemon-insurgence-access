# Heart Swap, as the router and the scanner see it.
#
# It is a Mew ability that trades places with a statue: `pbUseHeartSwap` (179_ChallengeChampionship.rb:2471)
# walks the event list for the first event whose name contains "HeartSwap_S" inside a box of
# |dx| < 8 and |dy| < 8, then moves HER onto that event's tile and the event onto hers. No facing, no
# action button, and nothing at all while surfing ("Nothing happened...").
#
# That makes it a crossing of a kind the router has not had before: SAME map, different tile. It is the
# only way past several pieces of terrain in the game -- Deyraan Town's cave sits above a waterfall with
# no way up it, and the statue on the far side is the intended route. To the closure it is shaped like a
# dive link with the destination map equal to the source map, which extend_closure already allows (it
# guards only against a link back to the very tile being expanded).
#
# Two things had to be right for the region model:
#
#   * The landing is the STATUE'S tile, and the statue is standing on it -- but only until the swap, which
#     moves it to where she was. So the landing is genuinely standable, and `standable_landing?` agrees:
#     it asks whether the player can LEAVE that tile in some direction, which does not consult the event
#     sitting on it. The pocket above Deyraan's waterfall is four tiles and gets its own region, which is
#     the whole point -- the neighbour shortcut would have filed it into the town she is standing in.
#   * The tile she uses it FROM must be somewhere she can stand, so the box is filtered rather than
#     emitted whole. A 15 by 15 box is 225 tiles against the Tesseract's 25, and Route 14 carries five
#     statues; emitting the lot unfiltered would put over a thousand rows in front of every closure node.
#
# The statue table is lifted from the map archive (38 statues across 30 maps) rather than hand-listed, so
# the scanner can name one on a floor she is not standing on.
module PokeAccess
  module InsurgenceHeartSwap
    # map => [[x, y], ...] -- every HeartSwap_S statue in the game.
    SPOTS = {
      43 => [[6,23]],
      111 => [[29,22]],
      120 => [[51,31]],
      180 => [[85,58]],
      393 => [[53,33], [54,35], [87,55]],
      396 => [[54,35], [64,56], [65,57], [66,56], [87,55]],
      401 => [[62,26]],
      405 => [[50,65]],
      432 => [[63,27]],
      451 => [[7,61], [48,36]],
      454 => [[83,16]],
      470 => [[13,10]],
      471 => [[41,33]],
      482 => [[0,29]],
      508 => [[43,31]],
      520 => [[27,5]],
      524 => [[51,62]],
      527 => [[12,30]],
      530 => [[43,46]],
      563 => [[4,77]],
      641 => [[23,11]],
      662 => [[50,65]],
      663 => [[50,65]],
      664 => [[50,70]],
      691 => [[40,45]],
      750 => [[8,19], [41,22]],
      751 => [[49,31]],
      754 => [[49,31]],
      761 => [[59,41]],
      765 => [[26,47]]
    }

    # How far from a statue the game accepts the ability. It tests |dx| < 8 and |dy| < 8, so seven tiles.
    REACH = 7

    # The ability is hers when this slot of the Mew-ability list is set -- the same test the game's own
    # ability menu uses (102_PokemonItemEffects.rb:589).
    ABILITY_VAR = 42
    ABILITY_SLOT = 5

    def self.unlocked?
      v = ($game_variables && $game_variables[ABILITY_VAR])
      v.is_a?(Array) && v[ABILITY_SLOT] == true
    rescue StandardError
      false
    end

    def self.statue?(ev)
      (ev.name.to_s rescue "").include?("HeartSwap_S")
    rescue StandardError
      false
    end

    # Where the statues are standing RIGHT NOW. A swap moves one, so this is read from the live event list
    # rather than from SPOTS, which records where they start.
    def self.live_spots
      out = []
      ($game_map.events.each_value { |ev| out.push([ev.x, ev.y]) if statue?(ev) } rescue nil)
      out.sort
    rescue StandardError
      []
    end

    # Can she be standing here? The router must never plan a leg from a tile she cannot occupy, and this is
    # also what keeps the 15 by 15 box down to a sane number of rows.
    def self.standable?(x, y)
      [2, 4, 6, 8].any? { |d| PokeAccess::Pathfinder.player_passable?(x, y, d) }
    rescue StandardError
      false
    end

    # WarpNet rows: every standable tile within reach of a statue crosses -- on the same map -- to the tile
    # the statue is on. Only the live map is answered; a swap is only ever offered as the leg she is about
    # to walk, and reading a foreign map's passability to filter the box is not worth the cost.
    #
    # Memoised on the statue positions, because warps() is asked once per node the closure expands and the
    # answer only changes when a statue moves.
    def self.links(mid)
      return [] unless unlocked?
      return [] unless mid == ($game_map.map_id rescue nil)
      return [] if ($PokemonGlobal.surfing rescue false)
      spots = live_spots
      return [] if spots.empty?
      key = [mid, spots]
      return @links if @links_key == key && @links
      out = []
      spots.each do |sx, sy|
        (-REACH..REACH).each do |dx|
          (-REACH..REACH).each do |dy|
            next if dx == 0 && dy == 0
            x = sx + dx; y = sy + dy
            next unless ($game_map.valid?(x, y) rescue false)
            next unless standable?(x, y)
            out.push([x, y, mid, sx, sy, nil, :heartswap])
          end
        end
      end
      @links_key = key
      @links = out
    rescue StandardError
      []
    end

    # A statue on ANOTHER map, so the scanner can offer one she cannot see yet.
    StatueTarget = Class.new(PokeAccess::Locator::RemoteTarget)

    # Where she actually walks to, for a statue on THIS map: the nearest tile she can reach that is in
    # range of it.
    #
    # Never the statue's own tile. The statue is standing on it, so she cannot occupy it -- and the whole
    # point of the ability is that the statue is somewhere there is no walking route to. Aimed at the
    # statue itself, the guide did the only thing left and pointed her at the water in front of the
    # Deyraan falls: "it's still trying to walk me through the waterfall that we're trying to subvert".
    # The target is the spot the ability is USED from, and the crossing line says so on arrival.
    #
    # reachable_set is the scanner's own walking flood, already built and memoised on her tile, so this is
    # 224 hash lookups and no search. If none of the box is reachable the statue tile is kept, which is no
    # worse than before: the router will simply report no route rather than invent one.
    def self.use_tile(sx, sy, px, py)
      set = (PokeAccess::Pathfinder.reachable_set rescue nil)
      return [sx, sy] unless set.is_a?(Hash)
      best = nil; bestd = nil
      (-REACH..REACH).each do |dx|
        (-REACH..REACH).each do |dy|
          next if dx == 0 && dy == 0
          x = sx + dx; y = sy + dy
          next unless set[PokeAccess::Pathfinder.pkey(x, y)]
          d = (x - px).abs + (y - py).abs
          if bestd.nil? || d < bestd
            bestd = d
            best = [x, y]
          end
        end
      end
      best || [sx, sy]
    rescue StandardError
      [sx, sy]
    end

    # The maps the router can currently plan a leg to, asked ONCE from the closure it already builds.
    # Asking WarpNet.first_leg per remote statue instead is what turned every doorway into a thirty-second
    # freeze when the Tesseract went in; the closure already knows which maps it reached.
    def self.reachable_maps
      mid = ($game_map.map_id rescue nil)
      return {} if mid.nil?
      c = (PokeAccess::WarpNet.closure(mid, $game_player.x, $game_player.y) rescue nil)
      nodes = c && c[:nodes]
      return {} unless nodes.is_a?(Array)
      out = {}
      nodes.each { |n| out[n[0]] = true }
      out
    rescue StandardError
      {}
    end

    # Statues worth listing: every one on this map, then every one the router can plan a leg to, nearest
    # first. Memoised on where she is standing, because this is rebuilt every time the category list is.
    def self.targets
      return [] unless unlocked?
      here = ($game_map.map_id rescue nil)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      key = [here, px, py]
      return @cached if @cache_key == key && @cached
      label = PokeAccess::I18n.t(:hs_statue)
      reach = nil
      ranked = []
      SPOTS.each do |mid, list|
        if mid != here
          reach = reachable_maps if reach.nil?
          next unless reach[mid]
        end
        list.each do |x, y|
          if mid == here
            ux, uy = use_tile(x, y, px, py)
            t = PokeAccess::Locator::SurfaceTarget.new(ux, uy, label, :heartswap)
            ranked.push([0, 0, (ux - px).abs + (uy - py).abs, t])
          else
            leg = (PokeAccess::WarpNet.first_leg(mid, x, y) rescue nil)
            next unless leg
            ranked.push([1, leg[1].to_i, 0, StatueTarget.new(mid, x, y, label)])
          end
        end
      end
      @cache_key = key
      @cached = ranked.sort_by { |a, b, c, _t| [a, b, c] }.map { |r| r[3] }
    rescue StandardError
      []
    end

    # Whether the category is worth offering. Answers from the map's own statue list when it can, because
    # this runs on every target rebuild and must never be the thing that does the searching.
    def self.any_targets?
      return false unless unlocked?
      here = ($game_map.map_id rescue nil)
      mine = SPOTS[here]
      return true if mine && !mine.empty?
      !targets.empty?
    rescue StandardError
      false
    end

    # Where a remote statue is, as spoken -- the map's name only once she has been there, the same rule
    # Story uses so an unvisited place is never named at her.
    def self.place_phrase(t)
      return nil unless t.is_a?(StatueTarget)
      seen = ($PokemonGlobal.visitedMaps rescue nil)
      if seen.nil? || seen[t.map_id]
        PokeAccess::I18n.t(:loc_on_map, :name => t.name.to_s,
                           :map => (PokeAccess::Locator.map_name(t.map_id) || "").to_s)
      else
        t.name.to_s
      end
    rescue StandardError
      nil
    end

    def self.label(ev)
      statue?(ev) ? PokeAccess::I18n.t(:hs_statue) : nil
    rescue StandardError
      nil
    end
  end
end

PokeAccess::Locator.register_event_reader { |ev| PokeAccess::InsurgenceHeartSwap.label(ev) }
PokeAccess::Locator.register_mechanic_exit { |ev| PokeAccess::InsurgenceHeartSwap.statue?(ev) }
PokeAccess::WarpNet.register_link_source { |mid| PokeAccess::InsurgenceHeartSwap.links(mid) }

# Unlike a doorway, a swap is used from where she is STANDING -- and unlike the Tesseract, not on the spot
# itself: the statue occupies its own tile, so the route ends beside it and the hold line has to say that
# the ability is what finishes the journey.
PokeAccess::Locator.register_crossing_kind do |t|
  :heartswap if (t.respond_to?(:key) && t.key == :heartswap) ||
                (t.respond_to?(:name) && t.name.to_s == PokeAccess::I18n.t(:hs_statue).to_s)
end

PokeAccess::Locator.register_category(:heartswap,
  :label     => :tcat_heartswap,
  :available => lambda { PokeAccess::InsurgenceHeartSwap.any_targets? },
  :targets   => lambda { PokeAccess::InsurgenceHeartSwap.targets },
  :place     => lambda { |t| PokeAccess::InsurgenceHeartSwap.place_phrase(t) })
