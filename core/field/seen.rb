module PokeAccess
  # What she has already looked at.
  #
  # Every other reader in the mod answers "where is the thing I am looking for". None of them answered
  # "what did I walk past" -- and that is information a sighted player gets for free, by glancing round a
  # room and noticing the three people they have not spoken to yet. Blind, the only way to be sure is to
  # talk to everything twice.
  #
  # So: remember which events she has actually TRIGGERED, and let the locator offer the ones she has not.
  # It reveals nothing the game hides -- it lists the same events the scanner already lists, minus the ones
  # she has dealt with. See the standing rule about not auto-completing content: this is the opposite of
  # that, it is a to-do list of things she can go and experience herself.
  #
  # Stored as "mapid:eventid=1" lines, in the same shareable-dictionary shape as the tags and markers.
  # NOTE it is keyed on the MOD's data folder, not the save file: starting a brand new game would inherit
  # the old game's ticks. That is the honest trade for not writing to her save.
  module Seen
    extend PokeAccess::Dictionary
    FILE   = "#{PokeAccess::Paths::DATA}/seen.txt"
    IMPORT = "#{PokeAccess::Paths::DATA}/seen_import.txt"
    EXPORT = "#{PokeAccess::Paths::DATA}/seen_export.txt"
    KEY_RE = /\A(\d+):(\d+)\z/

    # Triggers that mean SHE did it: 0 the action button, 1 walking into it. An event that ran because the
    # game decided to (autorun, parallel, or the event walking into her) is not something she looked at.
    PLAYER_TRIGGERS = [0, 1]

    # Writes are debounced: talking to a row of NPCs would otherwise rewrite the whole file per line.
    SAVE_GAP = 3.0
    @dirty = false
    @last_save = nil

    # True if she has already triggered this event.
    def self.seen?(mid, eid)
      m = store[mid]
      !!(m && m[eid])
    end

    # Records an interaction. Cheap and idempotent; the file catches up on its own.
    def self.mark(mid, eid)
      return if mid.nil? || eid.nil?
      m = (store[mid] ||= {})
      return if m[eid]
      m[eid] = true
      @dirty = true
      flush
    rescue StandardError
      nil
    end

    # Writes the file when enough time has passed since the last write; forced on a map change.
    def self.flush(force = false)
      return unless @dirty
      now = (PokeAccess.clock rescue 0)
      return if !force && @last_save && (now - @last_save) < SAVE_GAP
      @last_save = now
      @dirty = false
      save
    rescue StandardError
      nil
    end

    # The events on the current map she has not looked at yet: things that say or give something, and are
    # triggered by HER. Doors are left out -- the exits category is where a way out belongs, and an exit she
    # has not walked through is not content she missed.
    def self.unseen_on_map
      mid = ($game_map.map_id rescue nil)
      return [] if mid.nil?
      $game_map.events.values.select { |ev| candidate?(ev) && !seen?(mid, ev.id) }
    rescue StandardError
      []
    end

    # True if an event is the kind of thing worth noticing you have not looked at: she can trigger it, and
    # it does something when she does.
    def self.candidate?(ev)
      return false unless PLAYER_TRIGGERS.include?(PokeAccess.ivar_i(ev, :@trigger, -1))
      return false if (PokeAccess::Locator.tag_hidden?(ev) rescue false)
      return false if (PokeAccess::Locator.transfer_event?(ev) rescue false)
      (PokeAccess::Locator.interactable?(ev) rescue false)
    rescue StandardError
      false
    end

    # How many are left here.
    def self.count_here
      unseen_on_map.length
    end

    # ---- the Dictionary hooks ----

    def self.header
      ["PokeAccess: eventos ya vistos. Formato: mapa:evento=1",
       "Se reconstruye solo jugando; borralo para empezar de cero."]
    end

    def self.parse_line(dest, key, _val)
      return unless key =~ KEY_RE
      (dest[$1.to_i] ||= {})[$2.to_i] = true
    end

    def self.each_stored(store)
      store.sort.each do |mid, evs|
        evs.keys.sort.each { |eid| yield([mid, eid], "1") }
      end
    end

    def self.has_entry?(store, key)
      !!(store[key[0]] && store[key[0]][key[1]])
    end

    def self.put_entry(store, key, _val)
      (store[key[0]] ||= {})[key[1]] = true
    end

    def self.line_for(key, _val)
      "#{key[0]}:#{key[1]}=1"
    end
  end
end

# Records the interaction at the moment the engine agrees one happened: Game_Event#start is what every
# player-triggered event goes through, and its @trigger says whether SHE caused it.
#
# hook_container, because this body only RECORDS. Normally start just flags the event and the interpreter
# runs it a frame later, but a game may run the whole event INSIDE start -- Insurgence's secret base does,
# via runSBEvent -- and under the default guard every reader that event drives (its dialogue, the party
# chooser, the Move Relearner's move list) was dropped as nested inside this hook. The whole base went silent.
PokeAccess::Hooks.after_hook("Game_Event", :start, :hook_container => true) do |ev, _r, _a|
  if PokeAccess::Seen::PLAYER_TRIGGERS.include?(PokeAccess.ivar_i(ev, :@trigger, -1))
    PokeAccess::Seen.mark(($game_map.map_id rescue nil), (ev.id rescue nil))
  end
end

# A map change is the moment to be sure the file is on disk.
PokeAccess::Caches.register(:seen) { PokeAccess::Seen.flush(true) }
