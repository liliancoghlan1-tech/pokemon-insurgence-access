module PokeAccess
  # Hidden roamers: an event with NO graphic at all that the engine nonetheless walks around the map under
  # its own autonomous movement. That combination is a deliberate game design -- something you are meant to
  # hunt without seeing it -- and it is invisible to every other reader in the mod, because each of those
  # keys off a sprite, a trigger or a script the event does not have.
  #
  # Insurgence's journalist missions are the case this was written for: an unseen Pokemon random-walks a
  # whole desert, the game flashes its "Dust" battle animation on it a couple of times a second to show
  # where the sand is rustling, and you catch it by standing on its tile. The NPC beside you says so out
  # loud ("I've seen some of the sand rustling, but whatever is under the surface never stops moving"), so
  # the tell is intended -- but Insurgence's Dust animation carries NO sound effect whatsoever, which makes
  # the entire mission a purely visual hunt and flatly unplayable by ear.
  #
  # Two answers, and the split matters:
  #   * the FLASH is mirrored as a positional cue at the roamer's tile (see tick). That is not help, it is
  #     the game's own signal moved into a channel she can receive -- a sighted player gets exactly this,
  #     at exactly this rate, and no more. The hunt stays the hunt.
  #   * the roamer joins the LOCATOR as its own category, so the cane can route to it. That is help, and it
  #     is deliberate: the flash only carries while the thing is within earshot, and a random walk across a
  #     100x120 map is otherwise a coin-flip search with no way back to the trail once it is lost.
  module Roamers
    # RMXP autonomous movement types. 0 (fixed) is what every trigger tile, door, item ball and standing
    # NPC uses; 1 random, 2 approach and 3 custom route all mean the ENGINE is walking this event about on
    # its own, which is the half of the definition that a plain invisible trigger can never satisfy.
    MOVING_TYPES = [1, 2, 3]

    # RPG::MoveCommand codes that actually DISPLACE an event (the eight directions, the two player-relative
    # moves, random, forward, back, jump). Everything above them only turns, waits, or changes how the event
    # looks, and a route made only of those leaves it standing exactly where it was.
    MOVE_CODES = (1..14)

    # Shortest gap (seconds) between two flash cues. The flash is driven by a parallel process rolling a
    # 1-in-31 die every frame, so a run of ones would otherwise fire the cue several times inside one
    # animation and smear it into a hiss.
    CUE_GAP = 0.18

    @cache = nil
    @cache_map = nil
    @anim = {}
    @cue_time = nil

    # Drops the per-map state: the roamer list and the per-event animation edge memo. Event ids repeat
    # across maps, so carrying either one over would let map A's event 3 answer for map B's.
    def self.reset_map_state
      @cache = nil; @cache_map = nil; @anim = {}; @cue_time = nil
    rescue StandardError
      nil
    end

    # Drops just the cached list so the next look rescans. WHICH events are roamers is read off the page
    # that is currently active -- and the page is exactly what the mission flips when the thing is caught
    # (its later pages are fixed and graphic-less, so it stops being a roamer and leaves the locator by
    # itself). Keyed on the map alone, the list would keep offering a target that is no longer there.
    def self.forget
      @cache = nil
      @cache_map = nil
    end

    # True if an event is a hidden roamer: no sprite and no tile graphic, an active page, and autonomous
    # movement. Read live off the event, never off the map file, so a page change answers immediately.
    #
    # The graphic test is Locator.has_graphic?, deliberately: an event whose move route SETS a sprite (the
    # Helios Sewers fans do exactly that on their first step) is blank in the map data and visible in the
    # running game, and only the running game is right.
    def self.roamer?(ev)
      return false unless ev
      return false if PokeAccess.ivar(ev, :@erased) == true
      return false if PokeAccess.ivar(ev, :@list).nil?
      return false if (PokeAccess::Locator.has_graphic?(ev) rescue true)
      # A door is never a quarry. Said first because it is the cheap, certain half of the answer, and
      # because it is the false positive this rule was written for: Suntouched City's walk-through to the
      # south half of the town is a copy of a "spinning fan" template event, blank and move_type 3, and it
      # was being offered as something to hunt on the map she was standing on.
      return false if (PokeAccess::Locator.transfer_event?(ev) rescue false)
      mt = PokeAccess.ivar_i(ev, :@move_type, 0)
      return false unless MOVING_TYPES.include?(mt)
      mt == 3 ? route_moves?(ev) : true
    rescue StandardError
      false
    end

    # True if a custom move route would actually carry the event somewhere. Move type 3 is the one that
    # takes a hand-written route, and a route is not proof of motion: the template above animates itself
    # with three Change Graphic commands and a pair of waits and never takes a step. Every blank move-type-3
    # event in Insurgence -- eleven of them, against three real roamers -- is a copy of exactly that.
    def self.route_moves?(ev)
      r = PokeAccess.ivar(ev, :@move_route) || PokeAccess.ivar(ev, :@original_move_route)
      list = (r.list rescue nil)
      return false unless list.is_a?(Array)
      list.any? { |c| MOVE_CODES.include?((c.code rescue 0)) }
    rescue StandardError
      false
    end

    # The roamers on the current map, cached until a page change (see forget) or a map change.
    def self.on_map
      mid = ($game_map.map_id rescue nil)
      return [] if mid.nil?
      if @cache.nil? || @cache_map != mid
        @cache_map = mid
        @cache = $game_map.events.values.select { |ev| roamer?(ev) }
      end
      # Re-asked on every read, not just on the rebuild. The SCAN is what costs (every event on the map);
      # re-testing the nought-or-one that passed costs nothing, and it closes a staleness the page-change
      # invalidation cannot see: an autonomous move route that changes an event's own graphic has not run
      # yet during the first frames on a map, so an event that is about to become visible looks blank
      # exactly when the list is built.
      @cache = @cache.select { |ev| roamer?(ev) } unless @cache.empty?
      @cache
    rescue StandardError
      []
    end

    # True when this map holds at least one roamer, which is what gates the locator category and the cue.
    def self.any?
      !on_map.empty?
    end

    # Runs every map frame: mirrors the game's flash as a positional cue.
    #
    # Edge-triggered on the event's animation id. RMXP's own sprite layer clears @animation_id back to 0
    # the same frame it starts drawing (Sprite_Character#update), and the map's event interpreters run
    # BEFORE Game_Player#update, which is where this is called from -- so a flash is visible here for
    # exactly the one frame between being set and being consumed, and one flash makes one cue.
    def self.tick
      return unless $game_map && $game_player
      # nav_off only: the cue survives the "basic" sound-navigation mode, which silences the sonar's
      # paced emitters. Those are convenience; this one is the game telling the player where its quarry
      # is, and a player who turned the sonar down has not asked to stop being told that.
      return if (PokeAccess::Audio3D.nav_off? rescue false)
      list = on_map
      return if list.empty?
      busy = (PokeAccess::Spatial.busy? rescue false)
      list.each do |ev|
        id = PokeAccess.ivar_i(ev, :@animation_id, 0)
        was = @anim[ev.id]
        @anim[ev.id] = id
        next if busy
        next unless id != 0 && (was.nil? || was == 0)
        flash(ev)
      end
    rescue StandardError
      nil
    end

    # Plays the rustle at a roamer's tile: binaural through the 3D engine, or pre-panned by side on the
    # flat channel when that engine is unavailable. Out of earshot it is silent rather than centred -- a
    # cue with no direction in it would read as "right here", which is the one thing it must never say.
    def self.flash(ev)
      now = PokeAccess.clock
      return if @cue_time && (now - @cue_time) < CUE_GAP
      dx = ev.x - $game_player.x
      dy = ev.y - $game_player.y
      return if (dx.abs + dy.abs) > (PokeAccess::Audio3D.range rescue 12)
      @cue_time = now
      # drop_occluded false: a top-down map draws the flash straight through walls, so hiding the cue
      # behind one would take away a signal the sighted player is still getting. The soundscape's
      # occlusion setting still MUFFLES it, which is the part that carries information about the room.
      return if (PokeAccess::Audio3D.play_at(:roamer, ev.x, ev.y, nil, false) rescue false)
      v = (PokeAccess::Config.event_volume rescue 70)
      return if v.nil? || v <= 0
      file = dx < 0 ? "pa3d_roamer_l" : (dx > 0 ? "pa3d_roamer_r" : "pa3d_roamer_c")
      PokeAccess::Spatial.cue(file, v)
    rescue StandardError
      nil
    end
  end
end

# Roamers die with the map, like every other per-map memo (the shared reset point Caches drives).
PokeAccess::Caches.register(:roamers) { PokeAccess::Roamers.reset_map_state }
