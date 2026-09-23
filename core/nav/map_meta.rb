module PokeAccess
  # Essentials MAP METADATA, read the same way on both engine eras. Three facts about a map the mod needs
  # in order to say what a door leads to: is it indoors, does it hold a healing spot, and where does it sit
  # on the region map.
  #
  # Why it matters: Essentials convention names a town's house/shop interiors after the TOWN, so a whole
  # street of doors resolves to one name and the locator announced every one of them -- and the link to the
  # next section of the same town -- identically as "exit to <town>". In Insurgence alone that is 911
  # transfers: 704 building doors and 207 same-place section links. The destination's NAME cannot tell them
  # apart, and its metadata can.
  module MapMeta
    # gen-6 metadata indices (092_PokemonMap.rb) and the GameData-era accessors they became.
    OUTDOOR = 1
    HEALING = 5
    POSITION = 7

    # Static per map for the life of the process, so this cache is deliberately NOT registered with Caches:
    # nothing a player does edits metadata, and a map change re-reading it would be pure waste.
    @cache = {}

    # True when this engine exposes map metadata at all. The distinction matters: with the API present, "no
    # outdoor flag" is the engine's own way of spelling INDOORS (the games test `if !pbGetMetadata(id,
    # MetadataOutdoor)` exactly like that), while with the API absent the answer is genuinely unknown and
    # the mod must not invent one.
    def self.available?
      return true if defined?(GameData) && defined?(GameData::MapMetadata)
      defined?(pbGetMetadata) ? true : false
    rescue StandardError
      false
    end

    # One metadata field, memoised. modern is the GameData accessor, gen6 the numeric index.
    def self.field(mapid, modern, gen6)
      key = [mapid, gen6]
      hit = @cache[key]
      return hit[0] if hit
      v = read(mapid, modern, gen6)
      @cache[key] = [v]
      v
    rescue StandardError
      nil
    end

    # The uncached read, GameData era first.
    def self.read(mapid, modern, gen6)
      if defined?(GameData) && defined?(GameData::MapMetadata) &&
         GameData::MapMetadata.respond_to?(:try_get)
        m = (GameData::MapMetadata.try_get(mapid) rescue nil)
        return nil if m.nil?
        return (m.respond_to?(modern) ? m.send(modern) : nil)
      end
      return nil unless defined?(pbGetMetadata)
      pbGetMetadata(mapid, gen6)
    rescue StandardError
      nil
    end

    # True if a map is an interior, false if it is outdoors, nil when this engine cannot say.
    def self.indoor?(mapid)
      return nil unless available?
      !field(mapid, :outdoor_map, OUTDOOR)
    rescue StandardError
      nil
    end

    # True if a map declares a healing spot, i.e. it is a Pokemon Centre (or whatever a game calls its
    # equivalent). Free to ask, and it is the one interior worth naming when its map name will not.
    def self.healing?(mapid)
      f = field(mapid, :teleport_destination, HEALING)
      !f.nil? && f != false
    rescue StandardError
      false
    end

    # A map's [region, x, y] square on the region map, or nil.
    def self.position(mapid)
      p = field(mapid, :town_map_position, POSITION)
      (p.is_a?(Array) && p.length >= 3) ? p : nil
    rescue StandardError
      nil
    end

    # Which way a map lies from another, as a dir_* key, using the region map as the authority on where the
    # parts of a place sit relative to each other. nil when either has no square, they are in different
    # regions, or they share a square -- which is the common case for the rooms of one dungeon, and is why
    # the caller must have a wording that works without a direction.
    def self.side_of(from_id, to_id)
      a = position(from_id)
      b = position(to_id)
      return nil if a.nil? || b.nil? || a[0] != b[0]
      dx = b[1] - a[1]
      dy = b[2] - a[2]
      return nil if dx == 0 && dy == 0
      ns = dy > 0 ? "s" : (dy < 0 ? "n" : "")
      ew = dx > 0 ? "e" : (dx < 0 ? "o" : "")
      "dir_#{ns}#{ew}".to_sym
    rescue StandardError
      nil
    end
  end
end
