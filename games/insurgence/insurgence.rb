# Pokemon Insurgence profile. Insurgence runs on the generic (gen-6) core, so this holds only what is
# genuinely the game's own -- starting with its secret bases, which no engine-level rule can see.
#
# HOW A SECRET BASE IS BUILT (173_Secret_Base_Code.rb): a base map ships 100 EMPTY events, ids 1..100, all
# stacked on one column with no graphic and no commands. On entry `loadSecretBaseEvents($game_variables[78])`
# gives each occupied slot a sprite and `moveto`s it where the player put it, and `Game_Event#start` is
# overridden so that on a base map those ids run `runSBEvent` instead of their own (empty) command list.
#
# So every decoration the player has placed is, to the mod, a sprite that does nothing: not a transfer, not
# examinable, no commands to read. The locator classed it as scenery and the "hide non-interactive" filter
# -- which she has switched on -- removed the entire contents of her base from the scanner.
module PokeAccess
  module InsurgenceSB
    # The game variable holding the placement table, and the slot ids that are decoration events. Both are
    # the game's own numbers, read straight out of its Game_Event#start override.
    VAR = 78
    SLOTS = (1..100)

    @cat = nil

    # True while standing in a secret base, asked exactly as the game asks it -- including switch 368, which
    # is how Insurgence turns the interception off for its own scripted visits to those maps.
    def self.on_base_map?
      return false unless $game_map && $game_switches
      return false if $game_switches[368] != false
      return false unless defined?(getAllSBMaps)
      maps = (getAllSBMaps rescue nil)
      maps.is_a?(Array) && maps.include?($game_map.map_id)
    rescue StandardError
      false
    end

    # id => catalogue name, built ONCE from the game's own three catalogue lists by asking it for each
    # entry's number. Derived rather than transcribed, so it cannot drift from the game -- and, because the
    # lists are what the game actually offers a player, an id that exists in the code but in no list (a
    # developer leftover, of which this game has one that must never be read aloud) can never be spoken.
    def self.catalogue
      return @cat if @cat
      @cat = {}
      return @cat unless defined?(getStringsOfType) && defined?(getNumberForUpgrade)
      (0..2).each do |t|
        list = (getStringsOfType(t) rescue nil)
        next unless list.is_a?(Array)
        list.each do |nm|
          n = (getNumberForUpgrade(nm) rescue nil)
          @cat[n] = nm if n.is_a?(Integer)
        end
      end
      @cat
    rescue StandardError
      @cat = {}
    end

    # One slot's placement row, or nil.
    def self.slot(id)
      table = ($game_variables && $game_variables[VAR])
      return nil unless table.is_a?(Array)
      row = table[id]
      row.is_a?(Array) ? row : nil
    rescue StandardError
      nil
    end

    # The catalogue name for a placement row.
    #
    # WHICH column holds the upgrade id moves with the game's own switch 47 -- a base carrying another
    # player's layout stores a raw sprite name where a local one stores the id -- so both candidate columns
    # are offered and only an answer that is actually in the catalogue is trusted. A row we cannot read is
    # not guessed at.
    def self.upgrade_name(row)
      c = catalogue
      [row[1], row[2]].each { |v| return c[v] if v.is_a?(Integer) && c[v] }
      nil
    rescue StandardError
      nil
    end

    # The spoken name of a placed decoration, or nil for anything that is not one.
    #
    # An EMPTY sprite is the test for "this slot is empty": the ninety-odd unused slots never move off their
    # default tile and never get a graphic, and listing them would bury the handful that are really there.
    def self.label(ev)
      return nil unless on_base_map?
      id = (ev.id rescue nil)
      return nil unless id.is_a?(Integer) && SLOTS.include?(id)
      return nil if (ev.character_name.to_s rescue "").empty?
      row = slot(id)
      return nil if row.nil?
      # Placed but unrecognised still has to be findable -- being in the scanner is the whole point -- so it
      # falls back to the plain object word rather than to the sprite filename the core would have read out.
      upgrade_name(row) || PokeAccess::I18n.t(:loc_object)
    rescue StandardError
      nil
    end
  end
end

