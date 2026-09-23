module PokeAccess
  # A* pathfinder over walkable tiles (binary heap, manhattan heuristic), with ledge hops, ice slides,
  # selectable JPS/HPA* variants, and a reachability flood.
  module Pathfinder
    # Tile-coordinate packing stride: a tile packs as x*PKEY_STRIDE+y into one Integer hash key (HPA* reuses
    # the same stride to pack cluster ids). Map dimensions stay well under it.
    PKEY_STRIDE = 100000

    # Packs a tile coordinate into a single hash key.
    def self.pkey(x, y); x * PKEY_STRIDE + y; end

    # Packs a SEARCH state -- a tile plus whether the bridge is raised -- into one key. A map with a
    # drawbridge is really two maps laid over each other, and the same tile is a wall in one and a floor
    # in the other, so the search has to keep them apart. On a map with no bridge ramp the flag never
    # changes, the packing stays one-to-one and nothing about the search differs.
    def self.skey(x, y, b); pkey(x, y) * 2 + (b > 0 ? 1 : 0); end

    # rpg direction code => [dx, dy], for the callers that walk a finished route (which is a list of
    # direction codes) rather than expanding neighbours.
    DELTA = { 8 => [0, -1], 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0] }

    # The four orthogonal steps as [dx, dy, rpg direction code], shared by the search and the flood.
    DIRS = [[0, -1, 8], [0, 1, 2], [-1, 0, 4], [1, 0, 6]]
    # Only run the full reachability flood for targets at least this far (manhattan); nearer ones are
    # cheap for A* to resolve directly, so the flood would be wasted work.
    FLOOD_MIN = 24

    @pcache = {}
    @pcache_state = nil

    # Passability of a one-step move from (cx,cy) in direction d, optionally memoised per map and vehicle
    # state (route_cache) so the engine's costly passable? is not repeated across the flood, A* and guide
    # refreshes. The cache does NOT track moving events, so it is an opt-in toggle the player can turn off.
    # True when the ENGINE's passability answer must be overridden because the player is surfing.
    #
    # Insurgence (like base Essentials of this era) makes a water tile passable while surfing only when the
    # question is about the tile the player is STANDING ON -- Game_Map#passable? guards its water branch with
    # `x == $game_player.x && y == $game_player.y`. A search asks about tiles all over the map, so every
    # water tile except the one under the player came back "wall", and the router could not plot a course on
    # open water at all: it answered "no route" the moment she was afloat, and hugged the bank when it
    # answered at all. Verified in the running game -- from a water tile, a destination whose every approach
    # is water routed as nil with the flag set.
    #
    # So while surfing, and only then, a step from water to water is passable on the mod's own reading of the
    # terrain. It claims nothing the engine would not also allow for the player's own tile; it just stops
    # asking a question whose answer depends on where the player happens to be standing.
    #
    # The same guard hides the LANDING. Surfing ends when she presses toward land from the water (pbEndSurf,
    # from Game_Player#move_*), and the engine's first test there is the water tile's own passability -- true
    # only underfoot. So a route afloat could reach the water beside an island and never step ashore: "no
    # route" to the Cave of Steam door with the island in plain sight (Helios City, 2026-09-11). A step from
    # surfable water onto dry land is therefore passable when the LAND side would let her in: the tile accepts
    # entry from that direction and nothing solid stands on it -- the half of the engine's test that does
    # not depend on where she is.
    def self.surfing_water_step?(cx, cy, d)
      return false unless ($PokemonGlobal && $PokemonGlobal.surfing rescue false)
      return false unless surfable_cached?(cx, cy)
      dd = DIRS.detect { |e| e[2] == d }
      return false if dd.nil?
      nx = cx + dd[0]; ny = cy + dd[1]
      return false if afloat_tile_open?(cx, cy, d) == false
      return afloat_tile_open?(nx, ny, 10 - d) != false if surfable_cached?(nx, ny)
      landing_from_water?(nx, ny, d)
    rescue StandardError
      false
    end

    # The engine's own passability for a WATER tile as it would answer with her afloat on it: RMXP
    # Game_Map#passable? layer by layer (2, 1, 0), bridge tiles skipped at level 0, and the water layer itself
    # passable while surfing -- which is exactly the branch the engine only grants the tile under the player.
    #
    # The shortcut this replaces said "water joins water" and nothing else. Under Miara Town's bridges the
    # supports are drawn on a layer ABOVE the water with their own passage bits, so the engine stops her
    # leaving under a bridge sideways while the router happily planned it: the guide said "14 left" and she
    # could not take one of them. true / false, or nil when this engine does not expose the tables (the caller
    # then keeps its old answer).
    def self.afloat_tile_open?(x, y, d)
      st = [($game_map.map_id rescue 0), bridge_state > 0 ? 1 : 0]
      if @afloat_c.nil? || @afloat_c_state != st
        @afloat_c = {}
        @afloat_c_state = st
      end
      k = pkey(x, y) * 16 + d
      return @afloat_c[k] if @afloat_c.has_key?(k)
      @afloat_c[k] = afloat_tile_open_raw?(x, y, d)
    end

    # Memoised above per map, bridge level, tile and direction: a sea flood asks this eight times per tile,
    # and uncached it made every step afloat re-flood Stormy Seas for a second and a half.
    def self.afloat_tile_open_raw?(x, y, d)
      m = $game_map
      pas = m.instance_variable_get(:@passages)
      pri = m.instance_variable_get(:@priorities)
      tags = m.instance_variable_get(:@terrain_tags)
      data = (m.data rescue nil)
      return nil if pas.nil? || pri.nil? || tags.nil? || data.nil?
      return false unless m.valid?(x, y)
      bit = (1 << (d / 2 - 1)) & 0x0f
      m.events.each_value do |ev|
        next unless ev.x == x && ev.y == y && !(ev.through rescue false)
        tid = (ev.tile_id rescue 0).to_i
        next unless tid > 0
        return false if pas[tid] & bit != 0 || pas[tid] & 0x0f == 0x0f
        return true if pri[tid] == 0
      end
      level = bridge_state
      [2, 1, 0].each do |i|
        tid = data[x, y, i]
        return false if tid.nil?
        t = tags[tid]
        next if level == 0 && PokeAccess::Terrain.bridge?(t)
        return true if PokeAccess::Terrain.water?(t)
        return false if pas[tid] & bit != 0
        return false if pas[tid] & 0x0f == 0x0f
        return true if pri[tid] == 0
      end
      true
    rescue StandardError
      nil
    end

    # Can she come ashore on (x,y) moving in direction d? The land tile must not be water of any kind, must
    # accept entry from that side, and must not have a solid sprite standing on it (Game_Character#passableEx?
    # lets the player through a sprite-less event, and nothing else).
    def self.landing_from_water?(x, y, d)
      return false unless ($game_map.valid?(x, y) rescue false)
      return false if PokeAccess::Terrain.water_at?(x, y)
      return false unless ($game_map.passable?(x, y, 10 - d) rescue false)
      !(($game_map.events.values.any? do |e|
          e.x == x && e.y == y && !(e.through rescue false) && !(e.character_name.to_s.empty? rescue true)
        end) rescue false)
    rescue StandardError
      false
    end

    # Surfable water at a tile, memoised per map and bridge level. Terrain does not change under a search, and
    # the surf flood asks this for every neighbour of every tile of a sea -- Helios City is 5,652 tiles of
    # water, and the uncached question was most of a 2.4-second freeze.
    #
    # One table per bridge level, not one table flushed on a level change: a search on a bridge map flips
    # the level from node to node, and a flush on every flip would throw the whole cache away constantly.
    def self.surfable_cached?(x, y)
      mid = ($game_map.map_id rescue 0)
      if @surfc_map != mid; @surfc_map = mid; @surfc = [{}, {}]; end
      tbl = @surfc[bridge_state > 0 ? 1 : 0]
      k = pkey(x, y)
      v = tbl[k]
      return v unless v.nil?
      tbl[k] = (PokeAccess::Terrain.surfable_at?(x, y) ? true : false)
    rescue StandardError
      false
    end

    # A vertical step on or off climbable rock, while the field-move gates are set aside. The engine walls
    # these tiles off; the game carries the player up or down the whole face when she presses action facing
    # it (Kernel.pbAscendRockClimb / pbDescendRockClimb move one tile at a time, so the step count holds).
    # Only ever consulted inside Gates.with_removed, so a route through the rocks is always a GATED route and
    # the cane stops at the foot of the face and names it, exactly as it does at a cuttable tree.
    def self.climb_step?(cx, cy, d)
      return false unless @gates_open
      return false unless d == 2 || d == 8
      return false unless PokeAccess::Terrain.climb_supported?
      ny = cy + (d == 2 ? 1 : -1)
      on = PokeAccess::Terrain.climb_at?(cx, cy)
      onto = PokeAccess::Terrain.climb_at?(cx, ny)
      return false unless on || onto
      return true if onto
      !landing(cx, ny).nil?
    rescue StandardError
      false
    end

    # $game_player.passable?, asked as if she were NOT walking through walls. RMXP answers "passable" for every
    # tile while the player's through flag is on, and games switch it on for scripted moves: Insurgence's cave
    # doors step her off the door tile with "through on, move, through off". A route asked for in that half
    # second was planned straight through rock ("20 up" into a cliff, just after a doorway) and the passability
    # cache kept the lie. The flag is set aside for the one question and put back.
    def self.player_passable?(x, y, d)
      pl = $game_player
      return false if pl.nil?
      was = (pl.through rescue false)
      return (pl.passable?(x, y, d) ? true : false) unless was
      begin
        pl.through = false
        pl.passable?(x, y, d) ? true : false
      ensure
        pl.through = was
      end
    rescue StandardError
      false
    end

    # A step onto an obstacle that is TERRAIN rather than an event (Insurgence's sludge, which a Mew clears
    # with Seed Flare), while the field-move gates are set aside. Like climb_step?, only ever true inside
    # Gates.with_removed, so such a route is always a gated one: the guide walks her to the edge of it and
    # names what clears it instead of calling the whole far side unreachable.
    def self.terrain_gate_step?(cx, cy, d)
      return false unless @gates_open
      nx = cx + (d == 6 ? 1 : (d == 4 ? -1 : 0))
      ny = cy + (d == 2 ? 1 : (d == 8 ? -1 : 0))
      onto = (PokeAccess::Gates.at(nx, ny) rescue nil)
      return true if onto && onto[1] == :clear
      # And OFF it again. Sludge is water, and the engine refuses to let someone on foot leave a water tile,
      # so a crossing that could only be entered dead-ended in the middle: the far shore of the Abyssal
      # Base's channel stayed unreachable while the router happily walked half way across. Like climb_step?,
      # the step is allowed in both directions and only onto something that can be stood on.
      on = (PokeAccess::Gates.at(cx, cy) rescue nil)
      return false unless on && on[1] == :clear
      !landing(nx, ny).nil?
    rescue StandardError
      false
    end

    # The engine's answer, with the surfing and climbing overrides applied.
    def self.engine_passable?(cx, cy, d)
      return true if surfing_water_step?(cx, cy, d)
      return true if climb_step?(cx, cy, d)
      return true if terrain_gate_step?(cx, cy, d)
      (PokeAccess::Pathfinder.player_passable?(cx, cy, d) rescue false)
    end

    def self.passable_at?(cx, cy, d)
      return engine_passable?(cx, cy, d) unless (PokeAccess::Config.route_cache rescue false)
      # The map OBJECT too, not just its id: a reload of the same map is a new world.
      st = [($game_map.map_id rescue 0), ($game_map.__id__ rescue 0), ($PokemonGlobal.surfing rescue false), ($PokemonGlobal.diving rescue false)]
      if @pcache_state != st; @pcache_state = st; @pcache = {}; end
      # Everything else the engine's answer depends on that the tile and direction do not carry goes in the
      # KEY, not in the signature above: the searches flip these as they run, and a signature change would
      # empty the whole cache on every flip. Leaving them out entirely is worse -- a "wall" cached by the
      # ordinary flood was being handed back to the search that had just taken the tree down.
      k = (pkey(cx, cy) * 16 + d) * 8 + effective_variant(cx, cy, d)
      v = @pcache[k]
      return v unless v.nil?
      @pcache[k] = engine_passable?(cx, cy, d)
    rescue StandardError
      (PokeAccess::Pathfinder.player_passable?(cx, cy, d) rescue false)
    end

    # Whether the field-move obstacles are currently set aside (Gates.with_removed) and whether the
    # boulders are (Gates.with_boulders_through). Only those two set these, and both always put them back.
    def self.gates_open=(v); @gates_open = v; end
    def self.boulders_open=(v); @boulders_open = v; end
    def self.gates_open; @gates_open; end
    def self.boulders_open; @boulders_open; end

    # The passability cache's variant bits: the same tile answers differently with the bridge up, with the
    # trees down, or with the boulders set aside, so each answer is cached under its own world.
    def self.pass_variant
      (bridge_state > 0 ? 1 : 0) | (@gates_open ? 2 : 0) | (@boulders_open ? 4 : 0)
    end

    # The variant a step's cached answer actually depends on. Opening the gates changes the engine's answer
    # ONLY for a step that starts or ends on an obstacle tile: through-ness is tested on those two tiles and
    # nowhere else (Game_Character#passableEx?, Game_Map#passable?), and a climb override applies only on the
    # rock. Keying every step on the gate bits made every gated search re-ask the engine about the whole map
    # -- 1.4 seconds in Helios City, whose only obstacles are two tiles of rock on the far side of the bay.
    # Still keyed on every state that CAN change the answer; see the note in passable_at?.
    def self.effective_variant(cx, cy, d)
      v = pass_variant
      return v if v <= 1
      idx = (PokeAccess::Gates.index rescue nil)
      return v if idx.nil?
      dd = DIRS.detect { |e| e[2] == d }
      return v if dd.nil?
      return v if idx[pkey(cx, cy)] || idx[pkey(cx + dd[0], cy + dd[1])]
      v & 1
    rescue StandardError
      pass_variant
    end

    # Drops the memoised passability and reachable-set caches, and the HPA* abstract graph with them, so the
    # next route is computed against current map state. Called when a map event finishes, since a switch
    # flip or a moved event may have changed what is passable. Throttled to once every couple of seconds: a
    # cutscene fires many event-ends in a row and a cold re-flood is costly, more so on a game whose
    # passable? is slow. param force bypasses the throttle, for a caller that KNOWS a door just opened
    def self.invalidate_cache(force = false)
      now = (PokeAccess.clock rescue 0)
      return if !force && @last_invalidate && (now - @last_invalidate) < 2.0
      @last_invalidate = now
      @pcache = {}
      @pcache_state = nil
      @rs_key = nil
      @hpa = nil
      @hpa_sig = nil
      @surf_key = nil
      @surf_route = nil
      @srs_key = nil
      @srs_cache = nil
      @surfg_key = nil
      @surfg_route = nil
      @slide_key = nil
      @warp_key = nil
      @exit_key = nil
      @afloat_c = nil
      @bridge_key = nil
      # What is SURFABLE is keyed by map alone, because terrain does not change -- except where a game
      # changes it in place. Insurgence's Seed Flare turns a map's sludge into water and reloads the same
      # map id, so that table would keep answering "not water" for the rest of the session. Cleared only on
      # a forced invalidation (a map change, or a profile that knows the world just changed): re-asking the
      # engine about every tile of a sea is exactly the cost this table exists to avoid, and an ordinary
      # event end cannot have moved the water.
      if force
        @surfc_map = nil
        @surfc = nil
      end
      (PokeAccess::Gates.invalidate rescue nil)
    end

    # The farthest a target can be (manhattan tiles) for find_path and the flood to consider it,
    # user-tunable: a diamond around the player whose value is the straight (cardinal) reach.
    def self.reach; (PokeAccess::Config.route_reach rescue 128).to_i; end

    # How often (in expanded nodes) the time-budget search checks the clock. Checking every node would pay
    # the monotonic-clock call too often; every BUDGET_CHECK nodes keeps the overhead negligible.
    BUDGET_CHECK = 256

    # The deadline (a clock value) every search in the CURRENT operation shares, or nil when the auto/time
    # mode is off, which bounds the search by node count (astar_max) instead.
    #
    # Shared, because one find_path runs up to three searches -- the reachability probe, the plain route,
    # then the route allowing ledges -- and a clock per search would spend the player's budget three times
    # over. Running out on the first pass returns nil, and nil is exactly what fires the next pass.
    def self.search_deadline
      return @budget_until if @budget_until
      fresh_deadline
    end

    # A brand-new deadline, ignoring any in scope. Only with_budget and search_deadline should call this.
    def self.fresh_deadline
      return nil unless (PokeAccess::Config.route_auto rescue false)
      ms = (PokeAccess::Config.route_budget_ms rescue 8).to_i
      (PokeAccess.clock rescue 0.0) + (ms / 1000.0)
    end

    # Runs a block with ONE deadline covering everything inside it, so route_budget_ms means what the option
    # says. Nesting keeps the OUTER deadline (an inner search must not award itself a fresh budget), and the
    # previous value is always restored, so a search that throws never leaves a stale deadline behind to cut
    # the next one short.
    def self.with_budget
      outer = @budget_until
      @budget_until = outer || fresh_deadline
      yield
    ensure
      @budget_until = outer
    end

    # True once a search must stop: in time mode when the deadline passed (checked every BUDGET_CHECK nodes),
    # otherwise when the node count exceeds astar_max.
    def self.over_budget?(iter, deadline)
      if deadline
        return false unless (iter & (BUDGET_CHECK - 1)) == 0
        (PokeAccess.clock rescue 0.0) > deadline
      else
        iter > PokeAccess::Config.astar_max
      end
    end

    # The landing tile of a ledge hop from (cx,cy) one step in direction d, or nil when there is no ledge
    # that way. The game hops two tiles toward any faced ledge unconditionally, so this does the same,
    # requiring only a real standable landing; one-way behaviour comes from the map (you reach a ledge
    # only from its high side). Lets the search cross ledges the player hops over but cannot walk through.
    def self.ledge_jump(cx, cy, dx, dy, d)
      nx = cx + dx; ny = cy + dy
      return nil unless PokeAccess::Terrain.ledge_at?(nx, ny)
      return nil unless ledge_dir_ok?(nx, ny, d)
      lx = cx + 2 * dx; ly = cy + 2 * dy
      return nil unless ($game_map.valid?(lx, ly) rescue false)
      return nil unless [2, 4, 6, 8].any? { |dd| (PokeAccess::Pathfinder.player_passable?(lx, ly, dd) rescue false) }
      [lx, ly]
    rescue StandardError
      nil
    end

    # Jump direction => the tileset-passage bit of the side OPPOSITE the jump.
    LEDGE_OPP_BIT = { 2 => 0x08, 8 => 0x01, 4 => 0x04, 6 => 0x02 }

    # True if the ledge at (x,y) may be hopped in direction d. A ledge is one-way, so the hop is allowed
    # when the side opposite the jump is open. Permissive (true) when the passage can't be read or the
    # directions setting is off, so nothing is wrongly blocked.
    def self.ledge_dir_ok?(x, y, d)
      return true unless (PokeAccess::Config.ledge_directions rescue true)
      ob = LEDGE_OPP_BIT[d]
      return true unless ob
      p = ledge_passage(x, y)
      return true if p.nil?
      (p & ob) == 0
    rescue StandardError
      true
    end

    # The tileset passage byte of the ledge tile at (x,y) (the top layer whose terrain is a ledge), or
    # nil when the passage/terrain tables are unavailable (a non-RMXP engine).
    def self.ledge_passage(x, y)
      passages = $game_map.instance_variable_get(:@passages)
      tags = $game_map.instance_variable_get(:@terrain_tags)
      return nil unless passages && tags
      [2, 1, 0].each do |i|
        tid = ($game_map.data[x, y, i] rescue 0)
        next if tid.nil? || tid == 0
        return passages[tid] if tags[tid] == 1
      end
      nil
    rescue StandardError
      nil
    end

    # Move-route command code => tile delta, for decoding how far a forced move carries the player.
    MOVE_DELTA = { 1 => [0, 1], 2 => [-1, 0], 3 => [1, 0], 4 => [0, -1],
                   5 => [-1, 1], 6 => [1, 1], 7 => [-1, -1], 8 => [1, -1] }

    # Move route "Jump", whose distance is in its PARAMETERS rather than implied by its code -- the one
    # step command that cannot be read from the code alone, and so the one that was being read as zero.
    JUMP_CODE = 14

    # Every forced move a sprite-less touch event applies to the player, as
    # { trigger-direction => [dx, dy] } net displacements, or {} for an event that is not one.
    #
    # This one event shape covers two mechanisms that differ ONLY in whether its tile can be stood on:
    #   * a SLIDE ("minihueco") on a passable tile -- you step on and are carried across a gap;
    #   * a diagonal STAIRCASE on an impassable tile -- you never arrive, you bump it and are carried
    #     from where you stand. Insurgence alone has over a thousand of these, and they are how the two
    #     halves of a cave are joined.
    # So the displacement is stored raw and the caller decides what it is relative to (see move_target).
    #
    # Every direction branch is kept. The old single-value read took the LAST facing and the LAST move
    # route in the page and paired them, which for a staircase (one branch per direction, both in one
    # page) silently discarded the other way up the stairs.
    def self.forced_moves(ev)
      trig = PokeAccess.ivar(ev, :@trigger)
      return {} unless trig == 1 || trig == 2
      return {} unless ev.character_name.to_s.empty?
      list = PokeAccess.ivar(ev, :@list)
      return {} unless list.is_a?(Array)
      # A doorway that shuffles the player off its tile on the way through is not a mechanism of its own:
      # the transfer is what happens, and the warp index already has it. Reading its tidy-up move route as
      # a carry would invent a jump through the wall the door is drawn on.
      return {} if list.any? { |c| (c.code rescue 0) == 201 }
      facing_branches(list, {})
    rescue StandardError
      {}
    end

    # The net [dx, dy] of a "Set move route" on the player, jumps included.
    def self.route_delta(route)
      dx = 0; dy = 0
      ((route.list rescue []) || []).each do |mc|
        mcode = (mc.code rescue 0)
        if mcode == JUMP_CODE
          jp = (mc.parameters rescue nil)
          if jp.is_a?(Array) && jp.length >= 2
            dx += jp[0].to_i
            dy += jp[1].to_i
          end
        else
          d = MOVE_DELTA[mcode]
          if d
            dx += d[0]
            dy += d[1]
          end
        end
      end
      [dx, dy]
    end

    # Reads "if the player is facing <f>: move route ... else: move route ..." blocks out of one command
    # list into out as { facing => [dx, dy] }. Shared with ForeignMap, so the live map and the model of a
    # map she is not on can never disagree about what a bump does.
    #
    # The ELSE half is a real move. Sonata Gym's hedges are each one event: "facing up, jump two up;
    # otherwise, jump two down" -- the same hedge hopped from either side. Read as the IF alone, every hedge
    # was a one-way door, and a pocket entered by hopping down read as sealed: 17 tiles from where she stood,
    # against the 767 the game actually lets her walk. The else answers every facing the IF did not name.
    def self.facing_branches(list, out)
      stack = []; elses = []
      list.each do |c|
        code = (c.code rescue 0)
        ind = (c.indent rescue 0)
        pars = (c.parameters rescue nil) || []
        if code == 111 && pars[0] == 6 && pars[1] == -1
          stack.push([pars[2], false, ind])
        elsif code == 411 && !stack.empty? && stack[-1][2] == ind
          stack[-1][1] = true
        elsif code == 412 && !stack.empty? && stack[-1][2] == ind
          stack.pop
        elsif code == 209 && (pars[0].to_i rescue nil) == -1
          mv = route_delta(pars[1])
          next if mv == [0, 0]
          if stack.empty?
            # No conditional at all: the carry runs whichever way she walked into it, so it applies to every
            # facing. Requiring a facing branch made these invisible, and they are not rare -- 392 of them on
            # 92 Insurgence maps, 533 in Eternal Emerald, 350 in Z. One of them is the hop out of the pocket
            # she was stuck in: the engine carried her four tiles east while the router saw a wall.
            [2, 4, 6, 8].each { |d| out[d] = mv unless out.has_key?(d) }
            next
          end
          f, in_else, _ind = stack[-1]
          if in_else
            elses.push([f, mv])
          elsif f && !out.has_key?(f)
            out[f] = mv
          end
        end
      end
      elses.each do |f, mv|
        [2, 4, 6, 8].each { |d| out[d] = mv if d != f && !out.has_key?(d) }
      end
      out
    end

    # Per-map index of forced-move tiles: pkey => { trigger-direction => [dx, dy] }, cached so events are
    # scanned once per map.
    def self.slide_index
      key = ($game_map.map_id rescue 0)
      return @slide_idx if @slide_key == key && @slide_idx
      @slide_key = key
      idx = {}
      ($game_map.events.values rescue []).each do |ev|
        mv = forced_moves(ev)
        idx[pkey(ev.x, ev.y)] = mv unless mv.empty?
      end
      @slide_idx = idx
    rescue StandardError
      {}
    end

    # The [dx, dy] a forced-move tile applies when entered facing d, or nil.
    def self.forced_move_at(x, y, d)
      mv = slide_index[pkey(x, y)]
      mv ? mv[d] : nil
    rescue StandardError
      nil
    end

    # Commands that mean the transfer after them might not happen: a conditional branch, or anything that
    # talks to the player first (a door that ASKS is not a tile you simply walk through).
    # Deliberately NOT here: the sound, fade, wait and script lines a warp normally opens with (250, 223,
    # 106, 355). None of them can skip the command after them, so none of them makes the transfer
    # conditional; guarding on them would drop real warps to buy nothing.
    WARP_GUARD_CODES = [111, 101, 102]

    # The [x, y] a walk-onto event unconditionally transfers the player to, or nil. Deliberately strict:
    # the transfer must be literal (a variable destination is only known at run time) and nothing may
    # stand between stepping on the tile and being moved.
    #
    # Strictness is the whole point. Modelling a warp CONSUMES the step -- the tiles beyond it stop being
    # walk-through, which is correct when the warp fires and cuts a piece of the map off when it does not.
    # So a transfer is only an edge when it cannot fail to happen.
    # Returns [map, x, y, facing or nil]; the facing is set when the transfer sits behind "if the player is
    # facing <dir>", which makes the tile a one-way link like a doorway.
    #
    # A CONDITIONAL is no longer a refusal. Insurgence's bases are joined by teleport pads, and half of this
    # game's internal transfers (87 of 177) sit behind a branch: "if switch 161, go here, otherwise there".
    # Read as unanswerable, one such pad cut the whole far half of the Abyssal Base off the map -- every
    # target in it, the story step included, came back "no reachable route" while the game would have walked
    # her there. The branch is ASKED instead, of the same live state the game asks (a switch, a variable, a
    # self switch), and the side that would really run is the side the router reads. A guard it cannot
    # decide -- a script, the timer -- is still a guard, and still means no edge.
    def self.plain_warp_dest(ev)
      list = PokeAccess.ivar(ev, :@list)
      return nil unless list.is_a?(Array)
      eid = (ev.id rescue 0)
      stack = []
      list.each do |c|
        code = (c.code rescue 0)
        ind = (c.indent rescue 0)
        pars = (c.parameters rescue nil) || []
        case code
        when 111
          if pars[0] == 6 && pars[1] == -1
            stack.push([ind, false, :facing, pars[2]])
          else
            r = branch_true?(pars, eid)
            return nil if r.nil?
            stack.push([ind, false, r, nil])
          end
        when 411
          stack[-1][1] = true if !stack.empty? && stack[-1][0] == ind
        when 412
          stack.pop if !stack.empty? && stack[-1][0] == ind
        when 101, 102
          return nil if branch_live?(stack)
        when 201
          next unless branch_live?(stack)
          return nil unless pars[0] == 0
          return [pars[1], pars[2].to_i, pars[3].to_i, branch_facing(stack)]
        end
      end
      nil
    rescue StandardError
      nil
    end

    # Whether the commands at this point in a list are the ones that would actually run: every enclosing
    # branch must be on its live side. A facing guard is live on its IF side (the facing is recorded as a
    # requirement instead); its ELSE side means "walked into any other way", which is not a link worth
    # inventing, so it counts as not live.
    def self.branch_live?(stack)
      stack.all? do |s|
        if s[2] == :facing then !s[1]
        else (s[2] == true) != (s[1] == true)
        end
      end
    end

    # The facing the live branch requires, or nil when any direction works.
    def self.branch_facing(stack)
      f = nil
      stack.each { |s| f = s[3] if s[2] == :facing && !s[1] }
      f
    end

    # A conditional branch decided against the state the game itself would read: true, false, or nil when
    # this kind of condition cannot be answered here (a script, the timer, gold -- anything whose answer is
    # not simply stored). RMXP stores "is ON" as 0, which is the opposite of how it reads; confirmed against
    # the game rather than assumed, by walking onto a switch-guarded pad and seeing which way it sent her.
    def self.branch_true?(pars, eid)
      case pars[0]
      when 0 then (($game_switches[pars[1]] ? true : false) == (pars[2] == 0))
      when 2
        on = ($game_self_switches[[($game_map.map_id rescue 0), eid, pars[1].to_s]] ? true : false)
        on == (pars[2] == 0)
      when 1
        return nil unless pars[2] == 0
        v = ($game_variables[pars[1]].to_i rescue 0)
        n = pars[3].to_i
        case pars[4]
        when 0 then v == n
        when 1 then v >= n
        when 2 then v <= n
        when 3 then v > n
        when 4 then v < n
        when 5 then v != n
        end
      end
    rescue StandardError
      nil
    end

    # Per-map index of internal warps: pkey => [x, y], for a walk-onto transfer whose destination is THIS
    # map. A cave floor or a building's inner doorway is a real link between two parts of one map, and
    # with no edge for it the router calls everything on the far side unreachable. Reads the ACTIVE page
    # (Game_Event#@list), so a switch-gated door is judged as it currently stands.
    #
    # A transfer to ANOTHER map is not an edge: it leaves the map the route is being computed on. A
    # sprite-bearing door is not one either -- it may want the action button rather than a step.
    def self.warp_index
      key = ($game_map.map_id rescue 0)
      return @warp_idx if @warp_key == key && @warp_idx
      @warp_key = key
      idx = {}
      ($game_map.events.values rescue []).each do |ev|
        trig = PokeAccess.ivar(ev, :@trigger)
        next unless trig == 1 || trig == 2
        next unless (ev.character_name.to_s.empty? rescue false)
        dest = plain_warp_dest(ev)
        next unless dest && dest[0] == key
        next if (dest[1] - ev.x).abs + (dest[2] - ev.y).abs <= 1
        idx[pkey(ev.x, ev.y)] = [dest[1], dest[2], dest[3]]
      end
      @warp_idx = idx
    rescue StandardError
      {}
    end

    # The object carrying the bridge height. WHICH object it is depends on the engine generation, and
    # asking the wrong one fails silently rather than raising: gen-6 (Essentials v16-v18, so Insurgence)
    # keeps it on $PokemonMap, v19+ moved it to $PokemonGlobal. Guessing $PokemonGlobal everywhere left
    # every gen-6 bridge unmodelled, which reaches the player as an exit that reports no route --
    # Insurgence's Route 1 is cut in half by exactly one bridge.
    # Every object that carries a bridge height. There is more than one candidate because the engines
    # disagree: gen-6 (Essentials v16-v18, so Insurgence) keeps it on $PokemonMap and its $PokemonGlobal
    # has no such attribute at all, while v19+ moved it to $PokemonGlobal -- and some forks leave a vestige
    # on the other object, so "whichever answers respond_to? first" picks the wrong one and the engine
    # ignores everything written to it. Reading takes the first, writing sets them all, which is correct
    # whichever one that game's Game_Map#passable? consults; with_bridge_state puts every one back.
    #
    # Guessing $PokemonGlobal everywhere is what left every gen-6 bridge unmodelled, and that reaches the
    # player as an exit reporting no route: Insurgence's Route 1 is cut in half by exactly one bridge.
    #
    # Memoised against the candidate objects themselves, because passable_at? asks for the bridge height
    # on every single passability test and respond_to? calls there are measurable.
    def self.bridge_owners
      pm = ($PokemonMap rescue nil)
      pg = ($PokemonGlobal rescue nil)
      unless @bridge_pm.equal?(pm) && @bridge_pg.equal?(pg)
        @bridge_pm = pm; @bridge_pg = pg
        @bridge_owners = [pg, pm].compact.select { |o| (o.respond_to?(:bridge) && o.respond_to?(:bridge=)) rescue false }
      end
      @bridge_owners
    rescue StandardError
      []
    end

    # The current bridge height (0 = down / walking underneath), or 0 on an engine that has no bridges.
    def self.bridge_state
      o = bridge_owners[0]
      o ? (o.bridge.to_i rescue 0) : 0
    rescue StandardError
      0
    end

    # Sets the engine's bridge height. Only the search calls this, and only inside with_bridge_state,
    # which always puts the player's real value back.
    def self.bridge_state=(v)
      bridge_owners.each { |o| (o.bridge = v) rescue nil }
      v
    rescue StandardError
      nil
    end

    # Runs a block with the engine's bridge height restored afterwards whatever happens, so a search that
    # throws can never leave the player standing in a world whose bridge is up.
    def self.with_bridge_state
      was = bridge_owners.map { |o| (o.bridge rescue 0) }
      yield
    ensure
      begin
        bridge_owners.each_with_index { |o, i| (o.bridge = was[i]) rescue nil }
      rescue StandardError
        nil
      end
    end

    # The bridge height stepping on this event sets, or nil when it is not a ramp. Same strictness as
    # plain_warp_dest: anything that could stop the script call from running means this is not a tile the
    # player simply walks over to change level.
    def self.ramp_height(ev)
      list = PokeAccess.ivar(ev, :@list)
      return nil unless list.is_a?(Array)
      list.each do |c|
        code = (c.code rescue 0)
        return nil if WARP_GUARD_CODES.include?(code)
        next unless code == 355 || code == 655
        s = (c.parameters[0].to_s rescue "")
        return 0 if s.include?("pbBridgeOff")
        next unless s.include?("pbBridgeOn")
        m = s[/pbBridgeOn\s*\(?\s*(\d+)/, 1]
        return m ? m.to_i : 2
      end
      nil
    rescue StandardError
      nil
    end

    # Per-map index of bridge ramps: pkey => the height stepping on that tile sets. These are the ONLY
    # places the level changes, which is why the search carries the state instead of assuming it: a route
    # that crossed a raised bridge without walking up its ramp would send a blind player into a wall.
    def self.bridge_index
      key = ($game_map.map_id rescue 0)
      return @bridge_idx if @bridge_key == key && @bridge_idx
      @bridge_key = key
      idx = {}
      ($game_map.events.values rescue []).each do |ev|
        trig = PokeAccess.ivar(ev, :@trigger)
        next unless trig == 1 || trig == 2
        next unless (ev.character_name.to_s.empty? rescue false)
        h = ramp_height(ev)
        idx[pkey(ev.x, ev.y)] = h unless h.nil?
      end
      @bridge_idx = idx
    rescue StandardError
      {}
    end

    # The bridge height after stepping onto (x,y) from state b: the ramp's height, or b where there is none.
    def self.bridge_after(x, y, b)
      h = bridge_index[pkey(x, y)]
      h.nil? ? b : h
    rescue StandardError
      b
    end

    # A tile the player could be left standing on, or nil. Every mechanism edge ends here: if the landing
    # cannot be stood on then the model of that mechanism is wrong, and the edge is dropped rather than
    # guessed at -- a route that walks a blind player into a wall is worse than no route at all.
    def self.landing(x, y)
      return nil unless ($game_map.valid?(x, y) rescue false)
      return nil unless [2, 4, 6, 8].any? { |dd| (PokeAccess::Pathfinder.player_passable?(x, y, dd) rescue false) }
      [x, y]
    rescue StandardError
      nil
    end

    # One move from (cx,cy) in a direction as every search sees it: the step itself, then whatever the map
    # does to the player on arrival. The single place the four mechanisms compose, so the A*, the flood and
    # the surf sweep cannot drift apart on what a move means.
    #
    #   blocked ahead + a forced move there  -> a bump: carried from where the player STANDS (staircase)
    #   stepped on + a forced move there     -> carried on from the tile arrived at (slide)
    #   stepped on + an internal warp there  -> the warp's destination
    #
    # Returns [x, y] or nil.
    def self.move_target(cx, cy, dir, allow_ledge, edge_relax)
      d = dir[2]
      nbr = step_target(cx, cy, dir, allow_ledge, edge_relax)
      if nbr.nil?
        mv = forced_move_at(cx + dir[0], cy + dir[1], d)
        return mv ? landing(cx + mv[0], cy + mv[1]) : nil
      end
      # A step onto a real tile is never withdrawn. If the carry cannot be validated the model of the
      # mechanism is wrong, so only the EXTRA displacement is dropped and the plain step stands -- turning
      # a tile the player can walk onto into a wall would cut the map up worse than not knowing about the
      # mechanism at all. The bump case above has no such fallback: there, the step itself did not happen.
      w = warp_index[pkey(nbr[0], nbr[1])]
      # A pad behind "if the player is facing <dir>" only fires walked into that way; from any other side it
      # is ordinary floor.
      return (landing(w[0], w[1]) || nbr) if w && (w[2].nil? || w[2] == d)
      # A tile that LEAVES the map is not part of any route across it. Stepping onto one is the end of the
      # journey, so it is only ever the target -- and routes end beside the target, never on it. Walked through
      # as ordinary floor it sent her straight back where she came from: arriving on Stormy Seas, the way to
      # Whirl Islands began "6 up", across the very tile that returns to Miara Town.
      return nil if exit_tile?(nbr[0], nbr[1], d)
      mv = forced_move_at(nbr[0], nbr[1], d)
      return (landing(nbr[0] + mv[0], nbr[1] + mv[1]) || nbr) if mv
      nbr
    end

    # True if a player-touch event on (x,y) transfers her OFF this map (a door mat, a map-edge strip, the sea
    # lane back to town). Read from each event's ACTIVE page, so a door that is not open yet is not one.
    #
    # Many doorways only work walked into one way: Insurgence's cave exits open with "if the player is facing
    # up", so stepping onto the tile from any other side does nothing and is ordinary floor. d is the direction
    # of the step onto the tile; nil asks "is this an exit at all".
    def self.exit_tile?(x, y, d = nil)
      e = exit_index[pkey(x, y)]
      return false unless e
      return true if d.nil? || e == true
      e == d
    end

    # The direction a doorway must be walked into, or nil when any direction works (or it is no doorway).
    def self.door_facing(x, y)
      e = exit_index[pkey(x, y)]
      e.is_a?(Integer) ? e : nil
    end

    # The facing a transfer is guarded on ("Conditional branch: player facing <dir>" before the transfer), or
    # nil. Shared with ForeignMap through the same command shape.
    def self.facing_guard(list)
      list.each do |c|
        code = (c.code rescue 0)
        next if [0, 108, 408, 223, 250, 106].include?(code)
        if code == 111
          p = (c.parameters rescue [])
          return p[2] if p[0] == 6 && p[1] == -1 && [2, 4, 6, 8].include?(p[2])
        end
        return nil
      end
      nil
    rescue StandardError
      nil
    end

    def self.exit_index
      key = ($game_map.map_id rescue 0)
      return @exit_idx if @exit_key == key && @exit_idx
      @exit_key = key
      idx = {}
      ($game_map.events.values rescue []).each do |ev|
        trig = PokeAccess.ivar(ev, :@trigger)
        next unless trig == 1 || trig == 2
        list = PokeAccess.ivar(ev, :@list)
        next unless list.is_a?(Array)
        leaves = list.any? do |c|
          (c.code rescue 0) == 201 && (c.parameters[0] rescue 1) == 0 && (c.parameters[1] rescue key) != key
        end
        idx[pkey(ev.x, ev.y)] = (facing_guard(list) || true) if leaves
      end
      @exit_idx = idx
    rescue StandardError
      {}
    end

    # A route to a tile adjacent to the target. Prefers a pure walking/slide route (ledge hops are
    # awkward and often one-way for a blind player) and only allows ledge hops when no walking route exists.
    def self.find_path(tx, ty)
      # A one-way doorway is REACHED from the tile it is walked in from, and nowhere else: a route ending on its
      # other side leaves her pressing into a door that will not open.
      f = door_facing(tx, ty)
      if f
        dd = DELTA[f]
        ex = tx - dd[0]; ey = ty - dd[1]
        px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
        return [] if px == ex && py == ey
        return path_onto(ex, ey)
      end
      with_budget do
        with_bridge_state do
          px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
          far = (px - tx).abs + (py - ty).abs > FLOOD_MIN
          next nil if far && blocked_target?(tx, ty)
          find_path_to(tx, ty, false) || find_path_to(tx, ty, true) || (far ? flood_path(tx, ty) : nil)
        end
      end
    end

    # A breadth-first route over the same moves the flood uses, for a far target the flood KNOWS is reachable
    # but the A* gave up on: its node cap is sized for a keypress, and a winding hundred-tile channel through the
    # rocks of Stormy Seas exhausts it, so the guide said "no reachable route" to somewhere she could surf to.
    # Only runs when the complete flood contains the target, so it never pays for a search that must fail.
    FLOOD_PATH_MAX = 20000

    def self.flood_path(tx, ty)
      s = reachable_set
      return nil unless @rs_full && s && NEAR2.any? { |dx, dy| s[pkey(tx + dx, ty + dy)] }
      px = $game_player.x; py = $game_player.y
      b0 = bridge_state
      start = skey(px, py, b0)
      came = { start => nil }
      queue = [[px, py, b0]]; head = 0
      while head < queue.length && head < FLOOD_PATH_MAX
        cx, cy, cb = queue[head]; head += 1
        ck = skey(cx, cy, cb)
        if target_reached?(cx, cy, tx, ty)
          path = []
          while came[ck]
            pk, d = came[ck]
            path.unshift(d)
            ck = pk
          end
          return path
        end
        self.bridge_state = cb
        DIRS.each do |dir|
          nbr = move_target(cx, cy, dir, true, false)
          next if nbr.nil?
          nb = bridge_after(nbr[0], nbr[1], cb)
          nk = skey(nbr[0], nbr[1], nb)
          next if came.has_key?(nk)
          came[nk] = [ck, dir[2]]
          queue.push([nbr[0], nbr[1], nb])
        end
      end
      nil
    ensure
      (self.bridge_state = b0) if b0
    end

    # A route that only becomes walkable once a field-move obstacle has been cleared, as [steps, gates],
    # or nil when there is none (or when the plain route already exists -- ask find_path first).
    #
    # Deliberately a SEPARATE call from find_path rather than a fallback inside it. Whatever find_path
    # returns gets walked, so it may only ever return a route the player can walk this second; a route
    # through a tree that is still standing is the "walks a blind player into a wall" failure this module
    # refuses everywhere else. Only a caller with somewhere to put "needs Cut" asks for this one.
    # param allow_push runs the Strength-boulder search as well. Off for callers that ask about MANY
    # targets at once (the hide-unreachable filter): the push search is the expensive one here, and a
    # quarter of a second per target in a list rebuild is a stutter, where one per keypress is not.
    def self.find_path_gated(tx, ty, allow_push = true)
      return nil if (PokeAccess::Gates.empty? rescue true)
      with_budget do
        # Fast reject, as find_path does with its own flood: a far target the obstacle-free flood never reaches
        # has no gated route, and the A* would spend its whole node budget proving it -- twice, once per ledge
        # pass -- on EVERY question about a target across the water. Boulders are not set aside in that flood,
        # so a rejected target still gets the push search below.
        px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
        rejected = false
        if (px - tx).abs + (py - ty).abs > FLOOD_MIN
          c = region_flood(:walk_gated)
          rejected = c && c[4] && !NEAR2.any? { |dx, dy| c[3][pkey(tx + dx, ty + dy)] }
        end
        r = nil
        unless rejected
          r = PokeAccess::Gates.with_removed do
            with_bridge_state do
              p = find_path_to(tx, ty, false) || find_path_to(tx, ty, true)
              p.nil? ? nil : [p, (PokeAccess::Gates.crossed(p) rescue [])]
            end
          end
        end
        next r if r && !r[1].empty?
        # A route found with the trees taken down that crosses no tree is just the ordinary walking route,
        # which means the caller should have taken find_path's answer and there is nothing gated to report.
        # Returning here also keeps the push search off the hot path whenever a plain route exists at all.
        next nil if r
        next nil unless allow_push
        # Nothing a cut or a smash opens. The remaining possibility is a boulder that has to be shoved out
        # of the way, which is a different search because the rock does not vanish, it moves.
        pp = push_path(tx, ty)
        next nil if pp.nil?
        [pp, [[:strength, :push, nil, nil]]]
      end
    rescue StandardError
      nil
    end

    # The most shoves one route may contain. The search state is the player's tile plus the boulders that
    # have MOVED, so its size is the number of pushes made and not the number of rocks in the room -- which
    # is what makes a 35-boulder maze searchable at all. This caps how deep a puzzle it will try to solve.
    PUSH_LIMIT = 12

    # The push search's own node cap, well under the ordinary astar_max. It runs only when everything else
    # has already failed, it is the most expensive search here, and a measured 768ms of it on a map where
    # the answer turned out to be "no" is a stutter the player would feel on a single keypress. A deep
    # Sokoban room is declined rather than paid for.
    PUSH_MAX = 900

    # A route that includes shoving Strength boulders aside, as an ordinary list of step directions, or nil.
    #
    # It needs no new vocabulary. A push is a keypress that happens not to move her, so pressing east twice
    # at a boulder shoves it and then walks into the square it left -- and "2 east" is already exactly what
    # the guide says. What it DOES need is the boulders carried in the search state, since the same tile is
    # a wall before the shove and floor after. Every boulder is set non-blocking for the duration, so the
    # engine answers about terrain and other events only and boulder collisions come from the state.
    #
    # The state holds a DIFF -- only the rocks that have been moved -- rather than all their positions.
    # Insurgence's Ancient Tower has thirty-five boulders in one room; carrying all thirty-five in every
    # node would be hopeless, while carrying the two that were pushed is nothing.
    def self.push_path(tx, ty)
      bs = (PokeAccess::Gates.boulders rescue [])
      return nil if bs.empty?
      r = PokeAccess::Gates.with_boulders_through do
        PokeAccess::Gates.with_removed do
          with_bridge_state { push_search(tx, ty, bs) }
        end
      end
      # A "push route" that shoves nothing is the plain walking route wearing a hat. Saying it needs
      # Strength would send her off to find a move she does not need for it.
      (r && @push_count.to_i > 0) ? r : nil
    rescue StandardError
      nil
    end

    # The index of the boulder standing on (x,y) given a move-diff, or nil. O(pushes made), not O(boulders
    # in the room): a moved rock is found in the diff, an unmoved one in the map's own starting layout.
    def self.boulder_on(x, y, mv, orig_at)
      mv.each { |e| return e[0] if e[1] == x && e[2] == y }
      i = orig_at[pkey(x, y)]
      return nil if i.nil?
      mv.each { |e| return nil if e[0] == i }
      i
    end

    # The joint player-and-boulders A*. Bridge level is left at the player's own for the whole search: a
    # map with both a drawbridge and a boulder puzzle has not turned up, and guessing at the combination
    # would be a route nobody has walked.
    def self.push_search(tx, ty, bs)
      px = $game_player.x; py = $game_player.y
      return nil if (px - tx).abs + (py - ty).abs > reach
      evs = bs.map { |b| b[0] }
      orig_at = {}
      bs.each_with_index { |b, i| orig_at[pkey(b[1], b[2])] = i }
      startk = [px, py, []]
      g = { startk => 0 }
      came = {}; closed = {}; heap = []; iter = 0
      deadline = search_deadline
      heap_push(heap, [(px - tx).abs + (py - ty).abs, 0, px, py, 0, []])
      @push_stats = { :nodes => 0, :pushes => 0, :refused => 0, :walks => 0 }
      @push_count = 0
      until heap.empty?
        iter += 1
        break if iter > PUSH_MAX || over_budget?(iter, deadline)
        cur = heap_pop(heap)
        @push_stats[:nodes] += 1
        cx = cur[2]; cy = cur[3]; cmv = cur[5]
        ck = [cx, cy, cmv]
        next if closed[ck]
        closed[ck] = true
        return build_push_route(came, ck) if target_reached?(cx, cy, tx, ty)
        DIRS.each do |dir|
          dx = dir[0]; dy = dir[1]; d = dir[2]
          nx = cx + dx; ny = cy + dy
          bi = boulder_on(nx, ny, cmv, orig_at)
          if bi
            next if cmv.length >= PUSH_LIMIT
            occ = boulder_on(nx + dx, ny + dy, cmv, orig_at)
            next unless occ.nil?
            unless PokeAccess::Gates.boulder_can_move?(evs[bi], nx, ny, dx, dy, d, [])
              @push_stats[:refused] += 1
              next
            end
            @push_stats[:pushes] += 1
            nmv = (cmv.reject { |e| e[0] == bi } + [[bi, nx + dx, ny + dy]]).sort
            npx = cx; npy = cy                      # the shove leaves the player where she stands
            shove = true
          else
            t = move_target(cx, cy, dir, false, false)
            next if t.nil?
            npx = t[0]; npy = t[1]
            next if boulder_on(npx, npy, cmv, orig_at)
            @push_stats[:walks] += 1
            nmv = cmv
            shove = false
          end
          nk = [npx, npy, nmv]
          next if closed[nk]
          ng = g[ck] + 1
          if g[nk].nil? || ng < g[nk]
            g[nk] = ng
            came[nk] = [ck, d, shove]
            heap_push(heap, [ng + (npx - tx).abs + (npy - ty).abs, 0, npx, npy, d, nmv])
          end
        end
      end
      nil
    end

    # Counters from the last push search, for the diagnostics.
    def self.push_stats; @push_stats; end

    # Walks the push search's came-from chain back. Keyed by the whole state (player AND the rocks that
    # have moved) rather than by tile: the same square is stood on with the room in different shapes.
    def self.build_push_route(came, k)
      path = []; pushes = 0
      while came[k]
        c = came[k]
        path.unshift(c[1])
        pushes += 1 if c[2]
        k = c[0]
      end
      @push_count = pushes
      path
    end

    # How many shoves the last push route contained.
    def self.push_count; @push_count.to_i; end

    # Offsets within manhattan distance 2 of a tile (matches find_path_to's "get within 2" partial route).
    NEAR2 = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1],
             [2, 0], [-2, 0], [0, 2], [0, -2], [1, 1], [1, -1], [-1, 1], [-1, -1]]

    # Fast reject for a clearly unreachable target, so the guide does not run a full A* every refresh
    # while pointing somewhere unwalkable (a 1 fps freeze a tester hit). Uses the cached flood;
    # conservative: never rejects when edge-relax is on or the flood is truncated/unavailable.
    def self.blocked_target?(tx, ty)
      return false if (PokeAccess::Config.edge_relax rescue false)
      s = reachable_set
      return false if s.nil? || s.empty?
      return false unless @rs_full
      !NEAR2.any? { |dx, dy| s[pkey(tx + dx, ty + dy)] }
    rescue StandardError
      false
    end

    # The search algorithms the route key can choose; all share the neighbour expansion and turn
    # tiebreak and differ only in the frontier.
    ALGORITHMS = [:astar, :weighted, :greedy, :dijkstra, :bfs, :dfs, :jps, :hpa]

    # The search algorithm from config (default :astar; an unknown value falls back to it).
    def self.path_algorithm
      a = (PokeAccess::Config.path_algorithm rescue nil)
      a = a.to_sym if a.respond_to?(:to_sym)
      ALGORITHMS.include?(a) ? a : :astar
    end

    # The [g-weight, h-weight] of a heap algorithm's priority f = gw*g + hw*h: astar weights both equally,
    # weighted leans on the heuristic, greedy drops g, dijkstra drops h. Unused for bfs/dfs (queue-ordered).
    # The weights are DOUBLED ([2,2] rather than [1,1]) so weighted's [2,3] expresses 1.5x the heuristic in
    # pure integers -- do not "simplify" to [1,1]/[1,1.5]: a float weight would break the integer ordering.
    def self.algo_weights(algo)
      case algo
      when :weighted then [2, 3]
      when :greedy   then [0, 2]
      when :dijkstra then [2, 0]
      else [2, 2]
      end
    end

    # True if a tile is on the outer border of the map (where connection/exit tiles live).
    def self.border_tile?(x, y)
      return false unless $game_map
      x <= 0 || y <= 0 || x >= $game_map.width - 1 || y >= $game_map.height - 1
    rescue StandardError
      false
    end

    # The arrival test every search shares: a route succeeds once it stands ON the target or ORTHOGONALLY
    # ADJACENT to it, since the typical target (an NPC, sign or item) occupies a tile the player cannot enter.
    # A*, JPS and HPA* all end on this same criterion so none demands entering an unwalkable goal tile.
    def self.target_reached?(x, y, tx, ty); (x - tx).abs + (y - ty).abs <= 1; end

    # Orders two frontier nodes [f, turns, ...] by priority f, then by fewer turns.
    def self.heap_less(a, b); a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]); end

    # Pushes a node onto the binary min-heap and sifts it up.
    def self.heap_push(heap, item)
      heap.push(item); i = heap.size - 1
      while i > 0
        p = (i - 1) / 2
        break if heap_less(heap[p], heap[i])
        heap[p], heap[i] = heap[i], heap[p]; i = p
      end
    end

    # Pops the smallest node off the binary min-heap and sifts the hole down.
    def self.heap_pop(heap)
      top = heap[0]; last = heap.pop
      unless heap.empty?
        heap[0] = last; i = 0; n = heap.size
        loop do
          l = 2 * i + 1; r = 2 * i + 2; s = i
          s = l if l < n && heap_less(heap[l], heap[s])
          s = r if r < n && heap_less(heap[r], heap[s])
          break if s == i
          heap[i], heap[s] = heap[s], heap[i]; i = s
        end
      end
      top
    end

    # Walks a came-from chain keyed by TILE, for the searches that run on one flat level (HPA*'s low-level
    # A*, which only ever runs on a map with no bridge ramp).
    def self.build_route_flat(came, k)
      path = []
      while came[k]; p = came[k]; path.unshift(p[2]); k = pkey(p[0], p[1]); end
      path
    end

    # Walks the came-from chain back from a search-state key to the start, returning the step directions.
    # Chains on the state key, not the tile: on a bridge map the same tile appears twice, once per level,
    # and following the tile alone would splice two different walks together.
    def self.build_route(came, k)
      path = []
      while came[k]; p = came[k]; path.unshift(p[3]); k = skey(p[0], p[1], p[2]); end
      path
    end

    # Resolves a step from (cx,cy) in a direction to the neighbour the search may enter, or nil when blocked.
    # A ledge tile is never a standable node -- crossing it is only ever the two-tile hop, gated by
    # allow_ledge -- so it is caught before the passability test: v21/v22 and the gen-6 games make a ledge
    # PASSABLE from the high side and decide the jump inside their own "can move" branch, where a plain
    # passability check would walk into it as a dead end. Then a normal passable step (ice tiles ride their
    # slide), else (edge_relax) a passable border tile, else the ledge hop for an engine whose ledge reads
    # impassable. Both ledge paths go through ledge_jump, so both honour the ledge_directions setting.
    def self.step_target(cx, cy, dir, allow_ledge, edge_relax)
      dx, dy, d = dir
      nx = cx + dx; ny = cy + dy
      if (PokeAccess::Terrain.ledge_at?(nx, ny) rescue false)
        return allow_ledge ? ledge_jump(cx, cy, dx, dy, d) : nil
      end
      if passable_at?(cx, cy, d)
        return ice_slide(nx, ny, dx, dy, d) if PokeAccess::Terrain.ice_at?(nx, ny)
        return [nx, ny]
      end
      return [nx, ny] if edge_relax && border_tile?(nx, ny) && ($game_map.passable?(nx, ny, 0) rescue false)
      allow_ledge ? ledge_jump(cx, cy, dx, dy, d) : nil
    end

    # Follows an ice slide from (x,y): on ice the player keeps sliding the same way until the tile is no
    # longer ice or the next step is blocked, so the search lands where the slide stops (one key press
    # carries the player across the run). The entry tile is a validated passable ice tile; guarded against a loop.
    def self.ice_slide(x, y, dx, dy, d)
      guard = 0
      while PokeAccess::Terrain.ice_at?(x, y) && guard < 200
        guard += 1
        break unless passable_at?(x, y, d)
        x += dx; y += dy
      end
      [x, y]
    end

    # The search. allow_ledge enables ledge hops (used only by the second pass). Heap algorithms compare
    # f = gw*g + hw*h; bfs/dfs use a plain queue/stack; ties break toward fewer turns; passability is the
    # game's own, so it never routes through walls; edge tolerance optionally relaxes the map border.
    def self.find_path_to(tx, ty, allow_ledge)
      px = $game_player.x; py = $game_player.y
      return nil if (px - tx).abs + (py - ty).abs > reach
      straight = (PokeAccess::Config.straight_routes rescue false)
      edge_relax = (PokeAccess::Config.edge_relax rescue false)
      algo = path_algorithm
      # JPS and HPA* both assume one uniform grid, and a map with a bridge ramp has two overlaid. Neither
      # knows the level can change under it, so on such a map they fall through to the A* below, which does.
      if !allow_ledge && (algo == :jps || algo == :hpa) && bridge_index.empty?
        sr = (algo == :jps) ? jps_search(tx, ty) : hpa_search(tx, ty)
        return sr if sr.is_a?(Array)
      end
      gw, hw = algo_weights(algo)
      heaped = algo != :bfs && algo != :dfs
      heap = []; queue = []
      push = heaped ? lambda { |item| heap_push(heap, item) } : lambda { |item| queue.push(item) }
      pop = heaped ? lambda { heap_pop(heap) } : (algo == :dfs ? lambda { queue.pop } : lambda { queue.shift })
      empty = heaped ? lambda { heap.empty? } : lambda { queue.empty? }
      b0 = bridge_state
      start = skey(px, py, b0)
      g = { start => 0 }
      turns = { start => 0 }
      came = {}; closed = {}; iter = 0
      deadline = search_deadline
      bestk = start; bestd = (px - tx).abs + (py - ty).abs
      push.call([hw * ((px - tx).abs + (py - ty).abs), 0, px, py, 0, b0])
      until empty.call
        iter += 1
        break if over_budget?(iter, deadline)
        cur = pop.call
        cx = cur[2]; cy = cur[3]; cd = cur[4]; cb = cur[5]
        ck = skey(cx, cy, cb)
        next if closed[ck]
        closed[ck] = true
        # Passability is asked of the engine, so the engine has to be looking at the same level this node
        # is on before any of its neighbours are tested.
        self.bridge_state = cb
        md = (cx - tx).abs + (cy - ty).abs
        if md < bestd; bestd = md; bestk = ck; end
        return build_route(came, ck) if target_reached?(cx, cy, tx, ty)
        DIRS.each do |dir|
          d = dir[2]
          nbr = move_target(cx, cy, dir, allow_ledge, edge_relax)
          next if nbr.nil?
          nx, ny = nbr
          nb = bridge_after(nx, ny, cb)
          nk = skey(nx, ny, nb)
          next if closed[nk]
          turned = (cd != 0 && cd != d)
          ng = g[ck] + 1 + ((straight && turned) ? 1 : 0)
          nturns = turns[ck] + (turned ? 1 : 0)
          better = heaped ? (g[nk].nil? || ng < g[nk] || (ng == g[nk] && nturns < turns[nk])) : g[nk].nil?
          if better
            g[nk] = ng; turns[nk] = nturns; came[nk] = [cx, cy, cb, d]
            push.call([gw * ng + hw * ((nx - tx).abs + (ny - ty).abs), nturns, nx, ny, d, nb])
          end
        end
      end
      return build_route(came, bestk) if bestd <= 2 && bestk != start
      nil
    ensure
      (self.bridge_state = b0) if b0
    end

    # Jump point search: an A* whose successors are "jump points" (the next turning/goal tile in a
    # direction), so long straight corridors cost one expansion. Optimal on a uniform 4-connected grid;
    # ice/slide tiles break that, so it sets @jps_fallback and the caller drops to plain A*. A ledge does the
    # same for the same reason: the engine leaves it PASSABLE from the high side and the real step covers two
    # tiles, so on JPS's uniform grid it is crossed like flat ground -- the guide cane walks the blind player
    # over a one-way jump unannounced and the step counter lies. It exits through :fallback to the usual A*,
    # which does know how to jump it. Returns the route, nil (out of reach), or :fallback.
    def self.jps_search(tx, ty)
      px = $game_player.x; py = $game_player.y
      return nil if (px - tx).abs + (py - ty).abs > reach
      @jps_tx = tx; @jps_ty = ty; @jps_fallback = false
      @jps_steps = 0; @jps_budget = [(PokeAccess::Config.astar_max rescue 2500).to_i * 8, 20000].max
      heap = []; g = { pkey(px, py) => 0 }; came = {}; closed = {}; iter = 0
      deadline = search_deadline
      bestk = pkey(px, py); bestd = (px - tx).abs + (py - ty).abs
      heap_push(heap, [bestd, 0, px, py, 0])
      until heap.empty?
        iter += 1
        return :fallback if @jps_fallback
        break if over_budget?(iter, deadline)
        cur = heap_pop(heap); cx = cur[2]; cy = cur[3]; ck = pkey(cx, cy)
        next if closed[ck]
        closed[ck] = true
        md = (cx - tx).abs + (cy - ty).abs
        if md < bestd; bestd = md; bestk = ck; end
        return jps_route(came, ck) if target_reached?(cx, cy, tx, ty)
        DIRS.each do |dir|
          dx = dir[0]; dy = dir[1]; d = dir[2]
          jp = jps_jump(cx, cy, dx, dy, d)
          return :fallback if @jps_fallback
          next if jp.nil?
          jx = jp[0]; jy = jp[1]; jk = pkey(jx, jy)
          next if closed[jk]
          ng = g[ck] + (jx - cx).abs + (jy - cy).abs
          if g[jk].nil? || ng < g[jk]
            g[jk] = ng; came[jk] = [cx, cy, d, jx, jy]
            heap_push(heap, [ng + (jx - tx).abs + (jy - ty).abs, 0, jx, jy, d])
          end
        end
      end
      return :fallback if @jps_fallback
      return jps_route(came, bestk) if bestd <= 2 && bestk != pkey(px, py)
      nil
    end

    # Scans from (x,y) in one direction for the next jump point: the goal-adjacent tile, a tile with a
    # forced neighbour, or (4-connected completeness) a tile from which a perpendicular scan reaches a
    # jump point. Returns [x,y] or nil (a wall/ledge ends the scan). Ice/slide tiles, an exceeded step
    # budget, or recursion past the depth cap all set @jps_fallback so the caller reverts to plain A*.
    def self.jps_jump(x, y, dx, dy, d, depth = 0)
      if depth > 80
        @jps_fallback = true; return nil
      end
      loop do
        @jps_steps += 1
        if @jps_steps > @jps_budget
          @jps_fallback = true; return nil
        end
        unless passable_at?(x, y, d)
          # A wall that is really a staircase: the bump carries the player on, and JPS's uniform grid
          # cannot express that, so hand the whole search to the A* that can.
          @jps_fallback = true if forced_move_at(x + dx, y + dy, d)
          return nil
        end
        nx = x + dx; ny = y + dy
        if (PokeAccess::Terrain.ice_at?(nx, ny) rescue false) || slide_index[pkey(nx, ny)] ||
           warp_index[pkey(nx, ny)] || (PokeAccess::Terrain.ledge_at?(nx, ny) rescue false)
          @jps_fallback = true; return nil
        end
        return [nx, ny] if target_reached?(nx, ny, @jps_tx, @jps_ty)
        perps = (dx != 0) ? [8, 2] : [4, 6]
        return [nx, ny] if perps.any? { |p| !passable_at?(x, y, p) && passable_at?(nx, ny, p) }
        if dx != 0
          return [nx, ny] if !jps_jump(nx, ny, 0, -1, 8, depth + 1).nil? || !jps_jump(nx, ny, 0, 1, 2, depth + 1).nil?
        else
          return [nx, ny] if !jps_jump(nx, ny, -1, 0, 4, depth + 1).nil? || !jps_jump(nx, ny, 1, 0, 6, depth + 1).nil?
        end
        return nil if @jps_fallback
        x = nx; y = ny
      end
    end

    # Rebuilds the step route from a JPS came-from chain, expanding each jump back into individual tile
    # steps (a jump of n tiles in direction d becomes d repeated n times).
    def self.jps_route(came, k)
      path = []
      while (c = came[k])
        cx = c[0]; cy = c[1]; d = c[2]; jx = c[3]; jy = c[4]
        ((jx - cx).abs + (jy - cy).abs).times { path.unshift(d) }
        k = pkey(cx, cy)
      end
      path
    end

    # Hierarchical pathfinding (HPA*). The side length, in tiles, of a cluster: the map is tiled into
    # squares this big, portals cut at the openings between neighbours, and the abstract graph routes
    # cluster-to-cluster.
    HPA_CLUSTER = 10

    # Bounded low-level A* between two EXACT tiles, within an optional [x0,y0,x1,y1] box and node cap;
    # returns [step-directions, cost] or nil. Ice/slide tiles are treated as walls, so any path needing
    # them fails here and the caller reverts to plain A*. Weights abstract edges and refines abstract hops.
    # A ledge is discarded as a tile, like ice and the sliders: crossing it is a two-tile jump in one direction
    # and here it would count as an ordinary step both ways. With no local route the abstract hop is not
    # refined, and hpa_search returns :fallback to the usual A*, which does know how to jump it.
    def self.hpa_low(sx, sy, gx, gy, maxnodes, x0 = nil, y0 = nil, x1 = nil, y1 = nil)
      return [[], 0] if sx == gx && sy == gy
      heap = []; g = { pkey(sx, sy) => 0 }; came = {}; closed = {}; iter = 0
      heap_push(heap, [(sx - gx).abs + (sy - gy).abs, 0, sx, sy, 0])
      until heap.empty?
        iter += 1
        return nil if iter > maxnodes
        cur = heap_pop(heap); cx = cur[2]; cy = cur[3]; ck = pkey(cx, cy)
        next if closed[ck]
        closed[ck] = true
        return [build_route_flat(came, ck), g[ck]] if cx == gx && cy == gy
        DIRS.each do |dir|
          dx = dir[0]; dy = dir[1]; d = dir[2]
          next unless passable_at?(cx, cy, d)
          nx = cx + dx; ny = cy + dy
          next if x0 && (nx < x0 || ny < y0 || nx > x1 || ny > y1)
          next if (PokeAccess::Terrain.ice_at?(nx, ny) rescue false) || slide_index[pkey(nx, ny)] ||
                  warp_index[pkey(nx, ny)] || (PokeAccess::Terrain.ledge_at?(nx, ny) rescue false)
          nk = pkey(nx, ny)
          next if closed[nk]
          ng = g[ck] + 1
          if g[nk].nil? || ng < g[nk]
            g[nk] = ng; came[nk] = [cx, cy, d]
            heap_push(heap, [ng + (nx - gx).abs + (ny - gy).abs, 0, nx, ny, d])
          end
        end
      end
      nil
    end

    # The abstract graph for the current map: portal nodes at the openings between adjacent clusters,
    # with inter-cluster edges (cost 1) and intra-cluster edges (a bounded local A* per portal pair).
    # Cached per [map, surfing, diving]. Returns the graph hash or nil.
    def self.hpa_graph
      sig = [($game_map.map_id rescue 0), ($PokemonGlobal.surfing rescue false), ($PokemonGlobal.diving rescue false)]
      return @hpa if @hpa_sig == sig && @hpa
      @hpa_sig = sig; @hpa = nil
      w = ($game_map.width rescue 0); h = ($game_map.height rescue 0)
      return nil if w < 2 || h < 2
      c = HPA_CLUSTER
      adj = {}
      byc = {}
      addnode = lambda do |x, y|
        k = pkey(x, y); cid = (x / c) * PKEY_STRIDE + (y / c)
        lst = (byc[cid] ||= [])
        lst << k unless lst.include?(k)
        k
      end
      link = lambda { |a, b, cost| (adj[a] ||= []) << [b, cost]; (adj[b] ||= []) << [a, cost] }
      bx = c - 1
      while bx < w - 1
        cr = 0
        while cr * c < h
          ylo = cr * c; yhi = [cr * c + c - 1, h - 1].min; by = ylo
          while by <= yhi
            if passable_at?(bx, by, 6)
              run0 = by; by += 1
              by += 1 while by <= yhi && passable_at?(bx, by, 6)
              my = (run0 + by - 1) / 2
              link.call(addnode.call(bx, my), addnode.call(bx + 1, my), 1)
            else
              by += 1
            end
          end
          cr += 1
        end
        bx += c
      end
      by = c - 1
      while by < h - 1
        cc = 0
        while cc * c < w
          xlo = cc * c; xhi = [cc * c + c - 1, w - 1].min; bx = xlo
          while bx <= xhi
            if passable_at?(bx, by, 2)
              run0 = bx; bx += 1
              bx += 1 while bx <= xhi && passable_at?(bx, by, 2)
              mx = (run0 + bx - 1) / 2
              link.call(addnode.call(mx, by), addnode.call(mx, by + 1), 1)
            else
              bx += 1
            end
          end
          cc += 1
        end
        by += c
      end
      byc.each do |cid, nlist|
        cc = cid / PKEY_STRIDE; cr = cid % PKEY_STRIDE
        box = [cc * c, cr * c, [cc * c + c - 1, w - 1].min, [cr * c + c - 1, h - 1].min]
        i = 0
        while i < nlist.length
          j = i + 1
          while j < nlist.length
            a = nlist[i]; b = nlist[j]
            r = hpa_low(a / PKEY_STRIDE, a % PKEY_STRIDE, b / PKEY_STRIDE, b % PKEY_STRIDE, c * c * 2, box[0], box[1], box[2], box[3])
            link.call(a, b, r[1]) if r
            j += 1
          end
          i += 1
        end
      end
      @hpa = { :adj => adj, :byc => byc, :c => c, :w => w, :h => h }
    rescue StandardError
      @hpa = nil
    end

    # The bounding box of the two clusters containing a and b, clamped to the map, so the refining A* for
    # an abstract hop stays local.
    def self.pair_box(ax, ay, bx, by, c, w, h)
      [[(ax / c) * c, (bx / c) * c].min, [(ay / c) * c, (by / c) * c].min,
       [[(ax / c) * c + c - 1, (bx / c) * c + c - 1].max, w - 1].min,
       [[(ay / c) * c + c - 1, (by / c) * c + c - 1].max, h - 1].min]
    end

    # The tiles at which an HPA* route may ARRIVE: the target itself plus its orthogonal neighbours, kept
    # only when a tile is standable (some neighbour can step INTO it, the same passable_at? the search uses).
    # This is the graph-side form of target_reached?: a solid target (NPC/sign/item) drops out and its
    # walkable neighbours remain, so the hierarchy routes adjacent instead of demanding the unenterable tile.
    def self.hpa_arrivals(tx, ty)
      cells = [[tx, ty]]
      DIRS.each { |dx, dy, _d| cells << [tx + dx, ty + dy] }
      cells.select do |cx, cy|
        next false unless ($game_map.valid?(cx, cy) rescue false)
        DIRS.any? { |dx, dy, d| passable_at?(cx - dx, cy - dy, d) }
      end
    end

    # The abstract search's synthetic goal sink: a sentinel key no real tile can pack to (packed tiles are
    # non-negative), linked at zero cost from every arrival tile so A* selects the cheapest one to reach.
    HPA_SINK = -1

    # Hierarchical search: connect start and every arrival tile (target or a walkable neighbour) to their
    # clusters' portals, A* over the abstract graph to a synthetic sink linked from each arrival, then refine
    # each real abstract hop back into tile steps with a live local A*. Because every hop is re-solved against
    # current passability, a stale cached graph can only cause :fallback, never a wrong route. Returns the
    # route, nil (out of reach), :fallback (use plain A*), or [] (already adjacent). Neighbour lists are merged
    # with dup.concat, never Array#+: a fangame script patch redefines Array#+ as an in-place mutator (seen
    # in the wild) that would leak the temporary edges into the cached graph.
    def self.hpa_search(tx, ty)
      px = $game_player.x; py = $game_player.y
      return nil if (px - tx).abs + (py - ty).abs > reach
      return [] if target_reached?(px, py, tx, ty)
      gr = hpa_graph
      return :fallback unless gr
      c = gr[:c]; w = gr[:w]; h = gr[:h]; adj = gr[:adj]; byc = gr[:byc]
      start = pkey(px, py)
      arrivals = hpa_arrivals(tx, ty)
      return :fallback if arrivals.empty?
      temp = Hash.new { |hh, k| hh[k] = [] }
      connect = lambda do |sx, sy, sk|
        box = [(sx / c) * c, (sy / c) * c, [(sx / c) * c + c - 1, w - 1].min, [(sy / c) * c + c - 1, h - 1].min]
        (byc[(sx / c) * PKEY_STRIDE + (sy / c)] || []).each do |nk|
          r = hpa_low(sx, sy, nk / PKEY_STRIDE, nk % PKEY_STRIDE, c * c * 2, box[0], box[1], box[2], box[3])
          (temp[sk] << [nk, r[1]]; temp[nk] << [sk, r[1]]) if r
        end
      end
      connect.call(px, py, start)
      arrivals.each do |ax, ay|
        ak = pkey(ax, ay)
        connect.call(ax, ay, ak)
        temp[ak] << [HPA_SINK, 0]
        if (px / c) == (ax / c) && (py / c) == (ay / c)
          box = [(px / c) * c, (py / c) * c, [(px / c) * c + c - 1, w - 1].min, [(py / c) * c + c - 1, h - 1].min]
          r = hpa_low(px, py, ax, ay, c * c * 2, box[0], box[1], box[2], box[3])
          temp[start] << [ak, r[1]] if r
        end
      end
      openh = []; gg = { start => 0 }; cf = {}; cl = {}; it = 0
      deadline = search_deadline
      heap_push(openh, [(px - tx).abs + (py - ty).abs, 0, start])
      found = false
      until openh.empty?
        it += 1
        break if it > 20000 || (deadline && over_budget?(it, deadline))
        n = heap_pop(openh)[2]
        next if cl[n]
        cl[n] = true
        if n == HPA_SINK; found = true; break; end
        (adj[n] || []).dup.concat(temp[n]).each do |e|
          m = e[0]; ng = gg[n] + e[1]
          if gg[m].nil? || ng < gg[m]
            gg[m] = ng; cf[m] = n
            hh = (m == HPA_SINK) ? 0 : (m / PKEY_STRIDE - tx).abs + (m % PKEY_STRIDE - ty).abs
            heap_push(openh, [ng + hh, 0, m])
          end
        end
      end
      return :fallback unless found
      seq = []; k = cf[HPA_SINK]
      while k; seq.unshift(k); k = cf[k]; end
      return [] if seq.length <= 1
      route = []; i = 0
      while i < seq.length - 1
        a = seq[i]; b = seq[i + 1]
        ax = a / PKEY_STRIDE; ay = a % PKEY_STRIDE; bx = b / PKEY_STRIDE; by = b % PKEY_STRIDE
        box = pair_box(ax, ay, bx, by, c, w, h)
        r = hpa_low(ax, ay, bx, by, (box[2] - box[0] + 1) * (box[3] - box[1] + 1) * 2 + 8, box[0], box[1], box[2], box[3])
        return :fallback unless r
        route.concat(r[0]); i += 1
      end
      route.empty? ? :fallback : route
    rescue StandardError
      :fallback
    end

    # Every tile the player can walk to from here, as a pkey => true set, via one BFS flood using
    # find_path's passability. Replaces a full A* per target for the hide-unreachable filter (which made
    # changing category take seconds on big maps). Bounded to the find_path range and a hard node cap.
    # allow_water additionally crosses surfable water (see surf_step), for the surf-reachability test.
    # Walkable tiles from a tile that is NOT the player's, on the map she is standing on. The warp router
    # needs it: after the first door it is asking "and from where that one lands, which doors can be
    # reached", and that landing spot is somewhere else on this same map. Cached per tile.
    # A budget for a search that is NOT on the keypress path: the cross-map warp search runs once per
    # question and caches its answer, so cutting its floods off after 8 ms only makes it wrong.
    LONG_BUDGET_MS = 400

    def self.with_long_budget
      outer = @budget_until
      @budget_until = (PokeAccess.clock rescue 0.0) + (LONG_BUDGET_MS / 1000.0)
      yield
    ensure
      @budget_until = outer
    end

    def self.reachable_from(x, y)
      saved = @rs_full
      k = [x, y, ($game_map.map_id rescue 0)]
      @rf_cache = {} if @rf_cache.nil? || @rf_map != ($game_map.map_id rescue 0)
      @rf_map = ($game_map.map_id rescue 0)
      return @rf_cache[k] if @rf_cache.has_key?(k)
      set = with_long_budget { with_bridge_state { reachable_tiles(false, x, y) } }
      full = @rs_full
      # @rs_full belongs to the PLAYER's flood; this second one must hand it back untouched or
      # reachable_set_complete? starts answering for the wrong search. Same trap as the surf sweep.
      @rs_full = saved
      # A TRUNCATED region answers nil, not a short list. The warp router reads absence from this set as
      # "that door cannot be used", and a flood that merely ran out of budget would make it invent walls.
      @rf_cache[k] = (full ? set : nil)
    rescue StandardError
      @rs_full = saved
      nil
    end

    def self.reachable_tiles(allow_water = false, from_x = nil, from_y = nil)
      set = {}
      return set unless $game_player && $game_map
      px = from_x || $game_player.x; py = from_y || $game_player.y
      set[pkey(px, py)] = true
      b0 = bridge_state
      seen = { skey(px, py, b0) => true }
      # With water allowed, each tile's value records HOW it was first reached: true on foot (or on the
      # water she is already on), else [x, y, dir] -- the shore tile and facing of the FIRST launch on the way
      # there. Still truthy, so every "is it in the set" consumer is unaffected. See surf_plan.
      queue = [[px, py, b0, true]]; head = 0; iter = 0
      rch = reach
      deadline = search_deadline
      @rs_full = true
      while head < queue.length
        iter += 1
        if iter > 10000 || (deadline && over_budget?(iter, deadline)); @rs_full = false; break; end
        cur = queue[head]; head += 1
        cx = cur[0]; cy = cur[1]; cb = cur[2]; ctag = cur[3]
        # Ask the engine about the level this node is on, not the one the player happens to be standing on.
        self.bridge_state = cb
        afloat = allow_water || ($PokemonGlobal.surfing rescue false)
        cwet = allow_water && surfable_cached?(cx, cy)
        DIRS.each do |dir|
          nbr = afloat ? open_water_step(cx, cy, dir) : nil
          next if nbr == :blocked
          nbr = move_target(cx, cy, dir, true, false) if nbr.nil?
          nbr = surf_step(cx, cy, dir) if nbr.nil? && allow_water
          next if nbr.nil?
          nx, ny = nbr
          next if (nx - px).abs + (ny - py).abs > rch
          nb = bridge_after(nx, ny, cb)
          sk = seen[skey(nx, ny, nb)]
          next if sk
          seen[skey(nx, ny, nb)] = true
          tag = ctag
          if allow_water && ctag == true && !cwet && surfable_cached?(nx, ny)
            tag = [cx, cy, dir[2]]
          end
          # The SET is tiles, not states: every consumer of it is asking "can the player get there", and
          # a tile reachable on either level is reachable. First arrival wins, and the flood is breadth-first,
          # so a tile's launch is the one on the shortest way there.
          k = pkey(nx, ny)
          set[k] = tag unless set[k]
          queue.push([nx, ny, nb, tag])
        end
      end
      set
    ensure
      (self.bridge_state = b0) if b0
    end

    # The reachable-tiles set, cached per player tile so the flood runs once per move and is shared by the
    # locator's hide-unreachable filter and the positional audio's line-of-sight test.
    def self.reachable_set
      key = [($game_player.x rescue 0), ($game_player.y rescue 0), ($game_map.map_id rescue 0)]
      if @rs_key != key
        @rs_key = key
        @rs = with_bridge_state { reachable_tiles }
      end
      @rs
    rescue StandardError
      {}
    end

    # Whether the last flood ran to completion. A flood that hit the node cap or the frame budget covers
    # only part of the map, so absence from it is not evidence of unreachability -- every consumer that
    # would HIDE something has to ask this first.
    def self.reachable_set_complete?
      reachable_set
      @rs_full ? true : false
    rescue StandardError
      false
    end

    # True if any tile orthogonally adjacent to (x,y) is surfable water (a shore tile).
    def self.beside_surfable?(x, y)
      DIRS.any? { |d| surfable_cached?(x + d[0], y + d[1]) }
    rescue StandardError
      false
    end

    # The directions surfing can actually be STARTED in from (x,y): water that way, and the game willing to
    # launch (Gates.surf_launch_ok?). Empty for a tile that merely touches water.
    def self.launch_dirs(x, y)
      DIRS.select { |d| surfable_cached?(x + d[0], y + d[1]) && PokeAccess::Gates.surf_launch_ok?(x, y, d[2]) }.map { |d| d[2] }
    rescue StandardError
      []
    end

    # One step of the surf flood, for a move the walking flood refused: onto surfable water, or off water
    # onto land. Launching from dry land counts only where the game would really start surfing, and landing
    # only where the router afloat would really come ashore (landing_from_water?) -- so the flood and the
    # route agree, and "across the water" is never claimed from a shore nobody can push off from.
    def self.surf_step(cx, cy, dir)
      nx = cx + dir[0]; ny = cy + dir[1]
      return nil unless ($game_map.valid?(nx, ny) rescue false)
      return nil if exit_tile?(nx, ny, dir[2])
      wet = surfable_cached?(cx, cy)
      if surfable_cached?(nx, ny)
        return [nx, ny] if wet || PokeAccess::Gates.surf_launch_ok?(cx, cy, dir[2])
        return nil
      end
      return nil unless wet
      return nil if afloat_tile_open?(cx, cy, dir[2]) == false
      landing_from_water?(nx, ny, dir[2]) ? [nx, ny] : nil
    rescue StandardError
      nil
    end

    # A water-to-water step of the surf flood, answered without the engine: open water joins open water, and
    # asking Game_Player#passable? about each of a sea's tiles (a wall, every time, to someone on foot) was
    # most of the flood's cost. Declines -- nil, so the caller asks move_target as before -- wherever the
    # map does something to a step: a forced move or a warp on the far tile.
    def self.open_water_step(cx, cy, dir)
      nx = cx + dir[0]; ny = cy + dir[1]
      return nil unless surfable_cached?(cx, cy) && surfable_cached?(nx, ny)
      return nil unless ($game_map.valid?(nx, ny) rescue false)
      return nil if forced_move_at(nx, ny, dir[2]) || warp_index[pkey(nx, ny)]
      # An exit strip on the water (Stormy Seas' lane back to Miara) is a way OUT, not open sea. Skipping it
      # here while move_target refused it made the flood leak through into water the router could not reach.
      return :blocked if exit_tile?(nx, ny, dir[2])
      # Blocked afloat too (a bridge support): not a step at all. Asked here rather than left to move_target,
      # whose engine answer for far water is always "wall" and would let surf_step wave it through.
      return :blocked if afloat_tile_open?(cx, cy, dir[2]) == false || afloat_tile_open?(nx, ny, 10 - dir[2]) == false
      [nx, ny]
    rescue StandardError
      nil
    end

    # How far she may walk before a cached surf flood is thrown away. The flood is bounded by the route reach
    # around where it was STARTED, so it is only reused near there.
    SRS_DRIFT = 8

    # The tiles reachable when surfable water counts as walkable: the walking flood again, with water
    # crossable. Built only when a target has no walking route, so maps whose targets all route on foot never
    # pay for it. @rs_full is saved and restored: that flag belongs to the WALKING flood, and
    # reachable_set_complete? must not start answering for this one.
    #
    # Cached by REGION, not by tile: a tile inside the last flood, a few steps from where it started, floods
    # to the same set. Keyed per tile it re-ran on every step, and on a map that is mostly sea that was a
    # two-second freeze each time she moved and asked where something was.
    #
    # param gated also opens the field-move obstacles (a climbable face or a cuttable tree on the far shore),
    # for the question "could surfing get there once something past the water is dealt with".
    def self.surf_reachable_set(gated = false)
      gated = false if gated && (PokeAccess::Gates.empty? rescue true)
      c = region_flood(gated ? :surf_gated : :surf)
      c ? c[3] : {}
    rescue StandardError
      {}
    end

    # A flood cached by region, as [signature, origin x, origin y, set, complete?], or nil.
    #   :surf        walking plus surfable water
    #   :surf_gated  the same with the field-move obstacles set aside
    #   :walk_gated  walking with the obstacles set aside (the gated route's fast reject)
    # Reusing one from a nearby tile inside it is safe by transitivity: anything reachable from where she
    # stands now was reachable from where the flood started, so the old set can only be LARGER than a fresh
    # one -- never missing a tile -- apart from the reach bound, which the drift limit keeps negligible.
    def self.region_flood(kind)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      sig = [($game_map.map_id rescue 0), ($PokemonGlobal.surfing rescue false), bridge_state > 0]
      @srs_cache ||= {}
      c = @srs_cache[kind]
      # Her tile must have been reached WITHOUT a launch (value true): a flood from the near bank is not the
      # answer from the far one, and its launch records would send her back across the water.
      if c && c[0] == sig && c[3][pkey(px, py)] == true && (px - c[1]).abs + (py - c[2]).abs <= SRS_DRIFT
        return c
      end
      full = @rs_full
      set = {}; complete = false
      begin
        set = with_bridge_state do
          case kind
          when :surf then reachable_tiles(true)
          when :surf_gated then PokeAccess::Gates.with_removed { reachable_tiles(true) }
          else PokeAccess::Gates.with_removed { reachable_tiles(false) }
          end
        end
        complete = @rs_full ? true : false
      ensure
        @rs_full = full
      end
      @srs_cache[kind] = [sig, px, py, set, complete]
    rescue StandardError
      nil
    end

    # True if surfing could actually get the player to (tx,ty): the target, or a tile beside it, is in the
    # water-crossing flood. Positive evidence is required -- a truncated flood answers false -- because
    # "across the water" is a claim about where the target IS, not a shrug at a route that failed. Without
    # it, ANY unreachable target on a map with a pond was called aquatic: in a cave whose halves are joined
    # through internal warps, that meant the exits.
    def self.surf_reaches?(tx, ty, gated = false)
      set = surf_reachable_set(gated)
      return false if set.nil? || set.empty?
      return true if set[pkey(tx, ty)]
      DIRS.any? { |d| set[pkey(tx + d[0], ty + d[1])] }
    rescue StandardError
      false
    end

    # The surf flood from a tile on this map other than her own, as a door would leave her there: at bridge
    # level 0 (arriving on a map resets it) and on foot. A door tile is often impassable, so a flood that goes
    # nowhere is retried from a neighbour. @rs_full belongs to her own flood and is put back. nil if nothing.
    def self.surf_set_from(x, y)
      saved = @rs_full
      best = nil
      # No time budget: this runs once per stretch of shore and is cached, and a sea flood cut off after the
      # keypress budget never reaches the far side -- which is the only thing it is asked about.
      with_bridge_state do
        [[0, 0], [0, 1], [0, -1], [1, 0], [-1, 0]].each do |a, b|
          self.bridge_state = 0
          s = reachable_tiles(true, x + a, y + b)
          best = s if best.nil? || s.length > best.length
          break if s.length > 1
        end
      end
      best
    rescue StandardError
      nil
    ensure
      @rs_full = saved
    end

    # The first launch on the way to (tx,ty) as [shore x, shore y, facing], or nil when the surf flood does
    # not get there by launching. Read off the flood's own record of how each tile was first reached, for
    # the target's tile or a tile beside it (doors are bumped from beside).
    def self.surf_plan(tx, ty, gated = false)
      set = surf_reachable_set(gated)
      return nil if set.nil? || set.empty?
      ([[0, 0]] + DIRS.map { |d| [d[0], d[1]] }).each do |dx, dy|
        v = set[pkey(tx + dx, ty + dy)]
        return v if v.is_a?(Array)
      end
      nil
    rescue StandardError
      nil
    end

    # The facing to launch in when she is standing on the planned shore for (tx,ty), else nil.
    def self.planned_launch_dir(tx, ty)
      px = ($game_player.x rescue -1); py = ($game_player.y rescue -1)
      [false, true].each do |g|
        next if g && (PokeAccess::Gates.empty? rescue true)
        pl = surf_plan(tx, ty, g)
        return pl[2] if pl && pl[0] == px && pl[1] == py
      end
      nil
    rescue StandardError
      nil
    end

    # A route that ends ON (x,y), not beside it. find_path stops a tile short of its target -- right for a
    # door or a person, wrong for a shore, where standing one tile off can mean standing behind the railing.
    # Replays the route through move_target (so a ledge hop or slide lands where it really lands) and adds
    # the last step when it stopped beside the tile. nil when that last step cannot be taken.
    def self.path_onto(x, y)
      px = $game_player.x; py = $game_player.y
      return [] if px == x && py == y
      p = find_path(x, y)
      return nil if p.nil?
      ex = px; ey = py
      p.each do |d|
        dd = DIRS.detect { |e| e[2] == d }
        nxt = dd ? move_target(ex, ey, dd, true, false) : nil
        return nil if nxt.nil?
        ex = nxt[0]; ey = nxt[1]
      end
      return p if ex == x && ey == y
      last = DIRS.detect { |e| ex + e[0] == x && ey + e[1] == y }
      return nil if last.nil? || move_target(ex, ey, last, false, false) != [x, y]
      p + [last[2]]
    rescue StandardError
      nil
    end

    # For a target surfing reaches only once an obstacle BEYOND the water is dealt with: [route to the
    # shore, the obstacles as needs_phrase takes them], or nil. The obstacles are the ones the gated flood
    # crossed that the plain one could not, which on a real map is the face or tree walling the target off.
    def self.surf_launch_gated(tx, ty)
      return nil if (PokeAccess::Gates.empty? rescue true)
      k = [($game_player.x rescue -1), ($game_player.y rescue -1), ($game_map.map_id rescue -1), tx, ty]
      return @surfg_route if @surfg_key == k
      @surfg_key = k
      @surfg_route = nil
      p = compute_surf_launch(tx, ty, true)
      return nil if p.nil?
      g = surf_reachable_set(true); pl = surf_reachable_set(false)
      moves = []
      PokeAccess::Gates.index.each do |key, gate|
        next unless g[key] && !pl[key]
        moves.push(gate[0]) unless moves.include?(gate[0])
      end
      return nil if moves.empty?
      @surfg_route = [p, moves.map { |m| [m, :remove, nil, nil] }]
    rescue StandardError
      nil
    end

    # The walk to the next DOOR on the way to a target the ordinary search cannot reach, as
    # [path, doors_on_the_route], or nil. One leg only -- see WarpNet for why the whole journey is not
    # planned. The door tile is usually impassable, so the path ends beside it exactly as it does for any
    # other door, and walking into it is what opens it.
    def self.find_path_warp(tmap, tx, ty)
      leg = (PokeAccess::WarpNet.first_leg(tmap, tx, ty) rescue nil)
      return nil if leg.nil?
      # A dive or a surfacing is pressed while STANDING on the tile, not walked into from beside it.
      kind = leg[3]
      path = kind ? path_onto(leg[0][0], leg[0][1]) : find_path(leg[0][0], leg[0][1])
      # The first door itself across water: the leg starts at the shore. Fifth element true.
      surf_first = false
      if path.nil?
        path = surf_launch(leg[0][0], leg[0][1])
        return nil if path.nil?
        surf_first = true
      end
      # A third element, :surf, when the doors lead to a shore rather than to the target (WarpNet.surf_leg);
      # the fourth is the door itself, [x, y], for the guide to name when she reaches it; the sixth is what
      # that first crossing is, when it is not an ordinary doorway.
      [path, leg[1], leg[2], leg[0], surf_first, kind]
    rescue StandardError
      nil
    end

    # When find_path cannot reach a target on foot AND surfing would reach it, a route to the reachable
    # shore tile nearest the target -- where to start surfing from -- so the guide leads to the water's
    # edge. Once surfing, normal find_path routes across the water. Cached; nil when no reachable shore or
    # when the water leads nowhere near the target.
    def self.surf_launch(tx, ty)
      k = [($game_player.x rescue -1), ($game_player.y rescue -1), ($game_map.map_id rescue -1), tx, ty]
      return @surf_route if @surf_key == k
      @surf_key = k
      @surf_route = compute_surf_launch(tx, ty)
    rescue StandardError
      nil
    end

    # The uncached shore search: scans the reachable tiles for the one beside surfable water nearest the
    # target and routes to it. Cached by surf_launch because that scan is the cost behind a guide freeze
    # when pointing across water.
    def self.compute_surf_launch(tx, ty, gated = false)
      # Can she actually surf? The water flood only ever asked whether the WATER reached the target, never
      # whether she had any way to cross it. Asked of Gates.can_surf?, which a game profile may replace --
      # "knows the move" is the Essentials default and NOT universal: Insurgence surfs from a KEY ITEM and
      # a badge, so a party with no Surf can still cross every lake in the game. Only a definite NO refuses.
      return nil if (PokeAccess::Gates.can_surf? == false)
      # The shore the surf flood actually launched from on its way to the target -- not the shore NEAREST
      # the target. Nearest-as-the-crow-flies was the old choice, and in the Cave of Steam it picked a pond
      # beside the exit that does not join the lake the exit is on: she surfed, the route afloat could not get
      # there, sent her to the nearest shore -- one tile back -- and told her to surf again, forever.
      # Launch tiles come from surf_step, so the game's own launch rule (a railed pier refuses) still holds.
      plan = surf_plan(tx, ty, gated)
      return nil if plan.nil?
      path_onto(plan[0], plan[1])
    rescue StandardError
      nil
    end

    # A route split into legs: runs of the same direction merged into [direction, count] pairs. This is the
    # shape a route is spoken in, whether the whole thing is read at once or one leg at a time as it is
    # walked, so both readers share the split and cannot drift apart on how a corner is counted.
    def self.legs(path)
      return [] if path.nil? || path.empty?
      out = []; cur = path[0]; count = 0
      path.each do |d|
        if d == cur then count += 1
        else out.push([cur, count]); cur = d; count = 1 end
      end
      out.push([cur, count])
      out
    end

    # One leg as the player hears it, e.g. "3 up".
    def self.leg_text(leg)
      "#{leg[1]} #{PokeAccess::I18n.t(PokeAccess::Locator::DIR_NAMES[leg[0]])}"
    end

    # Turns a list of step directions into a spoken route (e.g. "3 up, 2 left").
    def self.path_to_text(path)
      return PokeAccess::I18n.t(:loc_no_route) if path.nil?
      return PokeAccess::I18n.t(:loc_next_to) if path.empty?
      legs(path).map { |l| leg_text(l) }.join(", ")
    end
  end
end

# Drop the passability grid and route caches on map change or load (Caches.reset_all): they are keyed to
# the current map, so a new map must not see the old grid. force = true bypasses the local invalidation
# throttle.
PokeAccess::Caches.register(:pathfinder) { PokeAccess::Pathfinder.invalidate_cache(true) }
