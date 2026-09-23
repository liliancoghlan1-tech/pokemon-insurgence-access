module PokeAccess
  # Diving, the Essentials way: a surface map names the map beneath it in its metadata (MetadataDiveMap /
  # MapMetadata#dive_map_id), and the two share coordinates.
  #   * DOWN: surfing on a Deep Water tile of a map that has a dive map, press the action button.
  #   * UP: diving, press it where the SURFACE map has Deep Water at the same x,y (unless the game lets you
  #     surface anywhere).
  # None of that is visible to a player who cannot see the dark patches in the sea, or the light coming down
  # through them from underneath, so this names both as places: "dive spot" and "place to surface".
  module Dive
    DEEP_WATER = 5

    @surface_of = nil

    # The map under mid, or nil.
    def self.dive_map(mid)
      idx = defined?(MetadataDiveMap) ? MetadataDiveMap : 8
      v = PokeAccess::MapMeta.field(mid, :dive_map_id, idx)
      v.is_a?(Integer) && v > 0 ? v : nil
    rescue StandardError
      nil
    end

    # The map above mid (the one whose dive map it is), or nil. The metadata only points DOWN, so the table
    # is inverted once -- exactly the search Kernel.pbSurfacing runs on every press.
    def self.surface_map(mid)
      surface_index[mid]
    end

    def self.surface_index
      return @surface_of if @surface_of
      out = {}
      if defined?(GameData) && defined?(GameData::MapMetadata) && GameData::MapMetadata.respond_to?(:each)
        GameData::MapMetadata.each do |m|
          d = (m.dive_map_id rescue nil)
          out[d] ||= m.id if d.is_a?(Integer) && d > 0
        end
      elsif defined?(pbLoadMetadata)
        idx = defined?(MetadataDiveMap) ? MetadataDiveMap : 8
        meta = (pbLoadMetadata rescue nil) || []
        meta.each_with_index do |row, i|
          next if i == 0 || !row.is_a?(Array)
          d = row[idx]
          out[d] ||= i if d.is_a?(Integer) && d > 0
        end
      end
      @surface_of = out
    rescue StandardError
      @surface_of = {}
    end

    def self.diving?
      ($PokemonGlobal && $PokemonGlobal.diving) ? true : false
    rescue StandardError
      false
    end

    def self.surface_anywhere?
      return (Settings::DIVING_SURFACE_ANYWHERE ? true : false) if defined?(Settings) && Settings.const_defined?(:DIVING_SURFACE_ANYWHERE)
      defined?(DIVINGSURFACEANYWHERE) && DIVINGSURFACEANYWHERE ? true : false
    rescue StandardError
      false
    end

    # A tile she could dive from on the current map: deep water, on a map with something under it.
    def self.dive_spot?(x, y)
      return false if dive_map(($game_map.map_id rescue 0)).nil?
      PokeAccess::Terrain.kind(x, y) == :deep_water
    rescue StandardError
      false
    end

    # A tile she could surface from on the current (underwater) map.
    def self.surface_spot?(x, y)
      up = surface_map(($game_map.map_id rescue 0))
      return false if up.nil?
      return true if surface_anywhere?
      rec = PokeAccess::ForeignMap.info(up)
      return false if rec.nil?
      PokeAccess::Terrain.kind_of(PokeAccess::ForeignMap.terrain_at(rec, x, y)) == :deep_water
    rescue StandardError
      false
    end

    # Whether diving is worth offering at all: a definite "cannot" hides it, "cannot tell" does not.
    def self.offer_dive?
      return false if dive_map(($game_map.map_id rescue 0)).nil?
      PokeAccess::Gates.can_dive? != false
    rescue StandardError
      false
    end

    def self.offer_surface?
      diving? && !surface_map(($game_map.map_id rescue 0)).nil?
    rescue StandardError
      false
    end

    # How many separate patches of one map are offered to the cross-map router. Measured across this game:
    # the most any map has is six, so the cap costs nothing real and bounds a sea of 237 tiles to one entry.
    LINKS_MAX = 8

    # Every way this map joins the layer above or below it, as [x, y, destination map, :dive or :surface].
    #
    # ONE TILE PER PATCH. A door is a tile; a dive is a whole stretch of deep water, and handing the router
    # every tile of Maelstrom 9's 237 would drown a search that is allowed eighty nodes in total. Tiles that
    # touch are the same crossing, so each connected patch contributes one representative and the answers are
    # identical -- "go to the deep water and press confirm" does not depend on which tile of it she picks.
    def self.links(mid)
      @links ||= {}
      hit = @links[mid]
      return hit if hit
      @links[mid] = compute_links(mid)
    rescue StandardError
      []
    end

    def self.forget_links; @links = nil; end

    def self.compute_links(mid)
      out = []
      down = dive_map(mid)
      up = surface_map(mid)
      out += patches(mid) { |x, y| deep_at?(mid, x, y) }.map { |x, y| [x, y, down, :dive] } if down && PokeAccess::Gates.can_dive? != false
      out += patches(mid) { |x, y| surfaces_at?(mid, up, x, y) }.map { |x, y| [x, y, up, :surface] } if up
      out
    rescue StandardError
      []
    end

    # Deep water on a map, asked of the engine for the map she is standing on and of the model anywhere else.
    def self.deep_at?(mid, x, y)
      if mid == ($game_map.map_id rescue nil)
        PokeAccess::Terrain.kind(x, y) == :deep_water
      else
        rec = PokeAccess::ForeignMap.info(mid)
        rec && PokeAccess::Terrain.kind_of(PokeAccess::ForeignMap.terrain_at(rec, x, y)) == :deep_water
      end
    rescue StandardError
      false
    end

    # A tile of an underwater map she could surface from: the map ABOVE has deep water at the same spot.
    def self.surfaces_at?(mid, up, x, y)
      return false if up.nil?
      return true if surface_anywhere?
      deep_at?(up, x, y)
    rescue StandardError
      false
    end

    # One representative tile per connected patch of tiles the block accepts, at most LINKS_MAX of them.
    def self.patches(mid)
      w, h = dims(mid)
      return [] if w.nil?
      hits = {}
      h.times { |y| w.times { |x| hits[x * 1000 + y] = true if yield(x, y) } }
      out = []
      until hits.empty?
        k = hits.keys[0]
        queue = [k]
        hits.delete(k)
        out.push([k / 1000, k % 1000])
        return out if out.length >= LINKS_MAX
        until queue.empty?
          c = queue.pop
          cx = c / 1000; cy = c % 1000
          [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |a, b|
            n = (cx + a) * 1000 + (cy + b)
            next unless hits[n]
            hits.delete(n)
            queue.push(n)
          end
        end
      end
      out
    rescue StandardError
      []
    end

    def self.dims(mid)
      if mid == ($game_map.map_id rescue nil)
        [($game_map.width rescue nil), ($game_map.height rescue nil)]
      else
        rec = PokeAccess::ForeignMap.info(mid)
        rec ? [rec[:w], rec[:h]] : [nil, nil]
      end
    rescue StandardError
      [nil, nil]
    end

    # The map a dive or surface from this map lands on, for a target of that kind, or nil.
    def self.lands_on(key, from_map)
      case key
      when :surf_dive then dive_map(from_map)
      when :surf_surface then surface_map(from_map)
      end
    end
  end
end

# The patches are read off map data that a game may change under us (a drained lake, a new channel), so they
# go when everything else keyed to the world does.
PokeAccess::Caches.register(:dive_links) { PokeAccess::Dive.forget_links }
