module PokeAccess
  # Field-move obstacles as things the router can plan THROUGH, rather than as walls.
  #
  # A cuttable tree standing in a corridor is not a wall, it is a door with a key the player is carrying.
  # The router used to treat it as solid, so everything behind it -- the rest of the cave, the exit, the
  # item -- came back "no reachable route", which is the one answer that is worse than silence: it tells a
  # blind player the place does not exist. Across the installed games this is not a corner case. Reborn
  # seals 3,102 tiles behind one, Eternal Emerald 1,931, Infinite Fusion 1,539, Insurgence 1,091.
  #
  # Two kinds, and the difference is the whole design:
  #   :remove  cut tree / smashable rock / headbutt tree -- the obstacle DISAPPEARS when the move is used,
  #            so the tile becomes ordinary floor and a route may run straight over it.
  #   :push    a Strength boulder does NOT disappear. It slides one tile per shove and the player stays
  #            put, so it is not a hole in the wall and pretending it is would route someone into a rock
  #            that is still there. Boulders are handled by the push search in Pathfinder, not here.
  #
  # Identification is the locator's, by the engine's own event name (see fieldmove_label), so a game that
  # names its obstacles the standard way is supported with no per-game work.
  module Gates
    # locator name key => [the move that clears it, how it clears].
    KINDS = { :loc_cut_tree         => [:cut,       :remove],
              :loc_rock_smash       => [:rocksmash, :remove],
              :loc_headbutt_tree    => [:headbutt,  :remove],
              :loc_strength_boulder => [:strength,  :push] }

    # move symbol => the localization key for its spoken name.
    MOVE_LABEL = { :cut => :rl_mo_cut, :rocksmash => :rl_mo_rocksmash,
                   :headbutt => :rl_mo_headbutt, :strength => :rl_mo_strength,
                   :rockclimb => :rl_mo_rockclimb }

    # move symbol => the name to match against a party move, letters only. Compared against BOTH the
    # engine's move name and the raw id, because gen-6 ids are integers whose name is localized while
    # v19+ ids are symbols that are not.
    MOVE_TOKEN = { :cut => "CUT", :rocksmash => "ROCKSMASH",
                   :headbutt => "HEADBUTT", :strength => "STRENGTH",
                   # Surf is not an obstacle gate like the others -- the pathfinder models water as its own
                   # flood -- but it is still a MOVE the party either has or has not, and the water router
                   # needs to be able to ask.
                   :surf => "SURF", :rockclimb => "ROCKCLIMB", :dive => "DIVE",
                   # Waterfall is the same shape as Surf: not an obstacle event, a property of a
                   # stretch of water that decides whether the router may cross it.
                   :waterfall => "WATERFALL" }

    # Per-map index of obstacles: pkey => [move, :remove/:push/:climb, event id]. Keyed by TILE, so it is
    # rebuilt whenever the pathfinder's caches are dropped -- which includes every event end, and a
    # boulder that has just been shoved has ended an event.
    #
    # A third kind, :climb, is not an event at all: it is a TERRAIN tag (climbable rock, where the game has
    # one), carries no event id, and is never taken down by with_removed -- the pathfinder lets a vertical
    # step across it while the gates are open (Pathfinder.climb_step?). It lives here so up_to_first stops
    # the cane at the foot of the face and the phrases name it, like any other obstacle.
    def self.index
      key = ($game_map.map_id rescue 0)
      return @idx if @idx_key == key && @idx
      @idx_key = key
      out = climb_index.dup
      ($game_map.events.values rescue []).each do |ev|
        k = KINDS[(PokeAccess::Locator.fieldmove_label(ev) rescue nil)]
        next unless k
        out[PokeAccess::Pathfinder.pkey(ev.x, ev.y)] = [k[0], k[1], ev.id]
      end
      out.merge!(extra_index)
      @idx = out
    rescue StandardError
      {}
    end

    # Obstacles a GAME PROFILE knows about and the engine's event names cannot express, as the index's own
    # pkey => [move, kind, event id or nil]. Insurgence's sludge is a whole autotile of the map rather than
    # an event: a Mew that knows Seed Flare turns it into water, and until then it is a wall the router had
    # no name for. Empty everywhere else.
    def self.extra_index
      {}
    end

    # A profile's obstacle vocabulary: the move's spoken name, and what to call the thing it clears.
    @extra_moves = {}

    def self.register_move(move, label_key, name_key)
      @extra_moves[move] = [label_key, name_key]
    end

    def self.move_label_key(move)
      e = @extra_moves[move]
      (e && e[0]) || MOVE_LABEL[move]
    end

    # The obstacle-name key a profile registered for a move, or nil (the core names its own).
    def self.name_key(move)
      e = @extra_moves[move]
      e && e[1]
    end

    # Every climbable-rock tile on the map. Terrain does not change, so this survives the index being dropped
    # on every event end and is rebuilt only for a different map: scanning ten thousand tiles on each event
    # end would be a stutter for nothing.
    def self.climb_index
      key = ($game_map.map_id rescue 0)
      return @climb_idx if @climb_key == key && @climb_idx
      @climb_key = key
      out = {}
      if PokeAccess::Terrain.climb_supported?
        w = ($game_map.width rescue 0); h = ($game_map.height rescue 0)
        h.times do |y|
          w.times do |x|
            next unless PokeAccess::Terrain.climb_at?(x, y)
            out[PokeAccess::Pathfinder.pkey(x, y)] = [:rockclimb, :climb, nil]
          end
        end
      end
      @climb_idx = out
    rescue StandardError
      @climb_idx = {}
    end

    # Drops the cached index. Called from Pathfinder.invalidate_cache so there is one place that decides
    # when the map has changed under us.
    def self.invalidate; @idx_key = nil; @idx = nil; end

    def self.empty?; index.empty?; end

    # The obstacle at a tile as [move, kind, event id], or nil.
    def self.at(x, y); index[PokeAccess::Pathfinder.pkey(x, y)]; end

    # Runs a block with every REMOVABLE obstacle set non-blocking -- the map as it will look once the move
    # has been used on them -- and puts each one back afterwards whatever happens. Boulders are left alone
    # on purpose. Nothing is drawn while this is in scope (a search runs inside one frame), so this changes
    # what the engine's passable? answers and nothing else.
    def self.with_removed
      saved = []
      was_flag = PokeAccess::Pathfinder.gates_open
      PokeAccess::Pathfinder.gates_open = true
      index.each_value do |g|
        next unless g[1] == :remove
        ev = ($game_map.events[g[2]] rescue nil)
        next unless ev
        saved.push([ev, (ev.through rescue false)])
        (ev.through = true) rescue nil
      end
      yield
    ensure
      PokeAccess::Pathfinder.gates_open = was_flag
      saved.each { |ev, was| (ev.through = was) rescue nil }
    end

    # The obstacles a finished route walks onto, in order, as [move, kind, x, y]. Read off the route
    # rather than recorded during the search, because a search explores many branches and only the one it
    # returned is the one the player is going to walk.
    def self.crossed(path)
      return [] unless path.is_a?(Array) && !index.empty?
      x = ($game_player.x rescue 0); y = ($game_player.y rescue 0)
      out = []
      pf = PokeAccess::Pathfinder
      was = pf.bridge_state
      begin
        path.each do |d|
          dx, dy = PokeAccess::Pathfinder::DELTA[d]
          break unless dx
          nxt = with_removed { pf.move_target(x, y, [dx, dy, d], true, false) }
          break unless nxt.is_a?(Array)
          x = nxt[0]; y = nxt[1]
          g = at(x, y)
          out.push([g[0], g[1], x, y]) if g
          pf.bridge_state = pf.bridge_after(x, y, pf.bridge_state)
        end
      ensure
        pf.bridge_state = was
      end
      out
    rescue StandardError
      []
    end

    # The part of a gated route the player can walk RIGHT NOW: everything up to, but not onto, the first
    # obstacle. Returns [steps, [move, kind, x, y]] or [path, nil] when the route crosses nothing.
    # Boulders are walked over here as well as trees -- not because the route goes through one, but so the
    # scan STOPS at it and reports it. Past that point a push route's presses no longer line up with tiles
    # anyway, and everything past the first obstacle is somebody else's problem.
    #
    # This is what makes a gated route safe to follow. The cane walks her to the tree and stops there with
    # the obstacle named, instead of counting steps straight through something solid; once she has cut it
    # the plain route exists and the guide carries on by itself.
    def self.up_to_first(path)
      return [path, nil] unless path.is_a?(Array) && !index.empty?
      x = ($game_player.x rescue 0); y = ($game_player.y rescue 0)
      pf = PokeAccess::Pathfinder
      was = pf.bridge_state
      begin
        path.each_with_index do |d, i|
          dx, dy = PokeAccess::Pathfinder::DELTA[d]
          break unless dx
          nxt = with_removed { with_boulders_through { pf.move_target(x, y, [dx, dy, d], true, false) } }
          break unless nxt.is_a?(Array)
          g = at(nxt[0], nxt[1])
          # Reported as [move, kind, x, y] to match crossed(), not as the index's own [move, kind, event]:
          # callers latch on the position, and an event id is not one.
          return [path[0, i], [g[0], g[1], nxt[0], nxt[1]]] if g
          x = nxt[0]; y = nxt[1]
          pf.bridge_state = pf.bridge_after(x, y, pf.bridge_state)
        end
      ensure
        pf.bridge_state = was
      end
      [path, nil]
    rescue StandardError
      [path, nil]
    end

    # ── STRENGTH BOULDERS ──────────────────────────────────────────────────────────────────────────
    # Verified against the engine (Essentials pbPushThisEvent / pbPushThisBoulder, Game_Character#passableEx?):
    #   * one tile per shove, in the direction the player is FACING;
    #   * THE PLAYER DOES NOT MOVE with it -- the event moves and $game_player is untouched, so crossing a
    #     boulder is press-to-push, then press the same way again to walk into the tile it left;
    #   * the boulder's own test is the STRICT one, which ignores per-direction passage bits, so a tile a
    #     person may walk onto from one side only is not somewhere a boulder can go;
    #   * nothing else may be standing on the destination;
    #   * and none of it happens at all until Strength has been used on this map ($PokemonMap.strengthUsed).

    # The boulders on this map as [event, x, y], nearest the player first.
    def self.boulders
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      out = []
      index.each_value do |g|
        next unless g[1] == :push
        ev = ($game_map.events[g[2]] rescue nil)
        out.push([ev, ev.x, ev.y]) if ev
      end
      out.sort_by { |b| (b[1] - px).abs + (b[2] - py).abs }
    rescue StandardError
      []
    end

    # Has Strength been switched on for this map? true / false / nil when the engine does not say.
    def self.strength_ready?
      m = ($PokemonMap rescue nil)
      return nil unless m && (m.respond_to?(:strengthUsed) rescue false)
      !!(m.strengthUsed rescue false)
    rescue StandardError
      nil
    end

    # Runs a block with every boulder set non-blocking, so the engine's passable? answers about terrain and
    # other events only. The push search keeps its own record of where the boulders are, and needs the
    # engine to stop insisting they are all still in their starting squares.
    def self.with_boulders_through
      saved = []
      was_flag = PokeAccess::Pathfinder.boulders_open
      PokeAccess::Pathfinder.boulders_open = true
      boulders.each do |ev, _x, _y|
        saved.push([ev, (ev.through rescue false)])
        (ev.through = true) rescue nil
      end
      yield
    ensure
      PokeAccess::Pathfinder.boulders_open = was_flag
      saved.each { |ev, was| (ev.through = was) rescue nil }
    end

    # Can the boulder at (bx,by) be shoved one tile in direction d? occupied is the set of tiles the
    # search's OTHER boulders currently stand on, which the engine cannot know about.
    def self.boulder_can_move?(ev, bx, by, dx, dy, d, occupied)
      nx = bx + dx; ny = by + dy
      return false unless ($game_map.valid?(nx, ny) rescue false)
      return false if occupied.include?([nx, ny])
      if ($game_map.respond_to?(:passableStrict?) rescue false)
        return false unless ($game_map.passableStrict?(bx, by, d, ev) rescue false)
        return false unless ($game_map.passableStrict?(nx, ny, 10 - d) rescue false)
      else
        return false unless ($game_map.passable?(bx, by, d, ev) rescue false)
        return false unless ($game_map.passable?(nx, ny, 10 - d) rescue false)
      end
      # Anything else solid standing there stops it. Every boulder is through for the search, so a boulder
      # in the way is caught by the occupied test above and never here.
      blocked = ($game_map.events.values.any? do |e|
        !e.equal?(ev) && e.x == nx && e.y == ny && !(e.through rescue false)
      end rescue false)
      return false if blocked
      !(($game_player.x == nx && $game_player.y == ny) rescue false)
    rescue StandardError
      false
    end

    # The spoken name of a move.
    def self.move_name(move)
      PokeAccess::I18n.t(move_label_key(move) || :rl_mo_cut)
    rescue StandardError
      move.to_s
    end

    # True when somebody in the party knows the move, false when nobody does, and nil when the party
    # cannot be read at all. Nil is not false: claiming "nobody knows Cut" on a party we failed to read
    # would send her hunting for a Pokemon she already has, so every caller treats nil as "say nothing".
    # Can the player cross water at all? The Essentials default is "somebody in the party knows Surf", and
    # that is only a default: a game is free to gate surfing on an item, a badge, a story flag or anything
    # else, so a PROFILE may replace this outright. Answers true / false / nil, and nil means "cannot tell",
    # which is not the same as no.
    def self.can_surf?
      known?(:surf)
    end

    # Can the player dive? Same shape and same nil rule as can_surf?; Insurgence dives with a key item.
    def self.can_dive?
      known?(:dive)
    end

    # Can the player climb a waterfall? Same shape and same nil rule as can_surf?.
    #
    # This is NOT a detail. Essentials' own pbIsSurfableTag? counts the two waterfall tags as surfable, so
    # without this the amphibious flood swims straight up a wall of falling water and the router plans
    # routes through it. Deyraan Town is the case that found it: the cave above the falls is meant to be
    # reached by trading places with a statue, and the router kept walking her into the pond instead.
    def self.can_waterfall?
      known?(:waterfall)
    end

    # Would the game START surfing with the player standing on (x,y) facing d, water in front? Essentials asks
    # one thing beyond the water itself: that her own tile is open on that side
    # ($game_map.passable?(x, y, direction) in the action handler). A pier with a railing, or a clifftop over
    # a lake, is beside water and still refuses -- which is where the cane used to leave her: on the Helios
    # City pier, facing a railing, told to surf. A profile may add the game's own extra conditions.
    def self.surf_launch_ok?(x, y, d)
      ($game_map.passable?(x, y, d) rescue false) ? true : false
    end

    # Can the player USE this obstacle's move right now? true / false / nil, with the same nil-is-not-no rule
    # as known?. The Essentials default is the party knowing the move; a game that unlocks a field move with a
    # key item instead (Insurgence's Hiking Boots for Rock Climb) replaces this in its profile.
    def self.usable?(move)
      known?(move)
    end

    # The name of the key item that unlocks a move, when a game unlocks it that way, else nil. Only changes
    # the WORDING of a "you can't do that yet": telling her nobody in the party knows Rock Climb would send
    # her looking for a Pokemon when what she is missing is a pair of boots.
    def self.unlock_item(move)
      nil
    end

    def self.known?(move)
      tok = MOVE_TOKEN[move]
      return nil unless tok
      party = party_list
      return nil if party.nil?
      party.each do |pk|
        (pk.moves rescue []).each do |m|
          next if m.nil?
          id = (m.id rescue nil)
          next if id.nil?
          return true if norm(id.to_s) == tok
          return true if norm((PokeAccess::Data.move_name(id) rescue "").to_s) == tok
        end
      end
      false
    rescue StandardError
      nil
    end

    # The player's party across engines ($Trainer in gen-6, $player from v19), or nil when neither reads.
    def self.party_list
      p = ($player.party rescue nil)
      p = ($Trainer.party rescue nil) if p.nil?
      p.is_a?(Array) ? p : nil
    rescue StandardError
      nil
    end

    def self.norm(s); s.to_s.upcase.gsub(/[^A-Z]/, ""); end

    # "needs Rock Smash", or "needs Rock Smash, nobody knows it" when the party has been read and does
    # not have it. One phrase covering however many different obstacles a route crosses.
    def self.needs_phrase(gates)
      moves = gates.map { |g| g[0] }.uniq
      return nil if moves.empty?
      names = moves.map { |mv| move_name(mv) }.join(", ")
      missing = moves.select { |mv| usable?(mv) == false }
      if missing.empty?
        PokeAccess::I18n.t(:loc_needs_move, :move => names)
      elsif (item = missing.map { |mv| unlock_item(mv) }.compact.first)
        PokeAccess::I18n.t(:loc_needs_move_item, :move => names, :item => item)
      else
        PokeAccess::I18n.t(:loc_needs_move_unknown, :move => names)
      end
    rescue StandardError
      nil
    end
  end
end
