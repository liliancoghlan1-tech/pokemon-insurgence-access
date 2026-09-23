module PokeAccess
  # Optional difficulty assists. Every one of them is OFF by default, reversible from the config menu at any
  # moment, and touches nothing but the two numbers a hard Pokemon game actually grinds a player down with:
  # how often the world interrupts you, and how fast your party keeps up.
  #
  # Why these two and not, say, invincibility. A blind player walks a great many more tiles than a sighted
  # one for the same journey -- exploring with the cane, correcting course, walking to a scanner target -- and
  # every one of those extra steps is another encounter roll. The random-encounter tax is not a difficulty
  # setting for her, it is a surcharge on being unable to see the map. And Insurgence's difficulty is very
  # largely level-curve pressure, which is paid in grinding, which is paid in more of the same walking.
  #
  # Nothing here touches a puzzle, a route, a battle's outcome or a line of story. It is a slower tide, not a
  # solved game. See the mod's standing rule about not auto-completing content.
  module Assist
    # Ordered for the menu's left/right cycling; the first is always "as the game shipped".
    ENCOUNTER_MODES = [:normal, :fewer, :rare, :none]
    EXP_MODES = [:normal, :x2, :x3]

    # Share of encounters that still happen, per mode.
    ENCOUNTER_KEEP = { :normal => 1.0, :fewer => 0.5, :rare => 0.25, :none => 0.0 }
    # Experience multiplier per mode.
    EXP_FACTOR = { :normal => 1, :x2 => 2, :x3 => 3 }

    # The game switch that turns on the universal Exp. Share, when the running game HAS one.
    #
    # Insurgence ships the feature already built and named (`uni_expshare`), read only in the experience
    # block and tested by no event page anywhere in the game -- so flipping it is using the developers' own
    # lever, not patching around them. A game that has no such switch simply does not offer the setting.
    EXPSHARE_SWITCH_NAMES = [/\Auni_?expshare\z/i, /\Aexp_?share_?all\z/i]

    @expshare_id = nil
    @expshare_looked = false

    # The id of this game's universal-Exp-Share switch, found ONCE by NAME in the engine's own switch table,
    # or nil. By name and never by number: switch 339 means "universal Exp Share" in Insurgence and
    # something else entirely in the next game, and a mod that writes a number it has not verified is a mod
    # that corrupts saves.
    def self.expshare_switch
      return @expshare_id if @expshare_looked
      @expshare_looked = true
      names = ($data_system.switches rescue nil)
      return @expshare_id = nil unless names.is_a?(Array)
      (1...names.length).each do |i|
        n = names[i].to_s
        next if n.empty?
        if EXPSHARE_SWITCH_NAMES.any? { |re| n =~ re }
          return @expshare_id = i
        end
      end
      @expshare_id = nil
    rescue StandardError
      @expshare_id = nil
    end

    # True when this game offers the shared-experience assist at all.
    def self.expshare_available?
      !expshare_switch.nil?
    end

    # Keeps the game's own switch in step with the setting, both ways, once a save is loaded. Runs from the
    # map poll rather than from the menu so it survives loading a save that was made with the setting the
    # other way round; writes only on a genuine difference, so an ordinary frame costs one comparison.
    def self.sync_expshare
      id = expshare_switch
      return if id.nil? || $game_switches.nil?
      want = !!(PokeAccess::Config.assist_expshare rescue false)
      return if !!$game_switches[id] == want
      $game_switches[id] = want
      # Insurgence's own switch is tested by no event page anywhere, but this one is found by NAME and the
      # next game's equivalent may well gate a page on it. Asking the map to refresh is what the engine
      # does after any switch write, and costs one frame.
      ($game_map.need_refresh = true) if $game_map
    rescue StandardError
      nil
    end

    # True if this encounter should be suppressed. Rolled per encounter, not per step: the engine has already
    # decided a battle is due, and thinning them here leaves the game's own density, repels, and every
    # special case exactly as authored.
    def self.suppress_encounter?
      mode = (PokeAccess::Config.assist_encounters rescue :normal)
      keep = ENCOUNTER_KEEP[mode]
      return false if keep.nil? || keep >= 1.0
      return true if keep <= 0.0
      rand >= keep
    rescue StandardError
      false
    end

    # The multiplier to apply to an experience award.
    def self.exp_factor
      EXP_FACTOR[(PokeAccess::Config.assist_exp rescue :normal)] || 1
    rescue StandardError
      1
    end
  end
end

# Thins wild encounters. The gate the engine already asks before every wild battle, so a suppressed
# encounter is indistinguishable from one the game itself declined -- no half-started battle, no lost step.
PokeAccess::Hooks.around_hook("PokemonEncounters", :pbCanEncounter?, :optional => true) do |_inst, nxt, _args|
  r = nxt.call
  (r && PokeAccess::Assist.suppress_encounter?) ? false : r
end

# Multiplies experience at the single point every award passes through on its way into a Pokemon: the engine
# computes the gain, hands it to the growth-rate table to be added, and takes the difference back. Scaling
# the ARGUMENT means level caps, Exp. Share splits and the game's own bonuses all still apply first, and the
# curve does the rest -- there is no second place where experience could arrive and miss this.
PokeAccess::Hooks.override("PBExperience", :pbAddExperience, :tag => "assist", :optional => true) do |_r, orig, args|
  f = PokeAccess::Assist.exp_factor
  args[1] = (args[1].to_i * f) if f != 1 && args.length >= 2 && args[1].is_a?(Integer)
  orig.call
end
