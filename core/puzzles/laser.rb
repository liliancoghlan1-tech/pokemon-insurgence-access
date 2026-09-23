module PokeAccess
  # The mirror-and-beam grid (Pokemon Insurgence's Erebus Gym, maps 486/542/543).
  #
  # A beam leaves a fixed emitter and steps one tile at a time. It CONTINUES ONLY WHERE AN EVENT STANDS:
  # the hundreds of "laser" events on those maps are the track it may run along, and the first empty tile
  # ends it. An event named "c" is a mirror; the beam turns there, or is swallowed if it arrives at a face
  # the mirror is not open on. Reaching a receiver opens a door.
  #
  # Everything here is lifted from the game's own code, not guessed:
  #   pbDrawLasers          179_ChallengeChampionship.rb:4199   the walk, and the emitter coordinates
  #   getDirectionReflect   179_ChallengeChampionship.rb:4314   the reflection table
  #   pbTurnMirror          179_ChallengeChampionship.rb:4173   the rotate prompt
  #   common event 53       "mirror"                            stand beside it, face it, press the action key
  #   $game_variables[144]  rotation per event id, 0..3         $game_variables[145] which tiles are lit
  #
  # WHAT THIS DOES AND DOES NOT TELL HER. A sighted player sees three things: where the mirrors are, which
  # way each one is turned, and the line the beam draws. All three are given here and nothing more -- the
  # route through the grid is hers to work out. Only with puzzle_assist on does it add which settings would
  # accept the beam that is currently arriving, and even that is a fact off the screen, not the answer.
  module Laser
    # dir: 0 up, 1 right, 2 down, 3 left -- the game's own numbering.
    DIRS = [0, 1, 2, 3]
    DIR_KEY = { 0 => :dir_up, 1 => :dir_right, 2 => :dir_down, 3 => :dir_left }
    # A mirror is an elbow joining two of its four faces, and rotating steps it clockwise through these.
    FACE_KEY = { 0 => :laser_f0, 1 => :laser_f1, 2 => :laser_f2, 3 => :laser_f3 }

    # rotation => { travel direction in => travel direction out }. Built from getDirectionReflect, which is
    # written against translateDir(travel) = (travel + 2) % 4 -- the way the beam came FROM.
    def self.table
      @table ||= begin
        t = {}
        (0..3).each do |rot|
          m = {}
          DIRS.each do |travel|
            f = (travel + 2) % 4
            out = case rot
                  when 0 then (f == 0 ? 3 : (f == 3 ? 0 : -1))
                  when 1 then (f == 0 ? 1 : (f == 1 ? 0 : -1))
                  when 2 then (f == 2 ? 1 : (f == 1 ? 2 : -1))
                  else        (f == 2 ? 3 : (f == 3 ? 2 : -1))
                  end
            m[travel] = out if out >= 0
          end
          t[rot] = m
        end
        t
      end
    end

    def self.mirror?(ev)
      (ev.name.to_s rescue "").include?("c")
    rescue StandardError
      false
    end

    def self.beam_tile?(ev)
      (ev.name.to_s rescue "") == "laser"
    rescue StandardError
      false
    end

    # event id => rotation, straight out of the variable the game keeps it in.
    def self.rotation(eid)
      a = ($game_variables[144] rescue nil)
      (a.is_a?(Array) && a[eid].is_a?(Integer)) ? (a[eid] % 4) : 0
    rescue StandardError
      0
    end

    # (x,y) => event, for this map. Rebuilt per map; the events never move.
    def self.index
      mid = ($game_map.map_id rescue nil)
      if @idx_map != mid
        @idx_map = mid
        @idx = {}
        ($game_map.events.each_value { |ev| @idx[[ev.x, ev.y]] = ev } rescue nil)
      end
      @idx
    rescue StandardError
      {}
    end

    def self.mirrors
      index.values.select { |ev| mirror?(ev) }.sort_by { |ev| [ev.y, ev.x] }
    rescue StandardError
      []
    end

    # Walk one beam. Returns [legs, ending], where legs is [[dir, tiles, mirror_or_nil], ...] and ending is
    # :receiver, :absorbed or :dead_end, plus the tile it finished on.
    def self.trace(sx, sy, sd, receivers)
      idx = index
      x = sx; y = sy; d = sd
      legs = [[d, 0, nil]]
      seen = {}
      600.times do
        if d == 0 || d == 2
          y += d - 1
        elsif d == 1
          x += 1
        else
          x -= 1
        end
        ev = idx[[x, y]]
        return [legs, :dead_end, [x, y]] if ev.nil?
        k = [x, y, d]
        return [legs, :loop, [x, y]] if seen[k]
        seen[k] = true
        legs[-1][1] += 1
        return [legs, :receiver, [x, y]] if receivers.include?([x, y])
        if mirror?(ev)
          nd = table[rotation(ev.id)][d]
          return [legs, :absorbed, [x, y]] if nd.nil?
          legs[-1][2] = [x, y]
          d = nd
          legs.push([d, 0, nil])
        end
      end
      [legs, :loop, [x, y]]
    rescue StandardError
      [[], :dead_end, [sx, sy]]
    end

    def self.beams(d)
      (d[:beams] || [])
    end

    def self.receivers(d)
      (d[:receivers] || [])
    end

    def self.active?(d)
      return false if mirrors.empty?
      !beams(d).empty?
    rescue StandardError
      false
    end

    # ---------------------------------------------------------------- speech

    def self.at(x, y)
      PokeAccess::I18n.t(:laser_at, :x => x.to_s, :y => y.to_s)
    end

    def self.dir_name(dir)
      PokeAccess::I18n.t(DIR_KEY[dir] || :dir_up)
    end

    def self.face_name(rot)
      PokeAccess::I18n.t(FACE_KEY[rot % 4])
    end

    # One beam as a sentence: each straight run, the mirror that turned it, and how it finished.
    def self.beam_phrase(d, n, spec)
      legs, how, last = trace(spec[0], spec[1], spec[2], receivers(d))
      parts = []
      legs.each do |dir, tiles, turn|
        next if tiles == 0
        if turn
          parts.push(PokeAccess::I18n.t(:laser_run_mirror, :n => tiles.to_s,
                                        :dir => dir_name(dir), :where => at(turn[0], turn[1])))
        else
          parts.push(PokeAccess::I18n.t(:laser_run, :n => tiles.to_s, :dir => dir_name(dir)))
        end
      end
      tail = case how
             when :receiver then PokeAccess::I18n.t(:laser_end_receiver)
             when :absorbed then PokeAccess::I18n.t(:laser_end_absorbed, :where => at(last[0], last[1]))
             else PokeAccess::I18n.t(:laser_end_dead, :where => at(last[0], last[1]))
             end
      PokeAccess::I18n.t(:laser_beam, :n => n.to_s, :path => parts.join(", "), :end => tail)
    rescue StandardError
      nil
    end

    # The info key: every beam in full, then every mirror and which way it is turned.
    def self.read(d)
      lines = []
      beams(d).each_with_index { |spec, i| p = beam_phrase(d, i + 1, spec); lines.push(p) if p }
      ms = mirrors
      unless ms.empty?
        bits = ms.map { |ev| PokeAccess::I18n.t(:laser_mirror_at, :where => at(ev.x, ev.y),
                                                :faces => face_name(rotation(ev.id))) }
        lines.push(PokeAccess::I18n.t(:laser_mirrors, :list => bits.join(", ")))
      end
      lines.concat(assist_lines(d)) if (PokeAccess::Puzzles.assist? rescue false)
      PokeAccess.speak(lines.join(". "), true) unless lines.empty?
    rescue StandardError
      nil
    end

    # With assist on: for the mirror the beam currently dies at, which settings would accept it. That is a
    # fact a sighted player reads off the screen, not the solution -- where to send it next is still hers.
    def self.assist_lines(d)
      out = []
      beams(d).each_with_index do |spec, i|
        legs, how, last = trace(spec[0], spec[1], spec[2], receivers(d))
        next unless how == :absorbed
        travel = legs[-1][0]
        ok = (0..3).select { |rot| table[rot][travel] }
        next if ok.empty?
        out.push(PokeAccess::I18n.t(:laser_assist, :n => (i + 1).to_s, :where => at(last[0], last[1]),
                                    :dir => dir_name(travel),
                                    :settings => ok.map { |r| face_name(r) }.join(", ")))
      end
      out
    rescue StandardError
      []
    end

    # ---------------------------------------------------------------- per-frame

    # Announces a mirror turning (she just rotated one) and, when it changes, how far the beam now gets.
    # Nothing is spoken on arrival: the info key is for the full picture, and a wall of text every time she
    # walks in would be worse than silence.
    def self.tick(d)
      mid = ($game_map.map_id rescue nil)
      if @map != mid
        @map = mid
        @rots = nil
        @reach = nil
        return
      end
      now = {}
      mirrors.each { |ev| now[ev.id] = rotation(ev.id) }
      if @rots.nil?
        @rots = now
        @reach = beam_state(d)
        return
      end
      changed = now.keys.select { |k| @rots[k] != now[k] }
      @rots = now
      return if changed.empty?
      said = []
      changed.each do |eid|
        ev = index.values.detect { |e| e.id == eid }
        next unless ev
        said.push(PokeAccess::I18n.t(:laser_turned, :where => at(ev.x, ev.y),
                                     :faces => face_name(now[eid])))
      end
      st = beam_state(d)
      if st != @reach
        st.each_with_index do |s, i|
          next if @reach && @reach[i] == s
          # Written out rather than as a ternary: 1.8.7 cannot carry one onto the next line before the
          # colon, and a syntax error here unloads the WHOLE mod without a word.
          if s[1] == :receiver
            said.push(PokeAccess::I18n.t(:laser_now_lit, :n => (i + 1).to_s))
          elsif s[1] == :absorbed
            # Swallowed by a mirror is not the same as running out of track, and telling her the beam
            # "stops" at a mirror she has just turned reads as though the mirror were the end of the road.
            said.push(PokeAccess::I18n.t(:laser_now_absorbed, :n => (i + 1).to_s,
                                         :tiles => s[0].to_s, :where => at(s[2][0], s[2][1])))
          else
            said.push(PokeAccess::I18n.t(:laser_now_reaches, :n => (i + 1).to_s,
                                         :tiles => s[0].to_s, :where => at(s[2][0], s[2][1])))
          end
        end
      end
      @reach = st
      PokeAccess.speak(said.join(". "), false) unless said.empty?
    rescue StandardError
      nil
    end

    # [[tiles lit, how it ended, last tile], ...] per beam -- the cheap summary tick compares.
    def self.beam_state(d)
      beams(d).map do |spec|
        legs, how, last = trace(spec[0], spec[1], spec[2], receivers(d))
        n = 0
        legs.each { |_dir, t, _m| n += t }
        [n, how, last]
      end
    rescue StandardError
      []
    end

    # ---------------------------------------------------------------- walkthrough

    # Every mirror not yet at its target setting, nearest first, with how many turns it still wants.
    #
    # RECOMPUTED from the live rotations every time, never a fixed script: turn one the wrong way, or turn
    # one that was already right, and the next line is correct for where the grid actually is. Mirrors the
    # solution does not use are left out entirely -- any setting will do for those, and naming them would
    # send her across the room for nothing.
    def self.walkthrough(targets)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      rows = []
      mirrors.each do |ev|
        want = targets[[ev.x, ev.y]]
        next if want.nil?
        have = rotation(ev.id)
        next if have == want
        turns = (want - have) % 4
        step = PokeAccess::I18n.t(:wt_laser_step, :where => at(ev.x, ev.y),
                                  :turns => PokeAccess::I18n.t(TURNS[turns] || :wt_turns_1),
                                  :faces => face_name(want))
        rows.push([(ev.x - px).abs + (ev.y - py).abs, step])
      end
      rows.sort_by { |r| r[0] }.map { |r| r[1] }
    rescue StandardError
      []
    end

    TURNS = { 1 => :wt_turns_1, 2 => :wt_turns_2, 3 => :wt_turns_3 }

    # What the object scanner calls a mirror, or nil for anything else on these maps.
    def self.label(ev)
      return nil unless mirror?(ev)
      return nil unless (PokeAccess::Puzzles.current rescue nil)
      mirror_name(ev)
    rescue StandardError
      nil
    end

    # The spoken name of a mirror, carrying its COORDINATES. The walkthrough refers to mirrors by tile
    # ("turn the mirror at x 12, y 15"), so a scanner entry that only said "mirror, open top and left"
    # left her no way to tell which of the twelve she had selected.
    def self.mirror_name(ev)
      PokeAccess::I18n.t(:laser_mirror, :where => at(ev.x, ev.y),
                         :faces => face_name(rotation(ev.id)))
    rescue StandardError
      nil
    end

    # The mirrors as navigation targets, so she can list them and walk to one.
    def self.targets
      d = (PokeAccess::Puzzles.current rescue nil)
      return [] unless d && PokeAccess::Puzzles.kind(d) == :laser
      mirrors.map do |ev|
        PokeAccess::Locator::SurfaceTarget.new(ev.x, ev.y, mirror_name(ev), :mirrors)
      end
    rescue StandardError
      []
    end

    def self.any_targets?
      d = (PokeAccess::Puzzles.current rescue nil)
      return false unless d && PokeAccess::Puzzles.kind(d) == :laser
      !mirrors.empty?
    rescue StandardError
      false
    end

    def self.reset
      @map = nil; @rots = nil; @reach = nil; @idx_map = nil; @idx = nil
    end
  end
end