module PokeAccess
  # Crossing water in Insurgence.
  #
  # The Essentials default -- somebody in the party knows Surf -- is simply not how this game works.
  # Kernel.pbSurf (088_PokemonHiddenMoves.rb:784) asks for
  #     (the LAPRAS key item  OR  a party member with Surf)  AND  $game_switches[4]
  # where switch 4 is "Defeated Gym 1". The item is the "Instant Lapras pack", and a player who has it
  # crosses every lake in the game with a party that knows no HMs at all -- so the default answer would
  # have refused her every water route she is perfectly able to take.
  module InsurgenceSurf
    # Switch 4 is named "Defeated Gym 1" in this game's own switch table; pbSurf gates on it directly.
    BADGE_SWITCH = 4

    def self.can_surf?
      return nil if $game_switches.nil?
      return false unless $game_switches[BADGE_SWITCH]
      item = (PBItems.const_get(:LAPRAS) rescue nil)
      return true if item && $PokemonBag && ($PokemonBag.pbQuantity(item) rescue 0) > 0
      PokeAccess::Gates.known?(:surf) == true
    rescue StandardError
      nil
    end

    # Insurgence's action handler (088_PokemonHiddenMoves.rb:840) adds one condition to the Essentials launch
    # test: facing UP, surfing is refused when the water tile above is itself enterable from below. Copied
    # rather than reasoned about, so the cane never names a side the game will not launch from.
    def self.launch_ok?(orig, x, y, d)
      return false unless orig.call
      return true unless d == 8
      !($game_map.passable?(x, y - 1, 2, true) rescue false)
    rescue StandardError
      false
    end
  end

  # Rock Climb in Insurgence is a key item, not a move. Kernel.pbRockClimb (088_PokemonHiddenMoves.rb:1545)
  # checks for the Hiking Boots and nothing else -- no badge, no party member.
  module InsurgenceClimb
    def self.boots
      (PBItems.const_get(:HIKINGBOOTS) rescue nil)
    end

    def self.usable?
      b = boots
      return nil if b.nil? || $PokemonBag.nil?
      ($PokemonBag.pbQuantity(b) rescue 0) > 0
    rescue StandardError
      nil
    end

    # Rock Smash here is not the move: Kernel.doInsurgenceRockSmash (179_ChallengeChampionship.rb:649) breaks a
    # rock with ANY damaging Fighting-type move in the party.
    def self.smash_usable?
      party = ($Trainer.party rescue nil)
      return nil unless party.is_a?(Array)
      fighting = (PBTypes::FIGHTING rescue nil)
      return nil if fighting.nil?
      party.any? do |pk|
        next false if pk.nil? || (pk.egg? rescue false)
        (pk.moves || []).any? { |m| m && (m.id rescue 0) > 0 && (m.type rescue -1) == fighting && (m.basedamage rescue 0) > 0 }
      end
    rescue StandardError
      nil
    end

    def self.item_name
      b = boots
      b ? PokeAccess::Data.item_name(b).to_s : nil
    rescue StandardError
      nil
    end
  end

  # SLUDGE, and the Mew that clears it.
  #
  # Insurgence paints sludge as one AUTOTILE of the map's tileset, and `useShayminAbility`
  # (179_ChallengeChampionship.rb:2403) swaps that autotile for water and reloads the map: the sludge
  # becomes still water she can surf. Which slot holds it is decided by the tileset's NAME, and the game
  # asks the same question twice -- `pbSlimeCheck` is the other half of its surf trigger
  # (088_PokemonHiddenMoves.rb:844), which is why still water is surfable HERE and nowhere else.
  #
  # Two things follow, and the mod needed both. Before the flare, sludge is a wall with no name: every route
  # past it read "no reachable route", the one answer that says the place does not exist. After it, the water
  # is surfable and the mod would still have said it was not, because Essentials' own tag test says still
  # water never is.
  module InsurgenceSlime
    # tileset name => the autotile slot the sludge occupies. The game's own table, copied, not guessed.
    SLOTS = { "ins_outside" => 6, "interior_main" => 0, "ins_black" => 1, "DeepSeaBase" => 4 }
    STILL_WATER = 6

    def self.slot
      SLOTS[($game_map.tileset_name.to_s rescue "")]
    rescue StandardError
      nil
    end

    def self.autotile
      i = slot
      return nil if i.nil?
      ($game_map.autotile_names[i].to_s rescue nil)
    rescue StandardError
      nil
    end

    # Sludge is still here (not yet flared).
    def self.sludge_map?; autotile == "slime"; end

    # This map HAS the slot and it is no longer sludge, so its still water is surfable (pbSlimeCheck).
    def self.cleared_map?
      a = autotile
      !a.nil? && a != "slime"
    end

    def self.still_water_number
      return @swn if defined?(@swn)
      @swn = (defined?(PBTerrain) && PBTerrain.const_defined?(:StillWater)) ? PBTerrain.const_get(:StillWater) : STILL_WATER
    rescue StandardError
      @swn = STILL_WATER
    end

    def self.still_water_at?(x, y)
      PokeAccess::Terrain.number(PokeAccess::Terrain.raw(x, y)) == still_water_number
    rescue StandardError
      false
    end

    # The game's pbSlimeCheck, asked of a tile of the CURRENT map only -- the autotile table belongs to the
    # map that is loaded, so this must never be asked about anywhere else.
    def self.surfable_at?(x, y)
      cleared_map? && still_water_at?(x, y)
    rescue StandardError
      false
    end

    def self.sludge_at?(x, y)
      sludge_map? && still_water_at?(x, y)
    end

    # Every sludge tile of this map as gate entries, cached per map and per state of the autotile: the flare
    # reloads the same map id, so the id alone would serve the old answer for the rest of the session.
    def self.index
      key = [($game_map.map_id rescue 0), autotile]
      return @idx if @idx_key == key && @idx
      @idx_key = key
      out = {}
      if sludge_map?
        w = ($game_map.width rescue 0); h = ($game_map.height rescue 0)
        h.times do |y|
          w.times do |x|
            out[PokeAccess::Pathfinder.pkey(x, y)] = [:seedflare, :clear, nil] if still_water_at?(x, y)
          end
        end
      end
      @idx = out
    rescue StandardError
      {}
    end

    # The Quartz Flute is what calls the Mew, and variable 42 slot 2 is the game's own record of having
    # learnt Seed Flare (doQuartzFlute, 102_PokemonItemEffects.rb:586).
    def self.flute
      (PBItems.const_get(:QUARTZFLUTE) rescue nil)
    end

    def self.has_flute?
      f = flute
      return nil if f.nil? || $PokemonBag.nil?
      ($PokemonBag.pbQuantity(f) rescue 0) > 0
    rescue StandardError
      nil
    end

    def self.usable?
      f = has_flute?
      return f if f != true
      v = ($game_variables[42] rescue nil)
      return nil unless v.is_a?(Array)
      v[2] == true
    rescue StandardError
      nil
    end

    def self.flute_name
      f = flute
      f ? PokeAccess::Data.item_name(f).to_s : nil
    rescue StandardError
      nil
    end

    # The flare reloads the map in place (same id, same Game_Map), so nothing the mod watches would notice
    # that a wall just became water. One string compare a frame does.
    def self.watch
      a = autotile
      return if a == @last
      @last = a
      PokeAccess::Pathfinder.invalidate_cache(true) rescue nil
    rescue StandardError
      nil
    end
  end

  # Moving boulders here is not "the party knows Strength" either. Kernel.pbStrength
  # (088_PokemonHiddenMoves.rb:697) accepts any of THIRTEEN moves and gates them on switch 4, the same
  # first-badge switch surfing uses. Read as the Essentials default, a party carrying Icy Wind or Psychic --
  # which move boulders perfectly well in this game -- was told nobody could shift them, and every route
  # past a boulder was refused on a lie.
  #
  # Matched by the game's own move CONSTANTS rather than by name, so a translated move name cannot break it.
  module InsurgenceStrength
    MOVES = [:STRENGTH, :BULLDOZE, :STEAMROLLER, :OMINOUSWIND, :ICYWIND, :GIGAIMPACT, :SLAM, :WHIRLWIND,
             :ROCKTHROW, :HEAVYSLAM, :BARRAGE, :PSYCHIC, :HEADBUTT]
    BADGE_SWITCH = 4

    def self.ids
      return @ids if defined?(@ids) && @ids
      @ids = MOVES.map { |n| (PBMoves.const_get(n) rescue nil) }.compact
    rescue StandardError
      @ids = []
    end

    # Only the boulders the GAME calls "Boulder" go anywhere near Kernel.pbStrength: its handler fires on
    # facingEvent.name == "Boulder" and nothing else. This game has thirteen of those and six hundred and
    # eighty-seven named "boulder", which shove themselves when walked into and ask for no move at all.
    # Judging the second kind by the first tells her a rock she can push needs a move nobody in her party
    # has -- which is what it told her at the one that opens the Fiery Caverns.
    def self.map_boulders_free?
      gates = (PokeAccess::Gates.index rescue {})
      evs = ($game_map.events.values rescue [])
      names = []
      gates.each do |k, g|
        next unless g[0] == :strength
        ev = evs.detect { |e| PokeAccess::Pathfinder.pkey(e.x, e.y) == k }
        names.push(ev ? ev.name.to_s : "")
      end
      return false if names.empty?
      names.all? { |n| n != "Boulder" }
    rescue StandardError
      false
    end

    def self.usable?
      return false unless ($game_switches[BADGE_SWITCH] rescue false)
      # Every boulder on this map is the self-shoving kind: she can move them whatever her party knows.
      return true if map_boulders_free?
      party = ($Trainer.party rescue nil)
      return nil unless party.is_a?(Array)
      known = ids
      return nil if known.empty?
      party.any? do |pk|
        next false if pk.nil? || (pk.egg? rescue false)
        (pk.moves || []).any? { |m| m && known.include?((m.id rescue nil)) }
      end
    rescue StandardError
      nil
    end
  end

  # Climbing a waterfall in Insurgence. Kernel.pbWaterfall (088_PokemonHiddenMoves.rb:995) asks for
  #     numbadges >= BADGEFORWATERFALL (6, with HIDDENMOVESCOUNTBADGES on)
  #     AND (the JETPACK key item -- the "Magic Carpet" -- OR a party member with Waterfall)
  # so the Essentials default of "somebody knows the move" is wrong in both directions here.
  module InsurgenceWaterfall
    # 000_Settings.rb:91, with HIDDENMOVESCOUNTBADGES true on line 84 -- so it is a COUNT, not badge six.
    BADGES = 6

    def self.can_waterfall?
      n = ($Trainer.numbadges rescue nil)
      return nil if n.nil?
      return false if n < BADGES
      item = (PBItems.const_get(:JETPACK) rescue nil)
      return true if item && $PokemonBag && ($PokemonBag.pbQuantity(item) rescue 0) > 0
      PokeAccess::Gates.known?(:waterfall) == true
    rescue StandardError
      nil
    end
  end

  # Diving in Insurgence is the Scuba Gear, not the move: Kernel.pbDive (088_PokemonHiddenMoves.rb:1059) asks
  # for the key item and nothing else, and without it only says the sea is deep.
  module InsurgenceDive
    def self.can_dive?
      item = (PBItems.const_get(:SCUBAGEAR) rescue nil)
      return nil if item.nil? || $PokemonBag.nil?
      ($PokemonBag.pbQuantity(item) rescue 0) > 0
    rescue StandardError
      nil
    end
  end
