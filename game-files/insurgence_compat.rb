# Pokemon Insurgence compatibility shim for mkxp-z.
#
# WHY THIS EXISTS
# Insurgence ships as a stock RPG Maker XP game (RGSS 1.02). To make it moddable at all it
# is run under mkxp-z instead, which is what gives the accessibility mod its preloadScript
# hook. Almost everything survives that swap -- but not the MGC H-Mode7 renderer.
#
# A map whose name contains "[HM7]" switches on that renderer, which calls into
# MGC_Hmode7.dll passing what are, under real RGSS, pointers to Bitmap internals. mkxp-z's
# Bitmap is a completely different object, so the DLL writes into memory that is not a
# bitmap. The result is a native crash: the process disappears with no Ruby exception, no
# errorlog.txt and nothing on stderr. The very first place the game does this is the intro,
# on map 689 "Torren Region[HM7][HMAP2][#0][DF][X][Y]", which is why a new game could not
# get past character creation.
#
# WHAT THIS DOES -- AND DELIBERATELY DOES NOT DO
# Game_Map#setup still runs in full: the map, its events, its collision, every NPC and every
# script load exactly as the authors wrote them. All this changes is the flag that swaps the
# ordinary 2D camera for a mode-7 projection, so those maps draw flat instead.
#
# Mode-7 is a camera angle, not content. The same world is walked, the same events fire, the
# same story plays. Nothing is skipped, removed or auto-completed -- which matters, because
# the person this is for has never played the game and should meet all of it.
#
# Loaded via preloadScript in mkxp.json, alongside the accessibility mod's own loader. It
# touches no game file, so removing this line and this file puts everything back.
module InsurgenceCompat
  MARK = "accessibility/data/compat.txt"

  def self.note(msg)
    File.open(MARK, "a") { |f| f.write("#{Time.now}: #{msg}\n") }
  rescue StandardError
  end

  def self.install
    return unless defined?(::Game_Map)
    ::Game_Map.class_eval do
      unless method_defined?(:setup__insurgence_compat)
        alias_method :setup__insurgence_compat, :setup
        def setup(map_id)
          r = setup__insurgence_compat(map_id)
          begin
            if $game_system && $game_system.hm7
              $game_system.hm7 = false
              InsurgenceCompat.note("map #{map_id}: H-Mode7 disabled (renders flat; mkxp-z cannot call MGC_Hmode7.dll safely)")
            end
          rescue Exception
          end
          r
        end
      end
    end
    true
  end

  # Game_Map does not exist yet at preload time, so wait for the main loop the same way the
  # accessibility loader does, and install as soon as the class is defined.
  @done = false
  class << Graphics
    unless method_defined?(:update__insurgence_compat)
      alias_method :update__insurgence_compat, :update
      def update(*a)
        r = update__insurgence_compat(*a)
        unless InsurgenceCompat.done?
          InsurgenceCompat.mark_done if InsurgenceCompat.install
        end
        r
      end
    end
  end

  def self.done?; @done; end
  def self.mark_done; @done = true; end
end
