module PokeAccess
  # Walkability for a map the player is NOT standing on.
  #
  # The engine can only answer `passable?` for `$game_map`, which is why every router in the mod has so far
  # stopped at the edge of the current map. To route THROUGH a door -- to know that the tree you are about to
  # crawl into eventually reaches the gym leader -- something has to be able to read the map on the other
  # side. That is this: RPG Maker XP's own passability rule, re-implemented over map data loaded from disk.
  #
  # It is a MODEL, and the running engine is the authority. So it is used only for maps that are not loaded;
  # the current map always goes through the engine (Pathfinder.passable_at?), and `agrees_with_engine?`
  # exists to check the model against the engine on the current map before anything trusts it elsewhere.
  module ForeignMap
    # Maps kept in memory at once. A map is a few hundred KB of Table; the router visits a handful.
    CACHE_MAX = 14
    DIRS = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }

    @cache = {}
    @order = []

    # Whether the last floods were computed while surfing. Water flips every answer this module gives, so
    # a cache built on foot must not be handed to a search made afloat.
    def self.surf_state
      ($PokemonGlobal && $PokemonGlobal.surfing) ? true : false
    rescue StandardError
      false
    end

    # Drops the loaded maps and floods -- but only when the world has changed. Every page choice and so every
    # blocking event depends on switches, variables and self switches; while none of those have changed, a map
    # read a minute ago is the same map. Dropping it on EVERY map change made each arrival in Whirl Islands (rooms
    # on three maps, a door every few steps) re-read and re-flood them all: five seconds on the first question.
    def self.reset
      sig = world_signature
      return if sig && sig == @sig && @cache
      @sig = sig
      @cache = {}
      @order = []
      @floods = {}
    end

    def self.world_signature
      sw = ($game_switches.instance_variable_get(:@data) rescue nil)
      vr = ($game_variables.instance_variable_get(:@data) rescue nil)
      ss = ($game_self_switches.instance_variable_get(:@data) rescue nil)
      return nil if sw.nil?
      [sw.hash, (vr ? vr.select { |v| v.is_a?(Integer) }.hash : 0), (ss ? ss.select { |_k, v| v }.length : 0)]
    rescue StandardError
      nil
    end

    FLOODS_MAX = 300

    # amphi_flood, memoised with the maps (same lifetime, same signature).
    def self.amphi_flood_cached(mid, sx, sy)
      @floods ||= {}
      k = [mid, sx, sy]
      return @floods[k] if @floods.has_key?(k)
      @floods.clear if @floods.length > FLOODS_MAX
      @floods[k] = amphi_flood(mid, sx, sy)
    end

    # The loaded shape of a map: its data Table, its tileset's passage/priority tables, the tiles its events
    # block, and every transfer it offers. nil when the map cannot be read.
    def self.info(mid)
      hit = @cache[mid]
      return hit if hit
      m = (load_data(sprintf("Data/Map%03d.rxdata", mid)) rescue nil)
      return nil if m.nil?
      ts = ($data_tilesets[m.tileset_id] rescue nil)
      return nil if ts.nil?
      rec = { :w => m.width, :h => m.height, :data => m.data,
              :passages => ts.passages, :priorities => ts.priorities,
              :terrain => ts.terrain_tags,
              :blocked => {}, :warps => [], :jumps => {}, :ramps => {} }
      (m.events || {}).each_value do |ev|
        pg = active_page(mid, ev)
        if pg
          g = (pg.graphic.character_name.to_s rescue "")
          rec[:blocked][key(ev.x, ev.y)] = true if !g.empty? && !pg.through
        end
        h = ramp_height(ev, pg)
        rec[:ramps][key(ev.x, ev.y)] = h unless h.nil?
        d = first_transfer(ev)
        if d
          face = (pg ? PokeAccess::Pathfinder.facing_guard(pg.list || []) : nil)
          rec[:warps].push([ev.x, ev.y, d[0], d[1], d[2], face])
          trig = (pg.trigger rescue nil) if pg
          (rec[:exit_tiles] ||= {})[key(ev.x, ev.y)] = (face || true) if pg && (trig == 1 || trig == 2) && d[0] != mid
        else
          j = jumps_of(ev)
          rec[:jumps][key(ev.x, ev.y)] = j unless j.empty?
        end
      end
      @cache[mid] = rec
      @order.push(mid)
      if @order.length > CACHE_MAX
        drop = @order.shift
        @cache.delete(drop)
      end
      rec
    rescue StandardError
      nil
    end

    # The bridge height a walk-onto event sets (Pathfinder.ramp_height's rule, on loaded data), or nil.
    def self.ramp_height(ev, pg)
      return nil if pg.nil?
      return nil unless [1, 2].include?((pg.trigger rescue 0))
      return nil unless (pg.graphic.character_name.to_s rescue "").empty?
      (pg.list || []).each do |c|
        code = (c.code rescue 0)
        return nil if [111, 101, 102].include?(code)
        next unless code == 355 || code == 655
        str = (c.parameters[0].to_s rescue "")
        return 0 if str.include?("pbBridgeOff")
        next unless str.include?("pbBridgeOn")
        m = str[/pbBridgeOn\s*\(?\s*(\d+)/, 1]
        return m ? m.to_i : 2
      end
      nil
    rescue StandardError
      nil
    end

    # The page an event would be showing right now, chosen the way Game_Event#refresh chooses it: the LAST page
    # whose conditions the live switches, variables and self switches meet, or nil when none are (the event
    # is not there at all). Page 0 was the old assumption, and it is the page a story has not reached yet: in
    # Miara's museum a Crawdaunt parks on the pier door on page 0 and leaves once "Audrey_Miara_Done" is set.
    # Read as page 0, the only way to the sea stayed shut for a player who had long since opened it.
    def self.active_page(mid, ev)
      pages = (ev.pages || [])
      (pages.length - 1).downto(0) do |i|
        pg = pages[i]
        return pg if page_conditions_met?(mid, ev, pg)
      end
      nil
    rescue StandardError
      (ev.pages[0] rescue nil)
    end

    def self.page_conditions_met?(mid, ev, pg)
      c = pg.condition
      return false if c.switch1_valid && !($game_switches[c.switch1_id] rescue false)
      return false if c.switch2_valid && !($game_switches[c.switch2_id] rescue false)
      return false if c.variable_valid && ((($game_variables[c.variable_id] rescue 0).to_i rescue 0) < c.variable_value)
      if c.self_switch_valid
        return false unless ($game_self_switches[[mid, ev.id, c.self_switch_ch]] rescue false)
      end
      true
    rescue StandardError
      true
    end

    # The first Transfer Player command on any page of an event, as [map, x, y], or nil. Only a LITERAL
    # transfer counts: a variable-driven one (the editor's "designation with variables") cannot be resolved
    # without running the game, and a router that guessed at one would send her somewhere it invented.
    def self.first_transfer(ev)
      (ev.pages || []).each do |pg|
        (pg.list || []).each do |c|
          next unless (c.code rescue 0) == 201
          p = c.parameters
          next unless p.is_a?(Array) && p.length >= 4 && p[0] == 0
          return [p[1], p[2], p[3]]
        end
      end
      nil
    rescue StandardError
      nil
    end

    # Every gap this event jumps the player across, as { facing => [dx, dy] }, or {} for anything else.
    #
    # This is how the Black Market is BUILT: its floor is cut into ledges joined by two-tile gaps, and a
    # sprite-less touch event on each lip jumps the player over. Modelled as nothing, the market reads as
    # a handful of sealed islands -- which is exactly "nothing is reachable" -- and its shops, which sit
    # one gap from where she lands, look unreachable while being three steps away.
    #
    # Read by the very same parser as Pathfinder.forced_moves (facing_branches), else-branches included.
    def self.jumps_of(ev)
      trig = (ev.pages[0].trigger rescue nil)
      return {} unless trig == 1 || trig == 2
      out = {}
      (ev.pages || []).each { |pg| PokeAccess::Pathfinder.facing_branches(pg.list || [], out) }
      out
    rescue StandardError
      {}
    end

    def self.key(x, y); x * 1000 + y; end

    # RMXP Game_Map#passable?: the top-most tile whose priority is 0 decides, and any tile whose passage
    # bits block this direction (or block every direction) stops the search at once.
    # level: nil models no bridge at all (the old behaviour, for callers that do not carry one); 0 is the ground
    # (bridge tiles are skipped, as Game_Map#passable? skips them with the bridge down); above 0 the bridge
    # tile's own passage decides, as it does in the engine with the bridge up.
    #
    # Memoised per loaded map: the floods ask the same tile the same question from every neighbour, and a
    # region of a thousand tiles was spending most of its time re-walking the same three layers.
    def self.tile_passable?(rec, x, y, d, level = nil)
      c = (rec[:pc] ||= {})
      k = ((x * 1000 + y) * 16 + d) * 3 + (level.nil? ? 2 : (level > 0 ? 1 : 0))
      v = c[k]
      return v unless v.nil?
      c[k] = tile_passable_raw?(rec, x, y, d, level)
    end

    def self.tile_passable_raw?(rec, x, y, d, level = nil)
      return false if x < 0 || y < 0 || x >= rec[:w] || y >= rec[:h]
      bit = (1 << (d / 2 - 1)) & 0x0f
      [2, 1, 0].each do |i|
        tid = rec[:data][x, y, i]
        return false if tid.nil?
        if level && bridge_tag?(rec[:terrain][tid])
          next if level == 0
          psb = rec[:passages][tid]
          return false if psb.nil? || psb & bit != 0 || psb & 0x0f == 0x0f
          return true
        end
        ps = rec[:passages][tid]
        return false if ps.nil?
        return false if ps & bit != 0
        return false if ps & 0x0f == 0x0f
        return true if rec[:priorities][tid] == 0
      end
      true
    rescue StandardError
      false
    end

    # The terrain tag of the top-most tile that has one, or 0.
    def self.terrain_at(rec, x, y, level = nil)
      c = (rec[:tc] ||= {})
      k = (x * 1000 + y) * 3 + (level.nil? ? 2 : (level > 0 ? 1 : 0))
      v = c[k]
      return v unless v.nil?
      c[k] = terrain_at_raw(rec, x, y, level)
    end

    def self.terrain_at_raw(rec, x, y, level = nil)
      return 0 if x < 0 || y < 0 || x >= rec[:w] || y >= rec[:h]
      [2, 1, 0].each do |i|
        tid = rec[:data][x, y, i]
        next if tid.nil? || tid == 0
        t = rec[:terrain][tid]
        next if level == 0 && bridge_tag?(t)
        return t if t && t != 0
      end
      0
    rescue StandardError
      0
    end

    # The tile one step from (x,y) in direction d, or nil when the step is blocked. Both halves of the
    # engine's test: you must be able to LEAVE this tile that way and ENTER that one from this side.
    #
    # Plus WATER, which the tileset alone does not answer. Essentials leaves water tiles PASSABLE in the
    # tileset -- that is how surfing works at all -- and blocks them in Game_Map#passable? by terrain tag.
    # Without that rule this model walked straight across every lake and river it met, and a route computed
    # over a cave full of water is worse than no route: it is confident and wrong, which is exactly what
    # "it loses the plot right about when we get on water" looks like from the other end.
    def self.step(rec, x, y, d)
      dd = DIRS[d]
      return nil if dd.nil?
      nx = x + dd[0]; ny = y + dd[1]
      j = (rec[:jumps] || {})[key(nx, ny)]
      carry = j ? j[d] : nil
      unless walkable_step?(rec, x, y, nx, ny, d)
        # Blocked ahead, but the thing blocking is a jump lip: she bumps it and is carried from where she
        # STANDS. Without a carry it is simply a wall.
        return carry ? standable(rec, x + carry[0], y + carry[1]) : nil
      end
      return [nx, ny] if carry.nil?
      # The step itself always stands. If the landing cannot be validated the model of the mechanism is
      # wrong, and dropping only the extra displacement is safer than turning a walkable tile into a wall.
      standable(rec, nx + carry[0], ny + carry[1]) || [nx, ny]
    end

    # The ordinary one-tile test, with no mechanism in it.
    def self.walkable_step?(rec, x, y, nx, ny, d)
      return false if rec[:blocked][key(nx, ny)]
      # A transfer tile leaves the map; a region is where she can walk WITHOUT leaving (see Pathfinder.exit_tile?).
      return false if exit_step?(rec, nx, ny, d)
      surfing = ($PokemonGlobal && $PokemonGlobal.surfing) ? true : false
      wet = PokeAccess::Terrain.water?(terrain_at(rec, nx, ny))
      return false if wet != surfing
      return false unless tile_passable?(rec, x, y, d)
      tile_passable?(rec, nx, ny, 10 - d)
    end

    # A tile a carry may drop the player on: on the map, not occupied, the right side of the waterline,
    # and enterable from at least one direction.
    def self.standable(rec, x, y)
      return nil if x < 0 || y < 0 || x >= rec[:w] || y >= rec[:h]
      return nil if rec[:blocked][key(x, y)]
      surfing = ($PokemonGlobal && $PokemonGlobal.surfing) ? true : false
      return nil if PokeAccess::Terrain.water?(terrain_at(rec, x, y)) != surfing
      return nil unless [2, 4, 6, 8].any? { |dd| tile_passable?(rec, x, y, dd) }
      [x, y]
    rescue StandardError
      nil
    end

    # Every tile walkable from (sx,sy) on a map that is not loaded, as a hash of packed keys. Bounded, and
    # answers nil rather than a half-flood when it runs out of budget -- a truncated region would make the
    # router claim a door leads nowhere.
    def self.flood(mid, sx, sy, max_tiles = 20000)
      rec = info(mid)
      return nil if rec.nil?
      seen = { key(sx, sy) => true }
      queue = [[sx, sy]]
      head = 0
      while head < queue.length
        return nil if seen.length > max_tiles
        cur = queue[head]; head += 1
        [2, 4, 6, 8].each do |d|
          n = step(rec, cur[0], cur[1], d)
          next if n.nil?
          k = key(n[0], n[1])
          next if seen[k]
          seen[k] = true
          queue.push(n)
        end
      end
      seen
    rescue StandardError
      nil
    end

    # Everywhere reachable from (sx,sy) on a map that is not loaded, on foot AND by surfing, as packed keys
    # whose value is true (reached on foot) or :surf (reached only after pushing off from a shore). For a
    # player who can surf.
    #
    # The walking flood above was the only one, so a route that needed water in any room she was not standing
    # in did not exist: Whirl Islands is rooms joined by pools, spread over three maps, and past the first
    # pool every door read as unreachable. The rules are the engine's, as the current-map router already
    # models them: launch where her own tile is open toward surfable water, paddle where both water tiles are
    # open afloat (a support or rock drawn over the water still blocks), land where the shore accepts entry.
    def self.amphi_flood(mid, sx, sy, max_tiles = 30000)
      rec = info(mid)
      return nil if rec.nil?
      # Arriving on a map resets the bridge, so every region starts on the ground -- unless the landing is on a
      # ramp, which sets its own height.
      lv0 = rec[:ramps][key(sx, sy)] || 0
      start_wet = water_tag?(terrain_at(rec, sx, sy, lv0))
      seen = { key(sx, sy) => (start_wet ? :surf : true) }
      states = { key(sx, sy) * 2 + (lv0 > 0 ? 1 : 0) => true }
      queue = [[sx, sy, start_wet, lv0]]
      head = 0
      while head < queue.length
        return nil if seen.length > max_tiles
        x, y, wet, lv = queue[head]; head += 1
        [2, 4, 6, 8].each do |d|
          n = amphi_step(rec, x, y, wet, d, lv)
          next if n.nil?
          k = key(n[0], n[1])
          nlv = rec[:ramps][k] || lv
          sk = k * 2 + (nlv > 0 ? 1 : 0)
          next if states[sk]
          states[sk] = true
          seen[k] = (wet || n[2]) ? :surf : true unless seen[k] == true
          queue.push([n[0], n[1], n[2], nlv])
        end
      end
      seen
    rescue StandardError
      nil
    end

    # True if stepping onto (x,y) in direction d would leave the map (a one-way doorway only in its own direction).
    def self.exit_step?(rec, x, y, d)
      e = rec[:exit_tiles] && rec[:exit_tiles][key(x, y)]
      return false unless e
      e == true || e == d
    end

    def self.water_tag?(t)
      @water_c ||= {}
      v = @water_c[t]
      return v unless v.nil?
      @water_c[t] = (PokeAccess::Terrain.water?(t) ? true : false)
    rescue StandardError
      false
    end

    def self.surf_tag?(t)
      # Keyed by TAG, so unlike the pathfinder's per-map tile cache nothing ever drops it. The waterfall
      # gate can change under it, so the gate's own answer is part of the key.
      wf = PokeAccess::Terrain.waterfall_open? ? 1 : 0
      if @surf_c_wf != wf; @surf_c_wf = wf; @surf_c = {}; end
      @surf_c ||= {}
      v = @surf_c[t]
      return v unless v.nil?
      @surf_c[t] = (PokeAccess::Terrain.surfable?(t) ? true : false)
    rescue StandardError
      false
    end

    def self.bridge_tag?(t)
      @bridge_c ||= {}
      v = @bridge_c[t]
      return v unless v.nil?
      @bridge_c[t] = (PokeAccess::Terrain.bridge?(t) ? true : false)
    rescue StandardError
      false
    end

    # One amphibious move as [x, y, afloat_after], or nil.
    def self.amphi_step(rec, x, y, wet, d, lv = 0)
      dd = DIRS[d]
      nx = x + dd[0]; ny = y + dd[1]
      return nil if nx < 0 || ny < 0 || nx >= rec[:w] || ny >= rec[:h]
      k = key(nx, ny)
      return nil if rec[:blocked][k]
      return nil if exit_step?(rec, nx, ny, d)
      t = terrain_at(rec, nx, ny, lv)
      dest_wet = water_tag?(t)
      if !wet && !dest_wet
        n = step_on_foot(rec, x, y, d, lv)
        return n ? [n[0], n[1], false] : nil
      end
      if !wet
        # Launch: her own tile open toward surfable water.
        return nil unless surf_tag?(t)
        return tile_passable?(rec, x, y, d, lv) ? [nx, ny, true] : nil
      end
      return nil unless afloat_open?(rec, x, y, d)
      return (afloat_open?(rec, nx, ny, 10 - d) ? [nx, ny, true] : nil) if dest_wet
      # Landing.
      tile_passable?(rec, nx, ny, 10 - d, lv) ? [nx, ny, false] : nil
    rescue StandardError
      nil
    end

    # step() with the waterline forced to "on foot", whatever the player is doing right now.
    def self.step_on_foot(rec, x, y, d, lv = 0)
      dd = DIRS[d]
      nx = x + dd[0]; ny = y + dd[1]
      j = (rec[:jumps] || {})[key(nx, ny)]
      carry = j ? j[d] : nil
      ok = !rec[:blocked][key(nx, ny)] && !water_tag?(terrain_at(rec, nx, ny, lv)) &&
           tile_passable?(rec, x, y, d, lv) && tile_passable?(rec, nx, ny, 10 - d, lv)
      unless ok
        return nil unless carry
        lx = x + carry[0]; ly = y + carry[1]
        return nil if lx < 0 || ly < 0 || lx >= rec[:w] || ly >= rec[:h] || rec[:blocked][key(lx, ly)]
        return [lx, ly]
      end
      return [nx, ny] if carry.nil?
      [nx + carry[0], ny + carry[1]]
    rescue StandardError
      nil
    end

    # A water tile's passability with her afloat on it (Pathfinder.afloat_tile_open? over the loaded tables):
    # layers 2, 1, 0, bridges skipped as at ground level, the water layer itself open.
    def self.afloat_open?(rec, x, y, d)
      c = (rec[:ac] ||= {})
      k = (x * 1000 + y) * 16 + d
      v = c[k]
      return v unless v.nil?
      c[k] = afloat_open_raw?(rec, x, y, d)
    end

    def self.afloat_open_raw?(rec, x, y, d)
      return false if x < 0 || y < 0 || x >= rec[:w] || y >= rec[:h]
      bit = (1 << (d / 2 - 1)) & 0x0f
      [2, 1, 0].each do |i|
        tid = rec[:data][x, y, i]
        return false if tid.nil?
        t = rec[:terrain][tid]
        next if bridge_tag?(t)
        return true if water_tag?(t)
        ps = rec[:passages][tid]
        return false if ps.nil?
        return false if ps & bit != 0
        return false if ps & 0x0f == 0x0f
        return true if rec[:priorities][tid] == 0
      end
      true
    rescue StandardError
      false
    end

    # The transfers a map offers, as [x, y, dest_map, dest_x, dest_y].
    def self.warps(mid)
      rec = info(mid)
      rec ? rec[:warps] : []
    end

    # Checks the MODEL against the ENGINE on the current map: samples tiles around the player and compares
    # both answers. Used by the self-check, and by anything that wants to know whether to trust this module
    # on a map it cannot verify. Returns [agreements, disagreements].
    def self.agrees_with_engine?(samples = 300)
      mid = ($game_map.map_id rescue nil)
      rec = mid ? info(mid) : nil
      return [0, 0] if rec.nil? || $game_player.nil?
      ok = 0; bad = 0
      px = $game_player.x; py = $game_player.y
      n = 0
      r = 12
      (-r..r).each do |dx|
        (-r..r).each do |dy|
          next if n >= samples
          x = px + dx; y = py + dy
          next if x < 0 || y < 0 || x >= rec[:w] || y >= rec[:h]
          [2, 4, 6, 8].each do |d|
            mine = !step(rec, x, y, d).nil?
            theirs = ($game_player.passable?(x, y, d) rescue false)
            mine == theirs ? ok += 1 : bad += 1
          end
          n += 1
        end
      end
      [ok, bad]
    rescue StandardError
      [0, 0]
    end
  end
end

# A foreign map's shape never changes, but the cache is dropped with the rest on a map change so a long
# session cannot accumulate them.
PokeAccess::Caches.register(:foreign_map) { PokeAccess::ForeignMap.reset }
