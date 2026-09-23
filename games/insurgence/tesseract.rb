# The Tesseract, as the router and the scanner see it.
#
# It is a Mew ability that shifts you between two versions of the same place. The whole mechanic lives in
# `useTesseract` (179_ChallengeChampionship.rb:3971), and it has two modes, told apart by the name of the
# event you are standing near:
#
#   Tesseract_Spot_1 -- "go there". Stand within TWO tiles of it (the game tests |dx| < 3 and |dy| < 3)
#                       and you are moved to the paired map AT THE SAME x,y, facing the same way. The two
#                       maps are twin layouts; that is why the pair table is the whole of the geography.
#   Tesseract_Spot_2 -- "bring it here". Stand within THREE tiles but NOT on it ("Don't stand directly on
#                       the rift!") and it flips its own self-switch D, which turns its page over and
#                       makes something appear where it stands.
#
# For the ROUTER only the first kind is a crossing, and it is shaped exactly like Dive: two maps joined at
# the same coordinates, no door to walk through. So it is registered as a WarpNet link source and every
# tile in the 5x5 box around a spot becomes a crossing to the twin map -- the closure, the regions and the
# hop counting need to know nothing about it.
#
# For the SCANNER both kinds matter: they have no sprite, no transfer command and no action trigger, so
# every category test in the locator said "not a thing" and she could stand beside one and never be told.
#
# The pair table and the two-tile radius are copied from the game's own source, not guessed.
module PokeAccess
  module InsurgenceTesseract
    # map => the map the Tesseract shifts you to, from useTesseract's own tesseractMaps hash.
    PAIRS = {
      339 => 357, 357 => 339,
      360 => 361, 361 => 360,
      282 => 369, 369 => 282,
      393 => 396, 396 => 393,
      505 => 508, 510 => 508, 511 => 508, 512 => 508,
      513 => 508, 514 => 508, 515 => 508, 516 => 508,
      549 => 551, 551 => 549,
      452 => 563, 563 => 452,
      443 => 585, 585 => 443,
      363 => 643, 643 => 363,
      662 => 663, 663 => 662,
      122 => 764, 764 => 122
    }


    # Every Tesseract spot in the game: map => [[x, y, kind], ...] with kind 1 = "go there" shift point,
    # 2 = "bring it here" rift. Lifted from the map archive (63 spots across 55 maps), not hand-listed --
    # the scanner has to be able to name one on a floor she is not standing on, and reading 55 maps at run
    # time to find that out would cost more than it is worth.
    SPOTS = {
      82 => [[44,15,2], [45,15,2], [58,15,2]],
      122 => [[25,44,1]],
      123 => [[34,59,2]],
      126 => [[15,38,2]],
      148 => [[39,8,2]],
      151 => [[54,5,2]],
      170 => [[19,26,2]],
      172 => [[48,39,2]],
      176 => [[17,82,2]],
      180 => [[73,34,2]],
      240 => [[7,42,2]],
      243 => [[33,28,2], [51,28,2]],
      268 => [[27,27,2]],
      279 => [[37,13,2]],
      282 => [[43,60,1]],
      286 => [[30,66,2]],
      287 => [[57,41,2]],
      339 => [[17,32,1]],
      357 => [[17,32,1]],
      358 => [[15,32,1]],
      359 => [[17,32,1]],
      360 => [[21,51,1], [25,62,2]],
      361 => [[17,32,1], [21,51,1], [30,42,2]],
      363 => [[35,42,1]],
      365 => [[12,19,2], [21,17,2]],
      366 => [[13,22,2]],
      368 => [[11,16,2]],
      369 => [[43,60,1]],
      374 => [[24,15,2]],
      393 => [[58,16,2], [72,32,1]],
      396 => [[72,32,1]],
      443 => [[33,49,1]],
      452 => [[49,59,1]],
      456 => [[37,53,2]],
      505 => [[17,42,1]],
      508 => [[17,42,1]],
      510 => [[17,42,1]],
      511 => [[17,42,1]],
      512 => [[17,42,1]],
      513 => [[17,42,1]],
      514 => [[17,42,1]],
      515 => [[17,42,1]],
      516 => [[17,42,1]],
      517 => [[31,33,2]],
      534 => [[30,16,2]],
      549 => [[50,16,1]],
      551 => [[50,16,1]],
      563 => [[49,59,1]],
      585 => [[33,49,1]],
      643 => [[35,42,1]],
      662 => [[61,79,1]],
      663 => [[61,79,1]],
      735 => [[14,40,2]],
      764 => [[25,44,1]],
      829 => [[9,13,2]]
    }

    # How far from a spot the game accepts the ability: |dx| < 3 and |dy| < 3, i.e. two tiles.
    REACH = 2

    # The ability is hers when this slot of the Mew-ability list is set -- the same test the game's own
    # ability menu uses (102_PokemonItemEffects.rb:588).
    ABILITY_VAR = 42
    ABILITY_SLOT = 4

    # Map 363's shift is held shut until this switch (useTesseract's one special case).
    HIDEAWAY_MAP = 363
    HIDEAWAY_SWITCH = 556

    def self.unlocked?
      v = ($game_variables && $game_variables[ABILITY_VAR])
      v.is_a?(Array) && v[ABILITY_SLOT] == true
    rescue StandardError
      false
    end

    # :shift for a "go there" spot, :rift for a "bring it here" one, nil for anything else.
    def self.spot_kind(ev)
      n = (ev.name.to_s rescue "")
      return :shift if n.include?("Tesseract_Spot_1")
      return :rift  if n.include?("Tesseract_Spot_2")
      nil
    rescue StandardError
      nil
    end

    def self.spot?(ev); !spot_kind(ev).nil?; end

    # Can the shift actually be taken from this map right now?
    def self.shift_open?(mid)
      return false unless unlocked?
      return false unless PAIRS.has_key?(mid)
      return false if mid == HIDEAWAY_MAP && !($game_switches[HIDEAWAY_SWITCH] rescue false)
      true
    rescue StandardError
      false
    end

    # WarpNet rows for a map: every tile within reach of a "go there" spot crosses to the twin map at the
    # SAME coordinates. Same shape as a dive link, with the crossing named so the guide can say what it is.
    # Only the live map is answered: a shift is only ever offered as the leg she is about to walk.
    def self.links(mid)
      return [] unless shift_open?(mid)
      return [] unless mid == ($game_map.map_id rescue nil)
      dest = PAIRS[mid]
      out = []
      ($game_map.events.each_value do |ev|
        next unless spot_kind(ev) == :shift
        (-REACH..REACH).each do |dx|
          (-REACH..REACH).each do |dy|
            x = ev.x + dx; y = ev.y + dy
            next unless ($game_map.valid?(x, y) rescue false)
            out.push([x, y, dest, x, y, nil, :tesseract])
          end
        end
      end rescue nil)
      out
    rescue StandardError
      []
    end


    # A Tesseract spot on ANOTHER map, so the scanner can offer one she cannot see yet.
    RiftTarget = Class.new(PokeAccess::Locator::RemoteTarget)

    # Spots worth listing: every one on this map, plus every one the router can actually plan a leg to.
    #
    # This is the whole point of the exercise. Whirl Islands is four maps; its rifts are on the fourth.
    # Standing at the entrance there was nothing to select and nothing to walk toward, so finding one was
    # a matter of exhausting the interior by hand. Ranked exactly as Story ranks its steps: what is on
    # this map first, then what is fewest doors away, then what cannot be routed to at all.
    # The maps the router can currently plan a leg to, asked ONCE from the closure it already builds.
    #
    # This is the difference between a working scanner and a thirty-second freeze on every doorway. The
    # first version asked WarpNet.first_leg about all 62 remote spots, and first_leg grows a cross-map
    # closure with a budget measured in SECONDS -- so every target rebuild, which happens on every map
    # change, paid that sixty-two times over. The closure knows which maps it reached; reading it once and
    # filtering on that asks the expensive question a single time.
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

    # Memoised on where she is standing: the answer only changes when she moves or the map does, and this
    # is asked every time the category list is built.
    def self.targets
      return [] unless unlocked?
      here = ($game_map.map_id rescue nil)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      key = [here, px, py]
      return @cached if @cache_key == key && @cached
      reach = nil
      ranked = []
      SPOTS.each do |mid, list|
        if mid != here
          reach = reachable_maps if reach.nil?
          next unless reach[mid]
        end
        list.each do |x, y, kind|
          label = PokeAccess::I18n.t(kind == 1 ? :tess_shift : :tess_rift)
          if mid == here
            t = PokeAccess::Locator::SurfaceTarget.new(x, y, label, :rifts)
            ranked.push([0, 0, (x - px).abs + (y - py).abs, t])
          else
            leg = (PokeAccess::WarpNet.first_leg(mid, x, y) rescue nil)
            # A spot the router cannot plan a leg to is not offered at all. All 63 of them listed made a
            # list she had to cycle through to find the one in the room she is standing in; the ones that
            # matter are the ones here and the ones there is a way to.
            next unless leg
            ranked.push([1, leg[1].to_i, 0, RiftTarget.new(mid, x, y, label)])
          end
        end
      end
      @cache_key = key
      @cached = ranked.sort_by { |a, b, c, _t| [a, b, c] }.map { |r| r[3] }
    rescue StandardError
      []
    end

    # Only offer the category when there is something listable: a spot here, or one the router can reach.
    # Whether the category is worth offering. Answers from the map's own spot list when it can, because
    # this runs every time the category list is built and must never be the thing that does the searching.
    def self.any_targets?
      return false unless unlocked?
      here = ($game_map.map_id rescue nil)
      mine = SPOTS[here]
      return true if mine && !mine.empty?
      !targets.empty?
    rescue StandardError
      false
    end

    # Where a remote spot is, as spoken -- the map's name only once she has been there, same rule Story uses
    # so an unvisited place is never named at her.
    def self.place_phrase(t)
      return nil unless t.is_a?(RiftTarget)
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

    # What the scanner calls one, or nil when it is not a spot.
    def self.label(ev)
      case spot_kind(ev)
      when :shift then PokeAccess::I18n.t(:tess_shift)
      when :rift  then PokeAccess::I18n.t(:tess_rift)
      end
    rescue StandardError
      nil
    end
  end
end

PokeAccess::Locator.register_event_reader { |ev| PokeAccess::InsurgenceTesseract.label(ev) }
PokeAccess::Locator.register_mechanic_exit { |ev| PokeAccess::InsurgenceTesseract.spot?(ev) }
PokeAccess::WarpNet.register_link_source { |mid| PokeAccess::InsurgenceTesseract.links(mid) }
# A Tesseract spot is USED where it stands, like a dive spot -- so the guide should end the route ON the
# tile and say so, not walk her beside it and call the journey finished.
PokeAccess::Locator.register_crossing_kind do |t|
  :tesseract if (t.respond_to?(:name) && t.name.to_s =~ /Tesseract/i) ||
                (t.respond_to?(:key) && t.key == :rifts)
end

PokeAccess::Locator.register_category(:rifts,
  :label     => :tcat_rifts,
  :available => lambda { PokeAccess::InsurgenceTesseract.any_targets? },
  :targets   => lambda { PokeAccess::InsurgenceTesseract.targets },
  :place     => lambda { |t| PokeAccess::InsurgenceTesseract.place_phrase(t) })
