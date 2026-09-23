module PokeAccess
  # Dual-engine terrain queries: gen-6 returns an Integer tag (with PBTerrain.isX?), modern a
  # GameData::TerrainTag object (with boolean flags). This normalises both, falling back to the tag
  # number (identical across versions) when neither shape answers.
  module Terrain
    # Standard Essentials terrain-tag id_number => stable kind symbol (same numbering gen-6/modern).
    KIND = { 1 => :ledge, 2 => :grass, 3 => :sand, 4 => :rock, 5 => :deep_water, 6 => :still_water,
             7 => :water, 8 => :waterfall, 9 => :waterfall_crest, 10 => :tall_grass,
             11 => :underwater_grass, 12 => :ice, 13 => :neutral, 14 => :soot_grass,
             15 => :bridge, 16 => :puddle }
    # kind => localization key for surface awareness (cues and navigation targets).
    LABEL = { :tall_grass => :surf_tallgrass, :grass => :surf_grass, :sand => :surf_sand,
              :rock => :surf_rock, :water => :surf_water, :still_water => :surf_water,
              :deep_water => :surf_deepwater, :waterfall => :surf_waterfall,
              :waterfall_crest => :surf_waterfall, :ice => :surf_ice, :bridge => :surf_bridge,
              :puddle => :surf_puddle, :soot_grass => :surf_sootgrass }
    GRASS = [:grass, :tall_grass, :soot_grass]
    # Two different questions, and lumping them together is what made a fishing pond look like a road.
    #
    # WATER_NUMBERS: tiles you cannot WALK on. Still water counts -- you cannot stroll across a pond.
    # SURF_NUMBERS:  tiles you can SURF on. Still water does NOT count: Essentials' own pbIsSurfableTag?
    #                is pbIsWaterTag?, which is deep water, water and the two waterfall tags. Standing
    #                water is there to fish in, and no amount of Surf will cross it.
    WATER_NUMBERS = [5, 6, 7, 8, 9]
    SURF_NUMBERS = [5, 7, 8, 9]

    # GameData id symbol => kind, tried FIRST on tag objects: games can renumber the standard tags, so
    # the NAME is the identity and the number only the fallback. Integers slip through respond_to?(:id)
    # on 1.8.7 (old object_id alias); the IDS miss routes them to the numeric table.
    IDS = { :Ledge => :ledge, :Grass => :grass, :Sand => :sand, :Rock => :rock,
            :DeepWater => :deep_water, :StillWater => :still_water, :Water => :water,
            :Waterfall => :waterfall, :WaterfallCrest => :waterfall_crest,
            :TallGrass => :tall_grass, :UnderwaterGrass => :underwater_grass, :Ice => :ice,
            :Neutral => :neutral, :SootGrass => :soot_grass, :Bridge => :bridge, :Puddle => :puddle }

    # The stable kind of a raw terrain value: the tag object's id name when it maps, else the number. The
    # Integer guard matters under 1.8.7, whose Object#id exists and warns on every call.
    def self.kind_of(t)
      return nil if t.nil?
      if !t.is_a?(Integer) && t.respond_to?(:id)
        k = IDS[(t.id rescue nil)]
        return k if k
      end
      KIND[number(t)]
    end

    # The engine's raw terrain at (x,y) (Integer or GameData::TerrainTag), or nil. count_bridge reports
    # bridge tiles even when not standing on the bridge; uses the cross-map lookup for seamless edges.
    def self.raw(x, y, count_bridge = false)
      return nil unless $game_map
      if count_bridge
        r = ($game_map.terrain_tag(x, y, true) rescue :err)
        return r unless r == :err
      end
      ($game_map.terrain_tag(x, y) rescue nil)
    end

    # The id_number of a raw terrain value (object in modern, Integer in gen-6).
    def self.number(t)
      return nil if t.nil?
      return (t.id_number rescue nil) if t.respond_to?(:id_number)
      t.is_a?(Integer) ? t : nil
    end

    # The stable kind symbol at (x,y) (e.g. :water, :bridge), or nil for none/custom tags.
    def self.kind(x, y, count_bridge = false)
      kind_of(raw(x, y, count_bridge))
    end

    # The surface localization key at (x,y), or nil; counts bridges and falls back to water for any
    # surfable custom tag with no explicit label.
    def self.label(x, y)
      t = raw(x, y, true)
      LABEL[kind_of(t)] || (surfable?(t) ? :surf_water : nil)
    end

    # The three-step dual-engine probe every tag test shares: the modern object's boolean flag, then the
    # gen-6 PBTerrain helper, then the block over the NORMALISED tag number. One ladder instead of four
    # near-identical copies, and the number fallback is uniform (the old surfable? compared the raw value).
    def self.probe(t, flag, pb_name)
      return false if t.nil?
      return (t.send(flag) ? true : false) if t.respond_to?(flag)
      return PBTerrain.send(pb_name, t) if defined?(PBTerrain) && PBTerrain.respond_to?(pb_name)
      yield(number(t))
    rescue StandardError
      false
    end

    # The two tags a wall of falling water is made of.
    WATERFALL_KINDS = [:waterfall, :waterfall_crest]

    def self.waterfall?(t)
      WATERFALL_KINDS.include?(kind_of(t))
    rescue StandardError
      false
    end

    # May she cross falling water at all? Memoised PER MAP, because Gates.can_waterfall? walks the whole
    # party and this is asked once per water tile of a flood -- thousands of times. The cost of that cadence
    # is that teaching a Pokemon Waterfall takes effect at the next doorway rather than instantly, which is
    # the same deal the rest of the surf caches already make.
    #
    # nil means "could not read the party", and nil is not no: an unreadable party must not turn every
    # waterfall in the game into a wall.
    def self.waterfall_open?
      mid = ($game_map.map_id rescue nil)
      if @wf_map != mid
        @wf_map = mid
        @wf = (PokeAccess::Gates.can_waterfall? rescue nil)
      end
      @wf != false
    rescue StandardError
      true
    end

    # True if a raw terrain value is surfable water.
    #
    # A waterfall is surfable to the ENGINE -- pbIsSurfableTag? counts both waterfall tags -- but it is not
    # crossable to somebody who cannot use Waterfall, in either direction: the game only ever moves you
    # through one from its own pbWaterfall, which wants the badge and the move (or Insurgence's Magic
    # Carpet). Left as plain water, the amphibious flood climbs it and the router hands her a route up a
    # cliff of falling water.
    def self.surfable?(t)
      return false if t.nil?
      return false if waterfall?(t) && !waterfall_open?
      return (t.can_surf ? true : false) if t.respond_to?(:can_surf)
      n = number(t)
      # The GAME's own answer wins. Essentials keeps this as a bare top-level function, not a PBTerrain
      # method, so respond_to? has to look for a private one -- and without it the mod fell through to its
      # own number list, which used to call standing water surfable and routed her across a pond she can
      # only fish in.
      if respond_to?(:pbIsSurfableTag?, true)
        r = (pbIsSurfableTag?(n) rescue nil)
        return (r ? true : false) unless r.nil?
      end
      return (PBTerrain.isSurfable?(n) ? true : false) if defined?(PBTerrain) && PBTerrain.respond_to?(:isSurfable?)
      SURF_NUMBERS.include?(n)
    rescue StandardError
      false
    end

    # True if a raw terrain value is water of ANY kind, i.e. something you cannot walk on. Asked where the
    # question is "may I put a foot here", not "may I surf here".
    def self.water?(t)
      return false if t.nil?
      n = number(t)
      if respond_to?(:pbIsPassableWaterTag?, true)
        r = (pbIsPassableWaterTag?(n) rescue nil)
        return true if r
      end
      WATER_NUMBERS.include?(n)
    rescue StandardError
      false
    end

    # True if a tile is water of any kind.
    def self.water_at?(x, y); water?(raw(x, y)); end

    # True if a raw terrain value is a one-way ledge (tag 1).
    def self.ledge?(t); probe(t, :ledge, :isLedge?) { |n| n == 1 }; end

    # True if a raw terrain value is ice (forced slide).
    def self.ice?(t); probe(t, :ice, :isIce?) { |n| n == 12 }; end

    # True if a raw terrain value is a bridge tile.
    def self.bridge?(t); probe(t, :bridge, :isBridge?) { |n| n == 15 }; end

    # True if a raw terrain value is walkable grass (plain, tall or soot).
    def self.grass?(t)
      GRASS.include?(kind_of(t))
    end

    # The game's own climbable-rock terrain number, or nil where it has none. Asked of the GAME
    # (PBTerrain::RockClimb) rather than assumed: standard Essentials has no Rock Climb, and in those games
    # tag 4 is ordinary rock that nothing climbs. Insurgence defines it, as 4, and walls whole routes off
    # behind it.
    def self.climb_number
      return @climb_number if defined?(@climb_number)
      @climb_number = (defined?(PBTerrain) && PBTerrain.const_defined?(:RockClimb)) ? PBTerrain.const_get(:RockClimb) : nil
    rescue StandardError
      @climb_number = nil
    end

    def self.climb_supported?; !climb_number.nil?; end

    # Climbable rock at (x,y).
    def self.climb_at?(x, y)
      n = climb_number
      return false if n.nil?
      number(raw(x, y)) == n
    rescue StandardError
      false
    end

    # Surfable water directly at (x,y).
    def self.surfable_at?(x, y); surfable?(raw(x, y)); end
    # A one-way ledge at (x,y).
    def self.ledge_at?(x, y); ledge?(raw(x, y)); end
    # An ice tile (forced slide) at (x,y).
    def self.ice_at?(x, y); ice?(raw(x, y)); end
  end
end
