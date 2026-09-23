module PokeAccess
  # The walkthrough: for a puzzle that has one, the next thing to do, spoken without being asked.
  #
  # This is a deliberate departure from how the rest of the puzzle code works. Everything else here is
  # built to describe a puzzle so she can SOLVE it -- the grid readout, the beam trace, the boulder's state
  # -- because a puzzle you cannot see is not the same as a puzzle you cannot do. Her answer to that, in
  # her own words: "honestly I don't really get much out of puzzles." So this hands over the answer.
  #
  # Two rules it holds to:
  #
  #   * It is always RECOMPUTED, never a script. A provider answers "what is still wrong", so if she turns
  #     something the wrong way, or turns something that was already right, the next line is correct for
  #     where the puzzle actually is rather than for the step a counter thinks she is on. There is no way
  #     to get out of step with it.
  #   * It speaks only when the ANSWER CHANGES. Re-announcing the same step every frame, or on every
  #     footfall, would bury the rest of the mod's speech.
  #
  # A puzzle opts in with :walkthrough => lambda { [...] } on its definition, returning the steps still
  # outstanding, nearest or first to last. An empty list means solved.
  module Walkthrough
    def self.on?
      PokeAccess::Config.walkthrough
    rescue StandardError
      true
    end

    # The steps still outstanding for the current puzzle, or nil when it has no walkthrough.
    def self.steps(d)
      return nil unless d
      p = d[:walkthrough]
      return nil unless p
      r = (p.call rescue nil)
      r.is_a?(Array) ? r : nil
    rescue StandardError
      nil
    end

    # Spoken on arrival and whenever the outstanding work changes: the next step, and how many are left.
    def self.tick(d)
      return unless on?
      mid = ($game_map.map_id rescue nil)
      if @map != mid
        @map = mid
        @last = nil
        @was = nil
      end
      list = steps(d)
      if list.nil?
        @last = nil
        @was = nil
        return
      end
      if list.empty?
        # Only worth saying once, and only if there was something to finish.
        if @was && @was > 0
          PokeAccess.speak(PokeAccess::I18n.t(:wt_done), false)
        end
        @last = nil
        @was = 0
        return
      end
      # Keyed on the step AND how many are left, not the step alone. Finishing a step that was not the
      # nearest one leaves the same line at the head, and saying nothing then reads as the walkthrough
      # having missed what she just did -- when in fact the count is the part that moved.
      head = list[0].to_s
      key = [head, list.length]
      return if @last == key
      @last = key
      @was = list.length
      # "1 still to do" is noise on a provider that only ever offers one thing at a time, and the
      # Victory Road route is exactly that -- one leg, recomputed from her tile.
      if list.length == 1
        PokeAccess.speak(PokeAccess::I18n.t(:wt_next_one, :step => head), false)
      else
        PokeAccess.speak(PokeAccess::I18n.t(:wt_next, :step => head, :n => list.length.to_s), false)
      end
    rescue StandardError
      nil
    end

    # Added to the info-key readout, so she can hear it again without waiting for something to change.
    def self.read_lines(d)
      return [] unless on?
      list = steps(d)
      return [] if list.nil?
      return [PokeAccess::I18n.t(:wt_done_short)] if list.empty?
      return [PokeAccess::I18n.t(:wt_next_one, :step => list[0].to_s)] if list.length == 1
      [PokeAccess::I18n.t(:wt_next, :step => list[0].to_s, :n => list.length.to_s)]
    rescue StandardError
      []
    end

    def self.reset
      @map = nil; @last = nil; @was = nil
    end
  end
end
