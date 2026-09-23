# Hyperspace Hole, as the router and the scanner see it.
#
# The ability itself is `pbUseHyperspaceHole` (179_ChallengeChampionship.rb:2517): it walks the event list
# for the first event whose name contains "Hoopa_Hole" inside |dx| < 8 and |dy| < 8, and sets that event's
# SELF-SWITCH A. It does not move her and it does not need her to be facing anything. On map 463 it is
# refused outright until switch 445.
#
# Every sigil in the game is built the same way, three pages:
#
#   p0  always   an inert ring, solid, action trigger, no commands
#   p1  self A   autorun -- the opening, which is what sets self B
#   p2  self B   PLAYER TOUCH, and a transfer command
#
# So a ring is a DOOR that has to be unlocked before it is a door. Once self B is on the core's own warp
# scan sees it like any other touch-warp; before that the live page carries no transfer command at all,
# which is why nothing in the mod knew these existed. Same blind spot the Tesseract had.
#
# For the router that makes it simpler than Heart Swap: no box of tiles to emit, because she has to walk
# into the ring anyway and anywhere she can do that is already inside the ability's range. The ring is
# registered as an ordinary warp row, and the guide says the extra button when she arrives.
#
# The table is lifted from the map archive -- 34 rings across 30 maps, every one with a destination.
module PokeAccess
  module InsurgenceHyperspace
    # map => [[x, y, destination map, destination x, destination y], ...]
    RINGS = {
      176 => [[50,61,398,35,15]],
      188 => [[48,48,545,39,40]],
      398 => [[35,15,176,50,62]],
      402 => [[47,13,403,36,12]],
      403 => [[36,12,402,47,13]],
      444 => [[41,15,468,20,10]],
      455 => [[41,83,455,82,33], [82,33,455,41,83]],
      463 => [[17,8,444,41,15]],
      468 => [[20,10,444,41,15]],
      523 => [[49,86,151,21,8]],
      529 => [[26,19,530,26,79]],
      530 => [[26,79,529,26,19]],
      540 => [[41,15,468,20,10]],
      541 => [[17,8,444,41,15]],
      545 => [[39,40,188,48,48]],
      630 => [[41,15,468,20,10]],
      676 => [[92,66,680,27,55], [112,21,681,27,53]],
      680 => [[27,55,676,92,66]],
      681 => [[27,53,676,112,21], [36,12,402,46,13]],
      689 => [[92,66,680,27,55], [112,21,681,27,53]],
      690 => [[17,9,444,41,15]],
      738 => [[36,12,402,46,13]],
      742 => [[34,21,743,34,21]],
      743 => [[34,21,742,34,21]],
      744 => [[34,21,676,92,66]],
      748 => [[17,8,444,41,15]],
      749 => [[64,18,784,19,23]],
      784 => [[19,22,749,64,18]],
      797 => [[41,15,468,20,10]],
      798 => [[36,12,402,46,13]]
    }

    # The ability is hers when this slot of the Mew-ability list is set (102_PokemonItemEffects.rb:590).
    ABILITY_VAR = 42
    ABILITY_SLOT = 6

    # pbUseHyperspaceHole's one special case: refused on this map until this switch.
    SEALED_MAP = 463
    SEALED_SWITCH = 445

    def self.unlocked?
      v = ($game_variables && $game_variables[ABILITY_VAR])
      v.is_a?(Array) && v[ABILITY_SLOT] == true
    rescue StandardError
      false
    end

    def self.sealed?(mid)
      mid == SEALED_MAP && !($game_switches[SEALED_SWITCH] rescue false)
    rescue StandardError
      false
    end

    def self.ring?(ev)
      (ev.name.to_s rescue "").include?("Hoopa_Hole")
    rescue StandardError
      false
    end

    # Already opened? Self-switch B is what the opening sequence sets, and it is what turns the ring into
    # a live transfer event.
    def self.open?(mid, eid)
      ($game_self_switches[[mid, eid, "B"]] rescue false) ? true : false
    rescue StandardError
      false
    end

    # WarpNet rows. Answered for EVERY map, not just the live one: a ring two maps away is a door the
    # closure should be able to plan through, and neither the live warp scan nor ForeignMap can see one,
    # because the page carrying the transfer command is not the page that is live. A static hash lookup,
    # so this stays cheap on the per-node path.
    def self.links(mid)
      return [] unless unlocked?
      return [] if sealed?(mid)
      list = RINGS[mid]
      return [] unless list
      list.map { |x, y, dm, dx, dy| [x, y, dm, dx, dy, nil, :hyperspace] }
    rescue StandardError
      []
    end

    # A ring on ANOTHER map, so the scanner can offer one she cannot see yet.
    RingTarget = Class.new(PokeAccess::Locator::RemoteTarget)

    # Asked ONCE from the closure the router already builds -- never one search per remote ring. Doing that
    # the other way is what made every doorway take thirty seconds when the Tesseract went in.
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

    # Memoised on where she is standing, because this is rebuilt every time the category list is.
    def self.targets
      return [] unless unlocked?
      here = ($game_map.map_id rescue nil)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      key = [here, px, py]
      return @cached if @cache_key == key && @cached
      label = PokeAccess::I18n.t(:hs_ring)
      reach = nil
      ranked = []
      RINGS.each do |mid, list|
        next if sealed?(mid)
        if mid != here
          reach = reachable_maps if reach.nil?
          next unless reach[mid]
        end
        list.each do |x, y, _dm, _dx, _dy|
          if mid == here
            t = PokeAccess::Locator::SurfaceTarget.new(x, y, label, :rings)
            ranked.push([0, 0, (x - px).abs + (y - py).abs, t])
          else
            leg = (PokeAccess::WarpNet.first_leg(mid, x, y) rescue nil)
            next unless leg
            ranked.push([1, leg[1].to_i, 0, RingTarget.new(mid, x, y, label)])
          end
        end
      end
      @cache_key = key
      @cached = ranked.sort_by { |a, b, c, _t| [a, b, c] }.map { |r| r[3] }
    rescue StandardError
      []
    end

    # Answers from this map's own ring list when it can: this runs on every map change and must never be
    # the thing that does the searching.
    def self.any_targets?
      return false unless unlocked?
      here = ($game_map.map_id rescue nil)
      return false if sealed?(here)
      mine = RINGS[here]
      return true if mine && !mine.empty?
      !targets.empty?
    rescue StandardError
      false
    end

    def self.place_phrase(t)
      return nil unless t.is_a?(RingTarget)
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

    # What the scanner calls one. A ring she has already opened is a plain doorway and says so, because
    # the thing she needs to know is whether there is still a button to press.
    def self.label(ev)
      return nil unless ring?(ev)
      mid = ($game_map.map_id rescue nil)
      if open?(mid, (ev.id rescue 0))
        PokeAccess::I18n.t(:hs_ring_open)
      else
        PokeAccess::I18n.t(:hs_ring)
      end
    rescue StandardError
      nil
    end
  end
end

PokeAccess::Locator.register_event_reader { |ev| PokeAccess::InsurgenceHyperspace.label(ev) }
PokeAccess::Locator.register_mechanic_exit { |ev| PokeAccess::InsurgenceHyperspace.ring?(ev) }
PokeAccess::WarpNet.register_link_source { |mid| PokeAccess::InsurgenceHyperspace.links(mid) }

# Arriving at a ring, the route is not finished: it has to be opened before it will take her anywhere.
PokeAccess::Locator.register_crossing_kind do |t|
  :hyperspace if (t.respond_to?(:key) && t.key == :rings) ||
                 (t.respond_to?(:name) && [PokeAccess::I18n.t(:hs_ring).to_s,
                                           PokeAccess::I18n.t(:hs_ring_open).to_s].include?(t.name.to_s))
end

PokeAccess::Locator.register_category(:rings,
  :label     => :tcat_rings,
  :available => lambda { PokeAccess::InsurgenceHyperspace.any_targets? },
  :targets   => lambda { PokeAccess::InsurgenceHyperspace.targets },
  :place     => lambda { |t| PokeAccess::InsurgenceHyperspace.place_phrase(t) })
