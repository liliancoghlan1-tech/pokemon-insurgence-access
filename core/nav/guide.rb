module PokeAccess
  # Locator part 4 of 4: the two guides toward the selected target, both fed by one route.
  #
  #   - the CANE (Shift+I): a panned/pitched chime on a timer, pointing at the next step.
  #   - the STEP guide (Ctrl+I): the route spoken one leg at a time, "6 up", the next leg only once that
  #     one has been walked.
  #
  # The route is computed once by A* and then CONSUMED as the player walks it (recomputing only on
  # deviation, target change or a freshness check), which keeps it cheap on big maps and is what lets the
  # step guide read the leg it is on without searching again. Both may run at once; they share the route,
  # the "no route" latch and the end of the journey, so nothing is announced twice.
  module Locator
    # rpg direction code => its localization key (for the "jump <dir>" cue).
    DIR_NAMES = { 8 => :dir_up, 2 => :dir_down, 4 => :dir_left, 6 => :dir_right }

    # Manhattan distance (tiles) over which the guide chime fades to its quietest; nearer targets play louder.
    GUIDE_FALLOFF_TILES = 24.0
    # Minimum seconds between forced "next step blocked" recomputes, so walking corners (where path[0] briefly
    # faces a wall mid-step) does not trigger a per-tick double A*. The normal per-tick refresh is unaffected.
    RECHECK_BLOCKED_SEC = 0.5

    # Seconds between guide chimes, from guide_freq (higher = more frequent), paced in real time. The chime
    # spaces out with distance so a far target does not "gallop": at the target tile it is the configured
    # interval, growing linearly up to 2x at GUIDE_FALLOFF_TILES (24) or beyond. Close stays responsive,
    # far stays calm but still audible. param dist manhattan distance to the target (nil = no scaling)
    def self.guide_interval(dist = nil)
      base = PokeAccess.freq_to_seconds((PokeAccess::Config.guide_freq rescue 55))
      return base if dist.nil?
      f = dist.to_f / GUIDE_FALLOFF_TILES
      f = 1.0 if f > 1.0
      base * (1.0 + f)
    end

    # Seconds before a forced fresh A* (bounds staleness if the map changes mid-route), from guide_refresh.
    def self.guide_refresh_seconds
      s = (PokeAccess::Config.guide_refresh rescue 4).to_i
      s <= 0 ? 4 : s
    end

    # Starts the guide chime toward the current target when auto-guide is enabled.
    def self.auto_guide_on
      return unless (PokeAccess::Config.auto_guide rescue false)
      return unless @target
      @guide = true
      @guide_time = nil
      @guide_from = nil
      @guide_noroute = false
    end

    # Starts the step guide toward the current target when its auto setting is enabled. Silent: the target
    # was just announced by whatever selected it, and the first leg follows on the next frame anyway.
    def self.auto_steps_on
      return unless (PokeAccess::Config.auto_steps rescue false)
      return unless @target
      @steps = true
      @steps_at = nil
      @steps_leg = nil
    end

    # Toggles the guide-cane mode (Shift+I): a panned chime points to the next step toward the target.
    def self.toggle_guide
      @guide = !@guide
      if @guide
        ensure_target
        unless @target
          @guide = false
          return PokeAccess.speak(PokeAccess::I18n.t(:loc_nothing_selected), true)
        end
        @guide_time = nil
        @guide_from = nil
        @guide_noroute = nil
        PokeAccess.speak(PokeAccess::I18n.t(:loc_guide_to, :name => target_name(@target)), true)
      else
        PokeAccess.speak(PokeAccess::I18n.t(:loc_guide_off), true)
      end
    end

    # Toggles the step-by-step guide (Ctrl+I): speaks the leg of the route being walked now and the next
    # one as each is finished. The spoken counterpart of the cane, and independent of it.
    def self.toggle_steps
      @steps = !@steps
      if @steps
        ensure_target
        unless @target
          @steps = false
          return PokeAccess.speak(PokeAccess::I18n.t(:loc_nothing_selected), true)
        end
        @steps_at = nil
        @steps_leg = nil
        @guide_noroute = nil
        PokeAccess.speak(PokeAccess::I18n.t(:loc_steps_to, :name => target_name(@target)), true)
      else
        forget_steps
        PokeAccess.speak(PokeAccess::I18n.t(:loc_steps_off), true)
      end
    end

    # Drops what the step guide remembers about the leg it was on, so the next tick speaks afresh.
    def self.forget_steps
      @steps_at = nil
      @steps_leg = nil
    end

    # Ends both guides at once and says why. Arrival and a lost target end the JOURNEY, not one mode of
    # travelling it: with the cane and the step guide both running, each would otherwise reach the same
    # conclusion on the same frame and the player would hear it twice.
    def self.stop_guides(key)
      @guide = false
      @steps = false
      @surf_said = nil
      forget_steps
      PokeAccess.speak(PokeAccess::I18n.t(key), true)
    end

    # The straight-line direction toward the target, used only when A* cannot route. Prefers a WALKABLE
    # next tile so the chime leads around a wall, not into it; keeps the dominant direction only if
    # neither axis is walkable yet (e.g. deep water before surfing).
    def self.straight_dir(ev)
      px = $game_player.x; py = $game_player.y
      dx = ev.x - px; dy = ev.y - py
      horiz = dx == 0 ? 0 : (dx < 0 ? 4 : 6)
      vert  = dy == 0 ? 0 : (dy < 0 ? 8 : 2)
      primary, secondary = (dx.abs >= dy.abs) ? [horiz, vert] : [vert, horiz]
      return primary if primary != 0 && (PokeAccess::Pathfinder.player_passable?(px, py, primary) rescue false)
      return secondary if secondary != 0 && (PokeAccess::Pathfinder.player_passable?(px, py, secondary) rescue false)
      return primary if primary != 0 && surfable_ahead?(px, py, primary)
      return secondary if secondary != 0 && surfable_ahead?(px, py, secondary)
      0
    end

    # True if the tile one step in a direction is surfable water, so straight_dir tells water from a wall.
    def self.surfable_ahead?(px, py, dir)
      return false if dir == 0 || $game_map.nil?
      nx, ny = step_tile(px, py, dir)
      PokeAccess::Terrain.surfable_at?(nx, ny)
    rescue StandardError
      false
    end

    # Plays the panned/pitched guide chime for a step, louder as the target nears. Left/right go through
    # the 3D engine; up/down (front/back, which HRTF cannot place on plain stereo headphones) use a pitched
    # flat cue (high = up, low = down). The guide tone moves all four by the pair's shared factor.
    def self.guide_cue(dir, dist)
      return if dir == 0
      v = PokeAccess::Config.event_volume
      return if v.nil? || v <= 0
      factor = 1.0 - (dist.to_f / GUIDE_FALLOFF_TILES)
      factor = 0.35 if factor < 0.35
      factor = 1.0 if factor > 1.0
      vol = (v * factor).to_i
      return if (PokeAccess::Audio3D.guide(dir, vol) rescue false)
      f = PokeAccess::Spatial.guide_tone_factor
      case dir
      when 4 then PokeAccess::Spatial.cue("pa_guide_l", vol, (100 * f).round)
      when 6 then PokeAccess::Spatial.cue("pa_guide_r", vol, (100 * f).round)
      when 8 then PokeAccess::Spatial.cue("pa_guide_c", vol, (140 * f).round)
      else        PokeAccess::Spatial.cue("pa_guide_c", vol, (70 * f).round)
      end
    end

    # Runs each frame while guiding: chimes toward the target on a timer (the path refresh only runs on tick).
    def self.guide_tick
      return unless @guide
      return if PokeAccess::Spatial.busy?
      now = PokeAccess.clock
      dist = ((@target.x - $game_player.x).abs + (@target.y - $game_player.y).abs rescue nil)
      return if @guide_time && (now - @guide_time) < guide_interval(dist)
      @guide_time = now
      return stop_guides(:loc_target_lost) unless target_valid?
      refresh_guide_path
      path = @guide_path
      if path && !path.empty? && !ledge_step?(path[0]) && !forced_step?(path[0]) &&
         !(PokeAccess::Pathfinder.engine_passable?($game_player.x, $game_player.y, path[0]) rescue true)
        if @blocked_recheck_at.nil? || (now - @blocked_recheck_at) >= RECHECK_BLOCKED_SEC
          @blocked_recheck_at = now
          @guide_fresh = nil
          refresh_guide_path
          path = @guide_path
        end
      else
        @blocked_recheck_at = nil
      end
      if path && path.empty?
        return announce_gate_hold if @guide_gate
        return announce_door_hold if @guide_door
        return announce_surf_hold if @guide_surf
        return announce_dive_leg_hold if @guide_dive_leg
        return announce_dive_hold if @guide_dive
        # A crossing she selected herself: standing on it, say which button works it, and do NOT call the
        # journey over -- pressing it is the point of having walked here.
        return nil if announce_crossing_target
        return stop_guides(:loc_arrived)
      end
      if path.nil?
        unless @guide_noroute
          @guide_noroute = true
          PokeAccess.speak(PokeAccess::I18n.t(no_route_key), false)
        end
        return noroute_cue(dist)
      end
      @guide_noroute = false
      @noroute_cue_at = nil
      announce_jump_step(path[0])
      guide_cue(path[0], dist)
    end

    # Runs each map frame while the step guide is on. Driven by the player's TILE and the target's, not by
    # a clock: the instruction only changes when one of them moves, so standing still costs one comparison
    # a frame and walking gets the next leg on the frame the player lands on it. Shares the cane's "no
    # route" latch so the pair never says it twice.
    def self.steps_tick
      return unless @steps
      return stop_guides(:loc_target_lost) unless target_valid?
      here = [$game_player.x, $game_player.y, @target.x, @target.y]
      return if @steps_at == here
      @steps_at = here
      refresh_guide_path
      path = @guide_path
      if path && path.empty?
        return announce_gate_hold if @guide_gate
        return announce_door_hold if @guide_door
        return announce_surf_hold if @guide_surf
        return announce_dive_leg_hold if @guide_dive_leg
        return announce_dive_hold if @guide_dive
        # A crossing she selected herself: standing on it, say which button works it, and do NOT call the
        # journey over -- pressing it is the point of having walked here.
        return nil if announce_crossing_target
        return stop_guides(:loc_arrived)
      end
      if path.nil?
        @steps_leg = nil
        unless @guide_noroute
          @guide_noroute = true
          PokeAccess.speak(PokeAccess::I18n.t(no_route_key), false)
        end
        return
      end
      @guide_noroute = false
      announce_leg(path)
    end

    # Speaks the leg at the head of the route, but only when it is NEW information. Walking a leg merely
    # shortens it, which the player already knows, so a falling count in the same direction passes in
    # silence; a different direction means the leg is done, and a LONGER one in the same direction means
    # the route was recomputed after a wrong turn -- both are worth saying.
    def self.announce_leg(path)
      leg = PokeAccess::Pathfinder.legs(path)[0]
      return if leg.nil?
      last = @steps_leg
      @steps_leg = leg
      return if last && last[0] == leg[0] && leg[1] <= last[1]
      announce_jump_step(path[0])
      PokeAccess.speak(PokeAccess::Pathfinder.leg_text(leg), false)
    end

    # The cue for an unreachable target: still points straight at it (so the guide keeps nudging the player
    # closer even when A* finds no route), but does NOT re-chime while standing on the same tile facing the
    # same way -- otherwise it gallops identically in place. A move (new tile or new straight direction)
    # speaks again. param dist manhattan distance to the target
    def self.noroute_cue(dist)
      dir = straight_dir(@target)
      here = [$game_player.x, $game_player.y, dir] rescue nil
      return if here && here == @noroute_cue_at
      @noroute_cue_at = here
      guide_cue(dir, dist)
    end

    # True if the next guide step is a ledge hop (the faced tile is a ledge), not a normal walk.
    def self.ledge_step?(d)
      return false if d.nil? || d == 0 || $game_map.nil? || $game_player.nil?
      fx, fy = step_tile($game_player.x, $game_player.y, d)
      PokeAccess::Terrain.ledge_at?(fx, fy)
    rescue StandardError
      false
    end

    # True if the next step is a forced-move tile the player BUMPS rather than walks onto (a diagonal
    # staircase). Its tile is impassable by design, so without this the blocked-path check reads a
    # perfectly good route as obstructed and re-plans on a timer for as long as the player stands there.
    def self.forced_step?(d)
      return false if d.nil? || d == 0 || $game_map.nil? || $game_player.nil?
      fx, fy = step_tile($game_player.x, $game_player.y, d)
      !PokeAccess::Pathfinder.forced_move_at(fx, fy, d).nil?
    rescue StandardError
      false
    end

    # The landing of a HOP from (x,y) facing d -- a bump on a sprite-less event that jumps her straight
    # over it, like Sonata Gym's hedges or the Black Market's gaps -- or nil. Diagonal carries (cave
    # staircases) are not hops: nobody would call those a jump.
    def self.hop_landing(x, y, d)
      fx, fy = step_tile(x, y, d)
      mv = PokeAccess::Pathfinder.forced_move_at(fx, fy, d)
      return nil if mv.nil?
      return nil if (PokeAccess::Pathfinder.player_passable?(x, y, d) rescue true)
      sx = fx - x; sy = fy - y
      return nil unless mv[0] * sy == mv[1] * sx && (mv[0] * sx + mv[1] * sy) >= 2
      [x + mv[0], y + mv[1]]
    rescue StandardError
      nil
    end

    # Drops the remembered jump tile (map change or guide shutdown), so a fresh map cannot inherit it.
    def self.forget_jump
      @jump_at = nil
    end

    # Speaks "jump <dir>" once when the next step is a ledge hop, so the player jumps it instead of
    # walking into it. Tracks the tile so it is not repeated on every chime.
    def self.announce_jump_step(d)
      unless ledge_step?(d) || (hop_landing($game_player.x, $game_player.y, d) rescue nil)
        @jump_at = nil
        return
      end
      here = [$game_player.x, $game_player.y]
      return if @jump_at == here
      @jump_at = here
      PokeAccess.speak(PokeAccess::I18n.t(:loc_jump, :dir => PokeAccess::I18n.t(DIR_NAMES[d])), false)
    rescue StandardError
      nil
    end

    # The tile reached by stepping one tile in an rpg maker direction from (x, y).
    def self.step_tile(x, y, dir)
      case dir
      when 8 then [x, y - 1]
      when 2 then [x, y + 1]
      when 4 then [x - 1, y]
      when 6 then [x + 1, y]
      else [x, y]
      end
    end

    # The tile a route step actually LANDS on: one tile normally, but TWO when the step crosses a ledge --
    # the pathfinder packs a ledge hop as a single direction whose landing is beyond the ledge tile
    # (ledge_jump's two-tile model), so a consumer advancing one tile per step desynchronises after every
    # hop and re-runs the full A* (the cached guide route was useless on ledge routes).
    def self.step_span(x, y, dir)
      fx, fy = step_tile(x, y, dir)
      if (PokeAccess::Terrain.ledge_at?(fx, fy) rescue false)
        [x + 2 * (fx - x), y + 2 * (fy - y)]
      else
        hop_landing(x, y, dir) || [fx, fy]
      end
    end

    # Advances the cached path to the player's tile by dropping walked steps. True if still on the path.
    def self.advance_guide_path(px, py)
      return false unless @guide_path && @guide_from
      x, y = @guide_from
      consumed = 0
      @guide_path.each do |d|
        break if [x, y] == [px, py]
        x, y = step_span(x, y, d)
        consumed += 1
      end
      return false unless [x, y] == [px, py]
      @guide_path = @guide_path[consumed..-1] || []
      @guide_from = [px, py]
      true
    end

    # Keeps the guide path current without re-running A* every tick: computed once and consumed as the
    # player follows it, recomputing only on deviation, target move, or freshness lapse. An UNREACHABLE
    # result (find_path nil) is remembered by [player_xy, target_xy] so the costly A* is not re-run every
    # tick while the player stands at the same spot for the same out-of-reach target -- the straight-line
    # no-route cue still sounds. The memo clears the moment the player moves, the target changes, or
    # something invalidates the pathfinder caches (a switch that opens a path ends an event -> forget_noroute).
    def self.refresh_guide_path
      px = $game_player.x; py = $game_player.y
      tx = @target.x; ty = @target.y
      now = PokeAccess.clock
      return if @guide_path && @guide_target == [tx, ty] && follow_cached_path(px, py, now)
      return if @guide_path.nil? && @noroute_key == [px, py, tx, ty]
      @guide_from = [px, py]
      @guide_target = [tx, ty]
      @guide_fresh = now
      remote = (PokeAccess::Locator.remote_target?(@target) rescue false)
      # A dive spot or a place to surface is pressed ON, not beside: the route ends on the tile itself.
      @guide_dive = dive_target?(@target)
      @guide_path = remote ? nil : (@guide_dive ? PokeAccess::Pathfinder.path_onto(tx, ty) : PokeAccess::Pathfinder.find_path(tx, ty))
      @guide_gate = nil
      @guide_door = nil
      @guide_surf_goal = nil
      @guide_dive_leg = nil
      @guide_dive_at = nil
      @gate_said = nil unless @guide_path.nil?
      if @guide_path.nil?
        # Nothing walkable. Before giving up, ask whether a field-move obstacle is the only thing in the
        # way -- a cuttable tree in a corridor used to make the whole cave behind it "no reachable route".
        # The cane then walks her AS FAR AS the tree and stops there naming it, never through it; once she
        # has cut it the plain route above exists and this branch is not taken again.
        gp = (PokeAccess::Pathfinder.find_path_gated(tx, ty) rescue nil)
        if gp
          lead, gate = (PokeAccess::Gates.up_to_first(gp[0]) rescue [nil, nil])
          ready = (PokeAccess::Gates.strength_ready? rescue nil)
          if gate && gate[1] == :push && ready == true
            # Strength is already switched on for this map, so every shove in this route is just another
            # keypress. Hand over the whole thing: pressing into the rock moves it, pressing again walks
            # into the square it left, and the guide's ordinary "2 east" is the correct instruction.
            @guide_path = gp[0]
            @guide_gate = nil
            @guide_surf = false
            @noroute_key = nil
            return
          elsif gate
            @guide_path = lead
            @guide_gate = gate
            @guide_surf = false
            @noroute_key = nil
            return
          end
        end
        # A door is an edge in the graph like any other. Route to the next one; walking into it is what opens
        # it. Arriving beside it is NOT arriving: the guide used to say "You have arrived" there and switch
        # itself off, so every door on a journey meant turning it back on. It holds instead (announce_door_hold)
        # and carries on from the far side, where the carried target puts the route back together.
        wp = (PokeAccess::Pathfinder.find_path_warp(
                (PokeAccess::Locator.target_map(@target) rescue nil), tx, ty) rescue nil)
        if wp
          @guide_path = wp[0]
          @guide_gate = nil
          # First door across water: hold at the shore for Surf, not at the door.
          @guide_surf = wp[4] ? true : false
          # A dive is not walked into, so it is never announced as a doorway.
          @guide_door = (wp[4] || wp[5]) ? nil : wp[3]
          @guide_surf_goal = wp[4] ? wp[3] : nil
          @guide_dive_leg = wp[5]
          @guide_dive_at = wp[5] ? wp[3] : nil
          @noroute_key = nil
          return
        end
        sp = (PokeAccess::Pathfinder.surf_launch(tx, ty) rescue nil)
        if sp.nil?
          # Across the water AND past an obstacle on the far side. Worth the trip only if she can deal with
          # the obstacle when she gets there -- otherwise the cane would ferry her to the foot of a cliff she
          # has no way up, so it stays a no-route and the locator's phrase says what is missing.
          sg = (PokeAccess::Pathfinder.surf_launch_gated(tx, ty) rescue nil)
          sp = sg[0] if sg && sg[1].none? { |g| PokeAccess::Gates.usable?(g[0]) == false }
        end
        @guide_surf = !sp.nil?
        @guide_path = sp
        @noroute_key = @guide_path.nil? ? [px, py, tx, ty] : nil
      else
        @guide_surf = false
        @surf_said = nil
        @noroute_key = nil
        # Heading for a doorway itself: arriving beside it is "go through", not "you have arrived".
        @guide_door = [tx, ty] if !remote && (PokeAccess::Locator.transfer_event?(@target) rescue false)
      end
    end

    # Standing on the shore the route stops at: name the side the water is on and leave the guide RUNNING.
    # Surf IS a field-move gate; the pathfinder just models it as a second flood rather than as an obstacle
    # event, so it needs the same hold announce_gate_hold gives a cuttable tree.
    #
    # Switching both guides off here was the old behaviour, and it is what "walks you to the shore and
    # expects you to work out the rest" means: crossing meant re-selecting the target and turning the cane
    # back on. Nothing else has to change for the crossing to work -- mounting Surf moves the player one
    # tile, which is exactly the deviation that makes the cached path recompute, and the route graph is
    # already keyed on the surfing flag, so from the water find_path routes across it normally.
    def self.announce_surf_hold
      key = [$game_player.x, $game_player.y]
      return if @surf_said == key
      @surf_said = key
      d = surf_side
      PokeAccess.speak(d ? PokeAccess::I18n.t(:loc_surf_ahead, :dir => PokeAccess::I18n.t(d)) :
                            PokeAccess::I18n.t(:loc_surf_here), false)
      nil
    end

    # True for a dive spot or a place to surface from the scanner.
    def self.dive_target?(t)
      t.is_a?(SurfaceTarget) && [:surf_dive, :surf_surface].include?(t.key)
    rescue StandardError
      false
    end

    # The same hold for a dive that is one LEG of a longer journey (the target is on the layer below, or
    # beyond it): she is standing on the water the route crosses, and what happens next is a button press.
    # What to say when she is standing on a crossing that is pressed rather than walked into. Dive was
    # the only one of these for a long time and the test was a dive/surface binary; a WarpNet link source
    # can now contribute others (Insurgence's Tesseract), and an unnamed one was being announced as
    # "Place to surface", which is worse than silence -- it tells her to do something impossible.
    CROSSING_HOLD = { :dive => :loc_dive_here, :surface => :loc_surface_here,
                      :tesseract => :loc_tesseract_here,
                      :heartswap => :loc_heartswap_here,
                      :hyperspace => :loc_hyperspace_here }

    # The spoken line for a crossing kind, or nil when nothing sensible can be said about it.
    def self.crossing_hold_key(kind)
      CROSSING_HOLD[kind]
    end

    def self.announce_dive_leg_hold
      d = @guide_dive_at
      return nil if d.nil?
      return nil unless [$game_player.x, $game_player.y] == [d[0], d[1]]
      k = crossing_hold_key(@guide_dive_leg)
      return nil if k.nil?
      key = [d[0], d[1], @guide_dive_leg]
      return nil if @dive_said == key
      @dive_said = key
      PokeAccess.speak(PokeAccess::I18n.t(k), false)
      nil
    rescue StandardError
      nil
    end

    # Standing ON the dive spot or the place to surface: say what the confirm button does here, once, and keep
    # the guide running -- the dive itself changes the map, and that ends the journey (clear_targets).
    def self.announce_dive_hold
      return stop_guides(:loc_arrived) unless [$game_player.x, $game_player.y] == [@target.x, @target.y]
      key = [$game_player.x, $game_player.y, @target.key]
      return if @dive_said == key
      @dive_said = key
      PokeAccess.speak(PokeAccess::I18n.t(@target.key == :surf_dive ? :loc_dive_here : :loc_surface_here), false)
      nil
    rescue StandardError
      nil
    end

    # Arriving at a crossing she selected herself (a Tesseract spot from the scanner, say): stand on it and
    # be told which button does the thing, the same as a dive spot. Without this the guide reached the tile
    # and simply said "you have arrived", leaving the one action that matters unspoken.
    def self.announce_crossing_target
      return nil unless @target
      kind = (PokeAccess::Locator.target_crossing_kind(@target) rescue nil)
      k = kind && crossing_hold_key(kind)
      return nil if k.nil?
      return nil unless [$game_player.x, $game_player.y] == [@target.x, @target.y]
      key = [$game_player.x, $game_player.y, kind]
      return nil if @dive_said == key
      @dive_said = key
      PokeAccess.speak(PokeAccess::I18n.t(k), false)
      true
    rescue StandardError
      nil
    end

    # Which side to face to launch: of the surfable tiles next to the player, the one that ends up nearest
    # the target. The nearest water is not the answer -- a shore tile can touch a pond going the wrong way
    # -- so the choice is made by whether the step continues the journey.
    def self.surf_side
      px = $game_player.x; py = $game_player.y
      # Crossing water to reach a DOOR, the door is where the launch was planned for, not the final target
      # (which may be on another map entirely).
      tx, ty = (@guide_surf_goal || [@target.x, @target.y])
      # The side the route was planned to launch from, when she is standing where it was planned: a shore
      # can touch two bodies of water, and only one of them leads to the target.
      pd = (PokeAccess::Pathfinder.planned_launch_dir(tx, ty) rescue nil)
      return { 4 => :dir_o, 6 => :dir_e, 8 => :dir_n, 2 => :dir_s }[pd] if pd
      best = nil; bestd = nil
      # Only sides the game will launch from: water behind a railing is still water, and naming it sends her
      # pressing the action button at nothing.
      ok = (PokeAccess::Pathfinder.launch_dirs(px, py) rescue [])
      [[4, -1, 0], [6, 1, 0], [8, 0, -1], [2, 0, 1]].each do |dir, dx, dy|
        nx = px + dx; ny = py + dy
        next unless ok.include?(dir)
        d = (tx - nx).abs + (ty - ny).abs
        next unless bestd.nil? || d < bestd
        bestd = d; best = dir
      end
      return nil if best.nil?
      { 4 => :dir_o, 6 => :dir_e, 8 => :dir_n, 2 => :dir_s }[best]
    rescue StandardError
      nil
    end

    # Standing at the obstacle the route stops at: name it and the move that clears it, ONCE, and leave
    # the guide RUNNING. Stopping would be the wrong call -- the moment she cuts the tree the plain route
    # exists, and the next refresh picks it up and carries on with no second keypress from her.
    def self.announce_gate_hold
      g = @guide_gate
      return unless g
      key = [g[2], g[3]]
      return if @gate_said == key
      @gate_said = key
      t = gate_arrival_text(g)
      PokeAccess.speak(t, false) if t
      nil
    end

    # Standing beside the door the route goes through: say which side it is on, once per tile, and keep the
    # guide running. "Door to the south" is the whole instruction; the game does the rest when she walks in.
    def self.announce_door_hold
      d = @guide_door
      return unless d
      key = [$game_player.x, $game_player.y, d[0], d[1]]
      return if @door_said == key
      @door_said = key
      dir = gate_dir_key([nil, nil, d[0], d[1]])
      # When the doorway IS the destination there is no route after it to continue.
      final = @target && [@target.x, @target.y] == d && !(PokeAccess::Locator.remote_target?(@target) rescue false)
      PokeAccess.speak(PokeAccess::I18n.t(final ? :loc_door_target : :loc_door_ahead, :dir => PokeAccess::I18n.t(dir)), false)
      nil
    rescue StandardError
      nil
    end

    # The door the current guide route leads to, as [x, y], or nil.
    def self.guide_door; @guide_door; end

    # The obstacle the current guide route stops at, or nil. Set by refresh_guide_path.
    def self.guide_gate; @guide_gate; end

    # What to say on arriving at the obstacle the route stops at: "Breakable rock, use Rock Smash", and
    # the party check appended only when it came back a definite no.
    def self.gate_arrival_text(gate)
      what = PokeAccess::I18n.t(gate[1] == :push ? :loc_strength_boulder : gate_name_key(gate))
      move = PokeAccess::Gates.move_name(gate[0])
      item = nil
      key = if PokeAccess::Gates.usable?(gate[0]) == false
              (item = PokeAccess::Gates.unlock_item(gate[0])) ? :loc_gate_ahead_item : :loc_gate_ahead_unknown
            elsif gate[1] == :push then :loc_gate_ahead_push
            elsif gate[1] == :climb then :loc_gate_ahead_climb
            else :loc_gate_ahead
            end
      PokeAccess::I18n.t(key, :what => what, :move => move, :item => item.to_s,
                         :dir => PokeAccess::I18n.t(gate_dir_key(gate)))
    rescue StandardError
      nil
    end

    # The locator name key for an obstacle, from the move that clears it.
    def self.gate_name_key(gate)
      k = (PokeAccess::Gates.name_key(gate[0]) rescue nil)
      return k if k
      case gate[0]
      when :cut       then :loc_cut_tree
      when :rocksmash then :loc_rock_smash
      when :headbutt  then :loc_headbutt_tree
      when :rockclimb then :loc_rock_climb
      else :loc_strength_boulder
      end
    end

    # The side the obstacle is on from where she stands, as a direction key. A climb only starts facing the
    # face -- up to climb, down to descend -- so for that one the side is part of the instruction.
    def self.gate_dir_key(gate)
      dx = gate[2].to_i - $game_player.x; dy = gate[3].to_i - $game_player.y
      if dx.abs > dy.abs then (dx > 0 ? :dir_e : :dir_o)
      else (dy > 0 ? :dir_s : :dir_n)
      end
    rescue StandardError
      :dir_n
    end

    # Drops the remembered "no route" result so the next refresh re-runs A* (e.g. after a switch opens a
    # path). Called from the same event-end hook that invalidates the pathfinder caches.
    def self.forget_noroute; @noroute_key = nil; end

    # Everything the guides remember about the route on the map just left. Coordinates on one map mean
    # nothing on the next, and a "no route" latched there must not silence the route that exists here.
    def self.forget_route_state
      @noroute_key = nil
      @guide_path = nil
      @guide_noroute = nil
      @steps_at = nil
      @steps_leg = nil
      @door_said = nil
      @surf_said = nil
      @gate_said = nil
    end

    # Tries to reuse the cached route. True while the player is still on it and it is valid; inside the
    # freshness window that is trusted, past it the route is re-checked with a cheap linear walkability
    # scan (not a full A*), so guiding to a far target never pays for a periodic full search.
    def self.follow_cached_path(px, py, now)
      return false unless [px, py] == @guide_from || advance_guide_path(px, py)
      return true if @guide_fresh && (now - @guide_fresh) < guide_refresh_seconds
      @guide_fresh = now
      path_walkable?(px, py, @guide_path)
    end

    # True if every step of a cached route is still walkable from a start tile (a ledge hop counts as
    # walkable and advances to its LANDING, so the steps after a hop validate from the right tile),
    # scanned linearly with no node expansion -- far cheaper than rerunning A*.
    def self.path_walkable?(px, py, path)
      return true if path.nil? || path.empty?
      x = px; y = py
      path.each do |d|
        fx, fy = step_tile(x, y, d)
        if (PokeAccess::Terrain.ledge_at?(fx, fy) rescue false)
          x = x + 2 * (fx - x); y = y + 2 * (fy - y)
          next
        end
        # The mod's own answer, not the raw engine's: afloat, the engine calls every water tile except the
        # one she faces a wall, so this check threw the cached route away every second while she surfed and
        # the recompute was the stutter.
        return false unless (PokeAccess::Pathfinder.engine_passable?(x, y, d) rescue true)
        x = fx; y = fy
      end
      true
    end
  end
end
PokeAccess::Caches.register(:guide_jump) { PokeAccess::Locator.forget_jump }
