module PokeAccess
  # Routing THROUGH doors: the warp network as edges in the router's graph.
  #
  # Every router in the mod stops at the edge of the current map, so a target behind a door reads as "no
  # reachable route" even when the way there is obvious. Insurgence's second gym is the case this was
  # written for -- a maze of tree-holes across two maps, where the leader is forty tiles and four doors away
  # and no amount of single-map searching will ever find him.
  #
  # The design is Amethyst's, and it is the reason this is a router change and not a "puzzle mode":
  #   * a door is an EDGE, not a special case. The search walks, takes a door, walks, takes a door.
  #   * ONE LEG IS PLANNED, never the whole journey. Going through a door changes which map you are on, so
  #     any route computed past it is already wrong. This answers only "which door on THIS map do I walk to",
  #     and the ordinary guide walks her there in ordinary words. When she comes out the other side, the
  #     guide recomputes and asks again.
  #   * a certificate before speaking: a door whose destination is not a literal in the map data, or a map
  #     whose walkable region could not be established, is not offered at all.
  module WarpNet
    # Bounds. Doors deep, then landing spots wide; past either it answers "no route" rather than thinking
    # for a second. A gym is 4 doors and about twenty landings, a dungeon a little more.
    MAX_HOPS = 6
    # Landing spots the search may expand. NOT the same thing as maps: one map contributes a landing per
    # door, so a two-map gym with a dozen tree-holes is already twenty-odd nodes. Capping nodes at MAX_MAPS
    # is what made this give up long before it reached the leader.
    MAX_NODES = 80
    # Wall-clock ceiling for one closure. A neighbourhood of big maps can otherwise run for many seconds,
    # and a search that has not found the way in this long is not going to.
    BUDGET = 1.5

    @cl = nil
    @cl_map = nil
    @cl_region = nil
    @regions = nil
    @regions_surf = nil

    def self.reset
      @cl = nil
      @cl_map = nil
      @cl_region = nil
      @regions = nil
      @regions_surf = nil
    end

    # Whether the LAST first_leg looked everywhere it could reach, or stopped early (out of nodes, out of
    # seconds). "No reachable route" is a claim about the map; without this it was also said after a search
    # that simply ran out of room, which tells her a place does not exist when nobody finished checking.
    def self.searched_fully?
      @searched_fully ? true : false
    end

    # The FIRST leg toward a target on this or another map: the [x, y] of the door on the CURRENT map to
    # head for, plus how many doors remain after it. nil when there is no such route.
    #
    # Memoised on the whole question, because the answer only changes when the player changes map or the
    # target moves, and the search behind it is far too expensive to run per frame.
    def self.first_leg(tmap, tx, ty)
      @searched_fully = false
      mid = ($game_map.map_id rescue nil)
      return nil if mid.nil? || $game_player.nil?
      c = closure(mid, $game_player.x, $game_player.y)
      return nil if c.nil?
      # Reachable by surfing from right here: the ladder's surf step answers that, and a door search grown
      # for seconds to prove there is no door route was pure waste -- 12 s on the Helios pier.
      pf = PokeAccess::Pathfinder
      direct_surf = (tmap == mid && (pf.surf_plan(tx, ty) || pf.surf_plan(tx, ty, true))) ? true : false
      started = (PokeAccess.clock rescue 0)
      checked = 0
      loop do
        c[:nodes].each do |n|
          next unless n[0] == tmap
          next unless usable?(n[3], n[0], tx, ty)
          return nil if n[4].nil?
          wet = wet_reach?(n[3], tx, ty, n[0]) ? :surf : nil
          return [n[4][0], n[4][1], wet, n[4][2]]
        end
        # With water in the regions (amphi?), a door that leads to a shore is already found above and tagged by
        # wet_reach?; the separate engine-measured sea check is only for a game where she cannot surf.
        unless amphi?
          leg = surf_leg(c, mid, tmap, tx, ty)
          return leg if leg
        end
        break if direct_surf || c[:done] || (PokeAccess.clock rescue 0) - started > FULL_BUDGET
        break if checked == c[:nodes].length && c[:near_head] >= c[:near].length && c[:far_head] >= c[:far].length
        checked = c[:nodes].length
        extend_closure(c, BUDGET, tmap)
      end
      # What makes "no reachable route" a FINDING rather than a guess is whether the target's own map was
      # reached at all. Every landing on it was then tested and none of their regions holds the target, which
      # is a real answer. If the search never got that far -- it caps at eighty landings, and an overworld
      # spills past that from any room in it -- then nobody has looked, and saying the place cannot be
      # reached would be inventing a fact. Asking instead whether the whole search finished called every
      # question in a connected world unfinished, which buys nothing.
      @searched_fully = (tmap == mid || c[:nodes].any? { |n| n[0] == tmap }) ? true : false
      nil
    rescue StandardError
      nil
    end

    # Doors, THEN water: a target on this map that no door reaches on foot, but that surfing reaches from where
    # some door lets her back out onto this map. The answer is the same first door, tagged :surf so the phrase
    # can say what comes after.
    #
    # Miara Town is the case: islands joined by raised bridges, every shore a railing or a cliff while she is up
    # on the bridge level, and the ramps round every town door put her straight back up. The only way to the
    # water is through the museum -- in by the town door, out by the pier door, which comes out at water level
    # because arriving on a map always resets the bridge. Neither router alone could see it: doors had no water,
    # and the water flood started from where she stood.
    def self.surf_leg(c, mid, tmap, tx, ty)
      return nil if (PokeAccess::Gates.can_surf? == false)
      # Already able to surf there from where she stands (the pier itself): that is the ladder's own surf
      # step, and offering a door here would send her round through the museum and back out onto the pier.
      return nil if tmap == mid && PokeAccess::Pathfinder.surf_plan(tx, ty)
      c[:nodes].each do |n|
        next unless n[0] == tmap && n[4]
        next unless landing_surf_reaches?(tmap, n[1], n[2], tx, ty)
        return [n[4][0], n[4][1], :surf, n[4][2]]
      end
      nil
    rescue StandardError
      nil
    end

    # How many maps' surf floods to remember. They are only ever measured on the map itself, with the engine.
    SURF_SETS_MAX = 8

    # Does a surf flood from a landing on map tmap reach (tx,ty)? Measured with the ENGINE, so only while she
    # is standing on that map -- at bridge level 0, which is where a door leaves her -- and remembered past the
    # map change. That memory is what carries the plan through the doors: inside the museum the town map is
    # not loaded and nothing can flood its sea, but the flood she was given in town still says which landing
    # leads to the water. Nothing measured is ever invented away from its map: no set, no answer.
    def self.landing_surf_reaches?(tmap, lx, ly, tx, ty)
      @surf_sets ||= {}
      pk = PokeAccess::Pathfinder
      list = (@surf_sets[tmap] ||= [])
      set = list.find { |s| s[pk.pkey(lx, ly)] || [[0, 1], [0, -1], [1, 0], [-1, 0]].any? { |a, b| s[pk.pkey(lx + a, ly + b)] } }
      if set.nil?
        return false unless tmap == ($game_map.map_id rescue nil)
        set = pk.surf_set_from(lx, ly)
        return false if set.nil?
        list.push(set)
        @surf_order = ((@surf_order || []) - [tmap]) + [tmap]
        @surf_sets.delete(@surf_order.shift) while @surf_order.length > SURF_SETS_MAX
      end
      [[0, 0], [0, 1], [0, -1], [1, 0], [-1, 0]].any? { |a, b| set[pk.pkey(tx + a, ty + b)].is_a?(Array) }
    rescue StandardError
      false
    end


    # Everywhere the doors lead from where she is standing, computed ONCE for the region she is in.
    #
    # The expensive half of a cross-map search -- stepping out through each door and flooding the map it
    # lands on -- does not depend on where she is trying to GET to. Doing it per target meant every entry in
    # a list of exits paid for it again: measured at 3.4 s each in the Black Market, where she stands in a
    # 41-tile pocket and four of the five doors on the map are genuinely out of reach. Done once per region,
    # the first question is slow and every question after it is free.
    #
    # Each node is [map, landing x, landing y, that landing's walkable region, the FIRST door to take].
    def self.closure(mid, px, py)
      start_set = region(mid, px, py)
      return nil if start_set.nil?
      unless @cl && @cl_map == mid && @cl_region && in_set?(@cl_region, mid, px, py)
        @cl_map = mid
        @cl_region = start_set
        @cl = { :nodes => [[mid, px, py, start_set, nil]], :seen => { [mid, px, py].join(",") => true },
                :near => [0], :far => [], :near_head => 0, :far_head => 0, :done => false,
                :name => place_name(mid) }
        # One slice when the closure is first built. Growing it further on EVERY question -- including the
        # ones it already answers -- was a second and a half per keypress until it finished.
        extend_closure(@cl, BUDGET)
      end
      @cl
    rescue StandardError
      @cl = nil
    end

    def self.place_name(mid)
      (PokeAccess::Locator.map_name(mid) || "").to_s.strip.downcase
    rescue StandardError
      ""
    end

    # Total time one question may spend growing an unfinished closure before answering "no route".
    FULL_BUDGET = 3.0

    # Grows a closure breadth-first for up to `budget` seconds, and REMEMBERS where it stopped.
    #
    # It used to start over each time and give up after 1.5 s -- which in Miara Town, a hub of a dozen doors
    # with two big routes behind them, ran out one door short of the museum's pier exit, the only way to the
    # sea. Whether the answer came back depended on how fast the floods ran that second. Now a question that
    # finds nothing in what has been explored so far lets the search carry on (first_leg), and the next
    # question starts where this one stopped instead of repaying for the part already done.
    #
    # Places with the SAME NAME as where she stands are explored first: a maze is one place spread over several
    # maps (Vipik Gym's two, Whirl Islands' four), and the doors out to the town beside it are where a
    # breadth-first search goes to drown. With water counted, Vipik City is fifteen hundred tiles and a dozen
    # houses, and the search spent its whole budget in them before it was four trees deep into the gym.
    def self.extend_closure(cl, budget, want = nil)
      nodes = cl[:nodes]; seen = cl[:seen]
      deadline = (PokeAccess.clock rescue 0) + budget
      loop do
        idx, from = pick_index(cl, want)
        break if idx.nil?
        if nodes.length > MAX_NODES
          # Stopped because there was no more room to look, which is NOT the same as having looked everywhere.
          cl[:capped] = true
          cl[:done] = true
          return cl
        end
        if (PokeAccess.clock rescue 0) > deadline
          # Not expanded: put it back at the front of its queue for the next slice.
          case from
          when :want then cl[:near].insert(cl[:near_head], idx)
          when :far  then cl[:far_head] -= 1
          else            cl[:near_head] -= 1
          end
          return cl
        end
        n = nodes[idx]
        m = n[0]; set = n[3]
        next if set.nil?
        warps(m).each do |wx, wy, dm, dx, dy, face, kind|
          next if dm == m && dx == n[1] && dy == n[2]
          next unless door_usable?(set, m, wx, wy, face)
          key = [dm, dx, dy].join(",")
          next if seen[key]
          seen[key] = true
          # The answer is always the FIRST door of the journey, however deep the win turns up -- and what that
          # first one is (an ordinary doorway, a dive, a surfacing) travels with it.
          lead = n[4] || [[wx, wy], 0, kind]
          r = region(dm, dx, dy)
          next if r.nil?
          nodes.push([dm, dx, dy, r, [lead[0], lead[1] + 1, lead[2]]])
          (place_name(dm) == cl[:name] ? cl[:near] : cl[:far]).push(nodes.length - 1)
        end
      end
      cl[:done] = true
      cl
    rescue StandardError
      cl[:done] = true
      cl
    end

    # The next node to expand, as [index, which queue it came from].
    #
    # A node on the map the QUESTION is about goes first, wherever it is queued. Without that the budget is
    # spent breadth-first over the whole neighbourhood: asked from under the sea for somewhere in the base
    # above, the search explored twenty-two maps, hit its node cap and never got round to the pads of the one
    # map the target was actually on -- so a route she had just walked came back "no reachable route".
    def self.pick_index(cl, want)
      if want
        [[cl[:near], cl[:near_head], :near], [cl[:far], cl[:far_head], :far]].each do |q, head, _which|
          i = (head...q.length).detect { |j| (cl[:nodes][q[j]] || [])[0] == want }
          next if i.nil?
          idx = q[i]
          q.delete_at(i)
          return [idx, :want]
        end
      end
      if cl[:near_head] < cl[:near].length
        i = cl[:near][cl[:near_head]]; cl[:near_head] += 1
        [i, :near]
      elsif cl[:far_head] < cl[:far].length
        i = cl[:far][cl[:far_head]]; cl[:far_head] += 1
        [i, :far]
      else
        [nil, nil]
      end
    end

    # The walkable region around a spot, cached BY REGION and not by tile.
    #
    # Thirteen doors on one map land in the same handful of regions, and a flood is the expensive part of
    # this whole search: without this it ran one per landing. A tile already inside a known region reuses
    # that region's set.
    def self.region(mid, x, y)
      # Water flips every answer the model gives, so a cache built on foot cannot be handed to a search
      # made afloat (and the other way round). Mounting Surf drops the lot.
      sf = [(PokeAccess::ForeignMap.surf_state rescue false), amphi?]
      if @regions_surf != sf
        @regions_surf = sf
        @regions = nil
        @cl = nil
        @cl_map = nil
        @cl_region = nil
      end
      @regions ||= {}
      list = (@regions[mid] ||= [])
      list.each { |s| return s if in_set?(s, mid, x, y) }
      # A landing ON a doorway is in no region at all -- the tile is drawn into the wall -- so the room it
      # opens into was flooded again for every door of it. Measured: one map flooded seven times from seven
      # adjacent doorways, 150 ms each. A neighbour in a known region is that region, which is the same rule
      # door_usable? already uses to decide a door can be walked into.
      #
      # ONLY for a landing that cannot be stood on. A crossing like the Tesseract lands on a REAL tile, and
      # a real tile beside a known region is not necessarily part of it: Crystal Caves is split by a cliff,
      # and 31,51 sits directly below 31,50 on the far side of it. Taking the neighbour's answer filed every
      # square of the shift box into the 263-tile pocket she was already in, so the router concluded the
      # shift led nowhere new and refused to plan through it -- the whole point of the mechanic, lost to a
      # shortcut meant for doorways. Where she can stand, the tile's own region is the only correct answer.
      if standable_landing?(mid, x, y)
        s = compute_region(mid, x, y)
        return nil if s.nil?
        list.push(s)
        return s
      end
      list.each { |s| return s if usable?(s, mid, x, y) }
      s = compute_region(mid, x, y)
      return nil if s.nil?
      list.push(s)
      s
    end

    # One flood: the engine for the map she is standing on, the model for anywhere else. A landing that
    # comes out on an impassable tile would flood to nothing, so a one-tile answer is retried from a
    # neighbour before it is believed.
    def self.compute_region(mid, x, y)
      s = raw_region(mid, x, y)
      return s if s.nil? || s.length > 1
      [[0, 1], [0, -1], [1, 0], [-1, 0]].each do |a, b|
        t = raw_region(mid, x + a, y + b)
        return t if t && t.length > 1
      end
      s
    end

    def self.raw_region(mid, x, y)
      pf = PokeAccess::Pathfinder
      if mid == ($game_map.map_id rescue nil)
        return (pf.reachable_from(x, y) rescue nil) unless amphi?
        return pf.surf_reachable_set(false) if x == $game_player.x && y == $game_player.y
        # Another spot on this map (a door's landing): the MODEL's amphibious flood, re-keyed for this map. The
        # engine flood was right but slow -- a 90x90 cave map is a dozen rooms, each a flood of its own, and doing
        # them with the engine on every arrival froze the game for five to seven seconds. The model agrees with
        # the engine tile for tile (checked on the maps she has played), and it is remembered between map changes,
        # so coming back to a room costs nothing. Only where she stands is asked of the engine.
        model_region_here(mid, x, y)
      else
        amphi? ? PokeAccess::ForeignMap.amphi_flood_cached(mid, x, y) : PokeAccess::ForeignMap.flood(mid, x, y)
      end
    end

    # A model flood of the current map with its keys repacked the way the engine's sets are.
    def self.model_region_here(mid, x, y)
      f = PokeAccess::ForeignMap.amphi_flood_cached(mid, x, y)
      return nil if f.nil?
      @repacked ||= {}
      hit = @repacked[f.__id__]
      return hit if hit
      out = {}
      pk = PokeAccess::Pathfinder
      f.each { |k, v| out[pk.pkey(k / 1000, k % 1000)] = v }
      @repacked.clear if @repacked.length > 200
      @repacked[f.__id__] = out
    rescue StandardError
      nil
    end

    # Regions include water when she can surf: a room past a pool is part of where she can go, and a route
    # through Whirl Islands is doors AND pools, one after another, over three maps.
    def self.amphi?
      PokeAccess::Gates.can_surf? == true
    rescue StandardError
      false
    end

    # True if a region reaches (tx,ty) only by water: the target or a tile beside it was reached after a launch
    # (a launch record on the current map, :surf in the model) and none of them on foot.
    def self.wet_reach?(set, tx, ty, mid)
      vals = [[0, 0], [0, 1], [0, -1], [1, 0], [-1, 0]].map do |a, b|
        k = (mid == ($game_map.map_id rescue nil)) ? PokeAccess::Pathfinder.pkey(tx + a, ty + b) : PokeAccess::ForeignMap.key(tx + a, ty + b)
        set[k]
      end.compact
      return false if vals.empty? || vals.include?(true)
      vals.any? { |v| v.is_a?(Array) || v == :surf }
    rescue StandardError
      false
    end

    # True if a door at (wx,wy) can be used from a region. A door tile is usually IMPASSABLE -- a doorway or
    # a tree-hole drawn into the wall -- and its player-touch trigger fires when you walk into it, so it
    # counts as usable when the tile itself OR any neighbour is walkable.
    # A door as the closure uses it: a one-way doorway only from the tile it is walked in from.
    def self.door_usable?(set, mid, wx, wy, face)
      return usable?(set, mid, wx, wy) unless face
      dd = PokeAccess::Pathfinder::DELTA[face]
      in_set?(set, mid, wx - dd[0], wy - dd[1])
    end

    def self.usable?(set, mid, wx, wy)
      return true if in_set?(set, mid, wx, wy)
      [[0, 1], [0, -1], [1, 0], [-1, 0]].any? { |a, b| in_set?(set, mid, wx + a, wy + b) }
    end

    # Can she actually STAND on this landing tile? A doorway drawn into a wall cannot be stood on, which is
    # what the neighbour shortcut in region() exists for; a crossing's landing tile can.
    def self.standable_landing?(mid, x, y)
      if mid == ($game_map.map_id rescue nil)
        [2, 4, 6, 8].any? { |d| PokeAccess::Pathfinder.player_passable?(x, y, d) }
      else
        rec = PokeAccess::ForeignMap.info(mid)
        rec ? !PokeAccess::ForeignMap.standable(rec, x, y).nil? : false
      end
    rescue StandardError
      false
    end

    # Set membership across the two flood shapes: the engine's set is keyed by Pathfinder.pkey, the model's
    # by its own packing.
    def self.in_set?(set, mid, x, y)
      if mid == ($game_map.map_id rescue nil)
        !!set[PokeAccess::Pathfinder.pkey(x, y)]
      else
        !!set[PokeAccess::ForeignMap.key(x, y)]
      end
    end

    # The doors a map offers: live events on the current map (their pages may have changed), the loaded map
    # data anywhere else.
    # Extra link sources a GAME profile contributes, each a block taking a map id and returning warp
    # rows in the same shape as everything else here. Dive is the precedent: a crossing that is not a
    # door, joins two maps at the same coordinates, and needs the closure to know nothing about it.
    # Insurgence's Tesseract is exactly that shape, and it belongs to one game, so it registers instead
    # of being written in here.
    LINK_SOURCES = []

    def self.register_link_source(&blk); LINK_SOURCES.push(blk); end

    # Every registered source's rows for a map, with a source that raises simply contributing nothing --
    # a broken profile must not be able to make the whole router answer "no route".
    def self.extra_links(mid)
      return [] if LINK_SOURCES.empty?
      out = []
      LINK_SOURCES.each { |b| r = (b.call(mid) rescue nil); out.concat(r) if r.is_a?(Array) }
      out
    rescue StandardError
      []
    end

    def self.warps(mid)
      unless mid == ($game_map.map_id rescue nil)
        return PokeAccess::ForeignMap.warps(mid) + dive_links(mid) + extra_links(mid)
      end
      out = []
      $game_map.events.each_value do |ev|
        next unless (PokeAccess::Locator.transfer_event?(ev) rescue false)
        xy = (PokeAccess::Locator.transfer_command_dest_xy(ev) rescue nil)
        next if xy.nil?
        out.push([ev.x, ev.y, xy[0], xy[1], xy[2], PokeAccess::Pathfinder.door_facing(ev.x, ev.y)])
      end
      out + dive_links(mid) + extra_links(mid)
    rescue StandardError
      []
    end

    # Diving is a door like any other: a stretch of deep water joins a map to the one beneath it at the same
    # coordinates, and a patch of light joins it back. Shaped exactly like a warp row so the closure, the
    # regions and the hop counting need to know nothing about water -- with a seventh field naming what the
    # crossing IS, which is the one thing the guide has to say differently when she gets there.
    def self.dive_links(mid)
      PokeAccess::Dive.links(mid).map { |x, y, dm, kind| [x, y, dm, x, y, nil, kind] }
    rescue StandardError
      []
    end

  end
end

PokeAccess::Caches.register(:warpnet) { PokeAccess::WarpNet.reset }