end

PokeAccess::Game.define("insurgence") do
  event_reader { |ev| PokeAccess::InsurgenceSB.label(ev) }

  # Water is crossed with a key item here, not with the move (see InsurgenceSurf).
  override(PokeAccess::Gates, :can_surf?) { |_r, _orig, _a| PokeAccess::InsurgenceSurf.can_surf? }
  override(PokeAccess::Gates, :surf_launch_ok?) { |_r, orig, a| PokeAccess::InsurgenceSurf.launch_ok?(orig, a[0], a[1], a[2]) }
  override(PokeAccess::Gates, :can_dive?) { |_r, _orig, _a| PokeAccess::InsurgenceDive.can_dive? }
  # A waterfall is only water to somebody who can climb it (see InsurgenceWaterfall).
  override(PokeAccess::Gates, :can_waterfall?) { |_r, _orig, _a| PokeAccess::InsurgenceWaterfall.can_waterfall? }

  # Sludge: a wall until a Mew flares it, then water (see InsurgenceSlime).
  PokeAccess::Gates.register_move(:seedflare, :rl_mo_seedflare, :loc_sludge)
  override(PokeAccess::Gates, :extra_index) { |_r, _orig, _a| PokeAccess::InsurgenceSlime.index }
  override(PokeAccess::Terrain, :surfable_at?) do |_r, orig, a|
    orig.call || PokeAccess::InsurgenceSlime.surfable_at?(a[0], a[1])
  end
  override(PokeAccess::Terrain, :label) do |_r, orig, a|
    PokeAccess::InsurgenceSlime.sludge_at?(a[0], a[1]) ? :surf_sludge : orig.call
  end
  PokeAccess::Keys.on_frame { PokeAccess::InsurgenceSlime.watch }

  # Rock Climb is unlocked by the Hiking Boots (see InsurgenceClimb).
  override(PokeAccess::Gates, :usable?) do |_r, orig, a|
    case a[0]
    when :rockclimb then PokeAccess::InsurgenceClimb.usable?
    when :rocksmash then PokeAccess::InsurgenceClimb.smash_usable?
    when :seedflare then PokeAccess::InsurgenceSlime.usable?
    when :strength  then PokeAccess::InsurgenceStrength.usable?
    else orig.call
    end
  end
  override(PokeAccess::Gates, :unlock_item) do |_r, orig, a|
    case a[0]
    when :rockclimb then PokeAccess::InsurgenceClimb.item_name
    when :seedflare then PokeAccess::InsurgenceSlime.flute_name
    else orig.call
    end
  end
end
