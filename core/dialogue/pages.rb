module PokeAccess
  # Reads a message PAGE BY PAGE, in step with the player's key presses, instead of speaking the whole
  # thing the moment the game hands it over.
  #
  # A Show Text command is one message however many lines it holds, and the window pages it: it draws until
  # it reaches a pause marker, waits for the confirm key, then draws the next page. The mod used to speak
  # the entire string up front, so the speech ran away from the screen and a long conversation arrived as
  # one continuous block that had nothing to do with what she was pressing.
  #
  # The window is the authority on where the pages are, so this reads the window rather than trying to
  # re-derive the split: it speaks exactly the characters the window has just finished drawing.
  #
  # PACE: the first line of each message INTERRUPTS whatever is still being read, so pressing on to the
  # next line cuts to it. Queued speech was the real reason a long conversation ran away from her.
  #
  # SCOPE: this speaks only for text going through the message function. Window_AdvancedTextPokemon is
  # shared -- the battle scene drives its own copy of it directly, and those messages have their own reader
  # -- so the page reader stays out of any window it was not handed.
  #
  # SAFETY NET, deliberately: if a message ends and nothing was spoken for it -- a build with no
  # letter-by-letter, a window class this does not fit, a hook that failed to bind -- the whole message is
  # spoken the old way. Dialogue going quiet is the worst failure this mod has, so the fallback is
  # unconditional rather than clever, and `Config.dialogue_pages` turns the whole thing off.
  module MessagePages
    WINDOW = "Window_AdvancedTextPokemon"

    @bound = false
    @depth = 0
    @spoken_any = false
    @pending = nil
    @suppress = false
    @first = true

    # True when the paging path is installed AND the player has left it on.
    def self.on?
      @bound && (PokeAccess::Config.dialogue_pages rescue true)
    end

    def self.bound!; @bound = true; end
    def self.bound?; @bound; end

    # A message is starting. Remembers it for the repeat key and for the safety net; when paging is off,
    # behaves exactly as the mod always did and speaks it here.
    def self.begin_message(message)
      @depth += 1
      if @depth > 1
        # A message opened inside another (a choice inside a message). The inner one is left to the old
        # path rather than interleaved with the outer one's pages.
        PokeAccess.say_dialogue(message)
        return
      end
      @spoken_any = false
      @suppress = false
      @first = true
      @pending = message
      unless on?
        PokeAccess.say_dialogue(message)
        @spoken_any = true
        return
      end
      # A dedicated reader (battle, minigame, screen message) speaks its line BEFORE handing it to the
      # engine, and the engine then shows it in the message window. Reading the window's pages as well
      # is how battle text came out twice. Already said means already said: stay quiet for this one.
      if PokeAccess.recently_said?(PokeAccess.clean(message))
        @suppress = true
        @spoken_any = true
        return
      end
      PokeAccess.say_dialogue_skip(message)
    rescue StandardError
      nil
    end

    # The message is over. Speaks the whole thing if the page reader never got a word out.
    def self.end_message
      @depth -= 1 if @depth > 0
      return unless @depth == 0
      msg = @pending
      @pending = nil
      sup = @suppress
      @suppress = false
      return if sup || @spoken_any || msg.nil?
      PokeAccess.speak(PokeAccess.clean(msg), true)
    rescue StandardError
      nil
    end

    # Speaks the characters the window has drawn since the last page. Called at each pause and once more
    # when the message finishes, so every character is spoken exactly once.
    def self.flush(win)
      return unless on?
      return if @suppress
      # ONLY while a message call is actually in progress.
      #
      # The window class is shared, and the BATTLE does not use the message function at all: its
      # pbDisplayMessage sets cw.text on its own message window and runs its own loop. So these hooks fire
      # for battle text too, after the battle reader has already spoken it -- which is exactly how battle
      # messages came out twice. No message call in progress means this window belongs to somebody else,
      # and somebody else is reading it.
      return unless @depth > 0 && @pending
      chars = PokeAccess.ivar(win, :@textchars)
      return unless chars.is_a?(Array)
      cur = PokeAccess.ivar_i(win, :@curchar, 0)
      from = PokeAccess.ivar_i(win, :@pa_spoken, 0)
      cur = chars.length if cur > chars.length
      return if cur <= from
      text = PokeAccess.clean(chars[from...cur].join)
      win.instance_variable_set(:@pa_spoken, cur)
      return if text.nil? || text.strip.empty?
      @spoken_any = true
      PokeAccess.note_dialogue(text)
      # The FIRST thing said for a message interrupts; the rest of its pages queue behind it.
      #
      # This is the half of "read it in step with my key presses" that had nothing to do with paging.
      # Dialogue was queued, so pressing on to the next line did not stop the previous one -- over a long
      # conversation the speech fell further and further behind, which is what arrives as one continuous
      # block. Interrupting on each new message hands the pace back to her.
      PokeAccess.speak(text, @first)
      @first = false
    rescue StandardError
      nil
    end

    # A new message resets the per-window read cursor.
    def self.rewind(win)
      win.instance_variable_set(:@pa_spoken, 0)
    rescue StandardError
      nil
    end
  end
end

# Each page: the window pauses when it has drawn one, which is exactly the moment its text is on screen.
PokeAccess::Hooks.after_hook(PokeAccess::MessagePages::WINDOW, :startPause, :optional => true) do |w, _r, _a|
  PokeAccess::MessagePages.flush(w)
end

# The tail: the last page has no pause after it, so the end of the display is where it gets spoken.
# updateInternal runs per frame while a message is up, and clears @displaying on the frame it finishes.
PokeAccess::Hooks.after_hook(PokeAccess::MessagePages::WINDOW, :updateInternal, :optional => true) do |w, _r, _a|
  PokeAccess::MessagePages.flush(w) unless PokeAccess.ivar(w, :@displaying)
end

# Setting new text starts a new message: the read cursor goes back to the beginning.
PokeAccess::Hooks.after_hook(PokeAccess::MessagePages::WINDOW, :text=, :optional => true) do |w, _r, _a|
  PokeAccess::MessagePages.rewind(w)
end

# Only claim the paging path when the window really answered to all of it.
begin
  chains = (PokeAccess::Hooks.instance_variable_get(:@chains) || {})
  need = ["#{PokeAccess::MessagePages::WINDOW}#startPause",
          "#{PokeAccess::MessagePages::WINDOW}#updateInternal",
          "#{PokeAccess::MessagePages::WINDOW}#text="]
  PokeAccess::MessagePages.bound! if need.all? { |k| chains.has_key?(k) }
rescue StandardError
  nil
end
