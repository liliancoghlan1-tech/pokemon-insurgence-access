module PokeAccess
  # Story steps: where the game's own story is waiting for her next.
  #
  # Insurgence has no quest log -- its notebook screen is commented out of the pause menu -- so a sighted player
  # has no marker either; they read the world. What the game DOES have is its story written into switches with
  # names, and events whose behaviour depends on them. A story step is an event whose CURRENT page
  #   * is gated on progress already made (a named switch that is on, or a variable past a threshold), and
  #   * when it runs, turns on a named switch that is still off.
  # That is the game's own "this is what happens next", read without knowing any of the story. On her save it
  # narrowed 750 maps down to nine events; the router picks the nearest she can reach.
  #
  # Nothing about WHAT happens is ever spoken: the target is "story step", on this map or through the doors,
  # and a map she has never visited is not named.
  module Story
    INDEX_VERSION = 1
    # Maps read per build step, and frames between steps. Reading is load_data from the game's archive, a few
    # milliseconds a map; one every other frame keeps the build invisible and done within a minute of play.
    FRAMES_PER_STEP = 2

    StoryTarget = Class.new(PokeAccess::Locator::RemoteTarget)

    def self.index_path
      "#{PokeAccess::Paths::DATA}/story_index.dat"
    end

    def self.ready?; @index_done ? true : false; end

    # The editor bumps System#version_id on every save of the project, so a cached index is only reused for the
    # exact data it was built from.
    def self.signature
      [INDEX_VERSION, ($data_system.version_id rescue 0), (map_ids.length rescue 0)]
    end

    def self.map_ids
      @map_ids ||= begin
        infos = (PokeAccess::Locator.load_mapinfos rescue nil)
        infos.is_a?(Hash) ? infos.keys.sort : []
      end
    end

    def self.named_switch?(i)
      return false unless i.is_a?(Integer) && i > 0
      n = (($data_system.switches[i] rescue nil) || "").to_s.strip
      !n.empty? && n !~ /\As:/
    end

    # Runs every frame; builds or loads the index once per session.
    def self.tick
      return if @index_done || @failed
      return unless $game_map && ($scene.is_a?(Scene_Map) rescue false)
      if @index.nil?
        return if load_cached
        @pending = map_ids.dup
        @index = []
        @frame = 0
      end
      @frame += 1
      return unless (@frame % FRAMES_PER_STEP) == 0
      mid = @pending.shift
      if mid.nil?
        @index_done = true
        save_cached
        return
      end
      index_map(mid)
    rescue StandardError => e
      @failed = true
      PokeAccess.log_once("story_index", e)
    end

    def self.load_cached
      return false unless File.exist?(index_path)
      data = File.open(index_path, "rb") { |f| Marshal.load(f) }
      return false unless data.is_a?(Array) && data[0] == signature
      @index = data[1]
      @index_done = true
      true
    rescue StandardError
      false
    end

    def self.save_cached
      File.open(index_path, "wb") { |f| Marshal.dump([signature, @index], f) }
    rescue StandardError
      nil
    end

    # Records every event on a map that has at least one page turning on a named switch, with ALL its pages'
    # conditions: which page is active is only known at the moment of asking.
    def self.index_map(mid)
      m = (load_data(sprintf("Data/Map%03d.rxdata", mid)) rescue nil)
      return if m.nil?
      (m.events || {}).each_value do |ev|
        pages = (ev.pages || []).map do |pg|
          c = pg.condition
          cond = [c.switch1_valid ? c.switch1_id : nil, c.switch2_valid ? c.switch2_id : nil,
                  c.variable_valid ? [c.variable_id, c.variable_value] : nil,
                  c.self_switch_valid ? c.self_switch_ch.to_s : nil]
          sets = []
          (pg.list || []).each do |cmd|
            next unless (cmd.code rescue 0) == 121
            p = cmd.parameters
            next unless p[2] == 0
            (p[0]..p[1]).each { |i| sets.push(i) if named_switch?(i) }
          end
          [cond, (pg.trigger rescue 0), sets.uniq]
        end
        next unless pages.any? { |pg| !pg[2].empty? }
        @index.push([mid, ev.id, ev.x, ev.y, pages])
      end
    end

    def self.cond_met?(mid, eid, cond)
      return false if cond[0] && !($game_switches[cond[0]] rescue false)
      return false if cond[1] && !($game_switches[cond[1]] rescue false)
      return false if cond[2] && ((($game_variables[cond[2][0]] rescue 0).to_i rescue 0) < cond[2][1])
      return false if cond[3] && !($game_self_switches[[mid, eid, cond[3]]] rescue false)
      true
    end

    # The steps waiting right now, as [map, event, x, y].
    def self.armed
      return [] unless @index_done
      out = []
      @index.each do |mid, eid, x, y, pages|
        pg = nil
        (pages.length - 1).downto(0) { |i| if cond_met?(mid, eid, pages[i][0]) then pg = pages[i]; break end }
        next if pg.nil?
        cond, _trig, sets = pg
        gated = named_switch?(cond[0]) || named_switch?(cond[1]) || (cond[2] && cond[2][1] > 0)
        next unless gated
        next unless sets.any? { |i| !($game_switches[i] rescue true) }
        if mid == ($game_map.map_id rescue nil)
          ev = ($game_map.events[eid] rescue nil)
          next if ev.nil? || (ev.instance_variable_get(:@erased) rescue false)
          x = ev.x; y = ev.y
        end
        out.push([mid, eid, x, y])
      end
      out
    rescue StandardError
      []
    end

    def self.any?
      !armed.empty?
    end

    def self.visited?(mid)
      v = ($PokemonGlobal.visitedMaps rescue nil)
      v ? !!v[mid] : true
    end

    # Scanner targets, the ones she can get to first (fewest doors, then nearest), unreachable ones after.
    def self.targets
      here = ($game_map.map_id rescue nil)
      label = PokeAccess::I18n.t(:loc_story_step)
      px = ($game_player.x rescue 0); py = ($game_player.y rescue 0)
      ranked = armed.map do |mid, _eid, x, y|
        if mid == here
          t = PokeAccess::Locator::SurfaceTarget.new(x, y, label, :story)
          [0, 0, (x - px).abs + (y - py).abs, t]
        else
          leg = (PokeAccess::WarpNet.first_leg(mid, x, y) rescue nil)
          t = StoryTarget.new(mid, x, y, label)
          leg ? [1, leg[1].to_i, 0, t] : [2, 0, 0, t]
        end
      end
      ranked.sort_by { |a, b, c, _t| [a, b, c] }.map { |r| r[3] }
    rescue StandardError
      []
    end

    # Where a story step is, as spoken: its map's name only once she has been there.
    def self.place_phrase(t)
      return nil unless t.is_a?(StoryTarget)
      if visited?(t.map_id)
        PokeAccess::I18n.t(:loc_on_map, :name => t.name.to_s, :map => (PokeAccess::Locator.map_name(t.map_id) || "").to_s)
      else
        PokeAccess::I18n.t(:loc_story_new, :name => t.name.to_s)
      end
    end
  end
end

PokeAccess::Keys.on_frame { PokeAccess::Story.tick }
