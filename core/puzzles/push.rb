module PokeAccess
  # Puzzle kind :push -- a boulder you shove by WALKING INTO IT.
  #
  # This is not the Strength boulder that Gates and the Pathfinder already understand. That one is an
  # engine feature: $PokemonMap.strengthUsed gates it, pbPushThisEvent moves it, and the push search in
  # Pathfinder routes around it. This one is a hand-built event on one map -- trigger "Player Touch",
  # a branch per facing, and a Set Move Route that steps the event one tile. The engine knows nothing
  # about it, so neither did we: to the locator it was simply an object called "boulder", and nothing
  # said which side to stand on, which way it would go, or whether this shove was the one that ruins it.
  #
  # Sighted, you read that off the screen -- the lake is over there, the boulder is here, so push left.
  # Blind, you cannot, and a wrong shove down a dead-end corridor is unrecoverable without walking out of
  # the cave to reset the map. So the profile carries a POLICY: for every tile the boulder can reach, the
  # tile to stand on, the direction to press, and how many shoves remain. That table is computed offline
  # from the map's own data (see the tools note in the profile), which is why nothing here searches.
  #
  # What this module does at runtime is only lookup and speech: where the boulder is, where to stand,
  # which way to press, and -- because a 60-shove haul is impossible to hold in your head -- a mark on
  # the tile to stand on, so the existing cane and step guides walk you there.
  module Push
    # rpg direction code => [dx, dy] and its spoken name.
    DIRS = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }
    DIR_KEY = { 8 => :dir_up, 2 => :dir_down, 4 => :dir_left, 6 => :dir_right }

    @map = nil        # map the runtime state belongs to
    @last = nil       # last seen boulder tile, to notice a shove
    @mark = nil       # [map id, x, y] our "stand here" mark currently sits on
    @solved = nil     # last seen solved state, so the win is announced once

    # The boulder event, or nil when the map has none (or it has finished and erased itself).
    def self.event(d)
      return nil unless $game_map && d[:event]
      ev = $game_map.events[d[:event]]
      return nil unless ev
      # A finished boulder switches to a page with no graphic; treat that as gone rather than as a target.
      return nil if (ev.character_name.to_s.empty? rescue false)
      ev
    rescue StandardError
      nil
    end

    # The boulder's tile as [x, y], or nil.
    def self.tile(d)
      ev = event(d)
      ev ? [ev.x, ev.y] : nil
    end

    def self.solved?(d)
      d[:solved] ? !!(d[:solved].call rescue false) : false
    end

    # Active while the boulder is unsolved and NEAR HER.
    #
    # "Active" is what hands this the info key (Keys.puzzle_owns_info?), and Fiery Caverns is an
    # eighty-by-hundred map she has plenty of other reasons to press it on. Claiming the key for the
    # whole map would have cost her the ordinary readout everywhere on it for the length of the haul,
    # which is most of an evening. Within :radius of the boulder she is doing the puzzle; outside it she
    # is not, and the locator still lists the boulder as an object she can target from anywhere.
    def self.active?(d)
      return false if solved?(d)
      t = tile(d)
      return false unless t
      r = d[:radius] || 20
      (t[0] - $game_player.x).abs + (t[1] - $game_player.y).abs <= r
    rescue StandardError
      false
    end

    # True when the boulder is on a tile from which the NEXT shove wins.
    def self.winning?(d, t)
      (d[:wins] || []).include?(t)
    end

    # The policy row for the boulder's current tile: [stand_x, stand_y, dir, pushes_left], or nil when
    # the boulder has been shoved somewhere with no route left.
    def self.action(d, t = nil)
      t ||= tile(d)
      return nil unless t
      (d[:policy] || {})[t]
    end

    # The tile to stand on for the next shove: the policy's, or (on a winning tile) the one the final
    # shove is made from.
    def self.stand(d, t = nil)
      t ||= tile(d)
      return nil unless t
      if winning?(d, t)
        dx, dy = DIRS[d[:win_dir] || 4]
        return [t[0] - dx, t[1] - dy]
      end
      a = action(d, t)
      a ? [a[0], a[1]] : nil
    end

    # The direction to press for the next shove.
    def self.push_dir(d, t = nil)
      t ||= tile(d)
      return nil unless t
      return (d[:win_dir] || 4) if winning?(d, t)
      a = action(d, t)
      a ? a[2] : nil
    end

    # "3 left, 2 up" from the player to a tile.
    def self.phrase_to(t)
      PokeAccess::Locator.dir_phrase(t[0] - $game_player.x, t[1] - $game_player.y)
    end

    def self.dir_name(dir)
      PokeAccess::I18n.t(DIR_KEY[dir] || :dir_left)
    end

    # ---------------------------------------------------------------- frame

    # Per-frame: announce the win once, announce each shove, and keep the "stand here" mark where the
    # next shove is made from.
    def self.tick(d)
      if $game_map.map_id != @map
        @map = $game_map.map_id
        @last = tile(d)
        @solved = solved?(d)
        refresh_mark(d)
        return
      end
      if solved?(d)
        unless @solved
          @solved = true
          clear_mark(d)
          msg = d[:solved_msg] ? PokeAccess::I18n.t(d[:solved_msg]) : PokeAccess::I18n.t(:puzzle_solved)
          PokeAccess.speak(msg, false)
        end
        return
      end
      @solved = false
      t = tile(d)
      return if t == @last
      @last = t
      return unless t
      refresh_mark(d)
      PokeAccess.speak(moved_text(d, t), false)
    rescue StandardError
      nil
    end

    # What is said the moment the boulder moves: where it went, and what to do next.
    def self.moved_text(d, t)
      parts = [PokeAccess::I18n.t(:push_moved, :where => phrase_to(t))]
      parts.push(next_text(d, t))
      parts.compact.join(". ")
    end

    # The "what now" line, shared by the shove announcement and the info key.
    def self.next_text(d, t)
      if winning?(d, t)
        s = stand(d, t)
        return PokeAccess::I18n.t(:push_final_here, :dir => dir_name(push_dir(d, t))) if on_tile?(s)
        return PokeAccess::I18n.t(:push_final, :where => phrase_to(s), :dir => dir_name(push_dir(d, t)))
      end
      a = action(d, t)
      return PokeAccess::I18n.t(:push_stuck) unless a
      s = [a[0], a[1]]
      return PokeAccess::I18n.t(:push_here, :dir => dir_name(a[2]), :n => a[3]) if on_tile?(s)
      PokeAccess::I18n.t(:push_next, :where => phrase_to(s), :dir => dir_name(a[2]), :n => a[3])
    end

    def self.on_tile?(t)
      t && $game_player.x == t[0] && $game_player.y == t[1]
    end

    # ---------------------------------------------------------------- info key

    # The info-key readout: where the boulder is, then what to do next, plus the assist-only hint.
    def self.read(d)
      t = tile(d)
      unless t
        PokeAccess.speak(PokeAccess::I18n.t(:push_gone), true)
        return
      end
      parts = [PokeAccess::I18n.t(:push_where, :where => phrase_to(t))]
      parts.push(next_text(d, t))
      if (PokeAccess::Puzzles.assist? rescue false) && d[:hint]
        parts.push(PokeAccess::I18n.t(d[:hint]))
      end
      PokeAccess.speak(parts.compact.join(". "), true)
    rescue StandardError
      nil
    end

    # ---------------------------------------------------------------- the mark

    # Puts (or moves) a single named mark on the tile the next shove is made from, so the cane and the
    # step guide -- which already route to a mark -- can walk her there. One mark, moved as the boulder
    # moves, removed when the puzzle is done or the boulder is stuck; it never accumulates.
    def self.refresh_mark(d)
      return unless d[:mark] != false
      t = tile(d)
      s = t && stand(d, t)
      if s.nil?
        clear_mark(d)
        return
      end
      here = [$game_map.map_id, s[0], s[1]]
      return if @mark == here
      clear_mark(d)
      PokeAccess::Marks.set(here[0], here[1], here[2], PokeAccess::I18n.t(:push_mark))
      @mark = here
    rescue StandardError
      nil
    end

    # Removes our mark, and only ours: a mark she placed herself on that tile keeps its own name and is
    # left alone. The mark carries its own map id, because this also runs from the map-change hook, by
    # which time $game_map is already the map she has walked into.
    def self.clear_mark(d = nil)
      return unless @mark
      mine = PokeAccess::I18n.t(:push_mark)
      was = (PokeAccess::Marks.get(@mark[0], @mark[1], @mark[2]) rescue nil)
      PokeAccess::Marks.delete(@mark[0], @mark[1], @mark[2]) if was.to_s == mine.to_s
      @mark = nil
    rescue StandardError
      @mark = nil
    end

    # Called when the map changes or state is dropped. The mark goes with it: leaving the map puts the
    # boulder back at its starting tile, so a mark left on the old route would point at nothing.
    def self.reset
      clear_mark
      @map = nil; @last = nil; @solved = nil
    end
  end
end
