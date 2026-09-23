module PokeAccess
  # Time of day, as the GAME sees it. Evolutions, encounters and some events depend on day or night, and the
  # only way a sighted player knows which it is right now is the tint on the screen.
  #
  # Everything is asked of the game's own PBDayNight with the game's own pbGetTimeNow, never recomputed:
  # a fork may run an accelerated or fixed clock, or move where night begins. The one thing that varies is
  # the SIGNATURE -- old Essentials (Insurgence) takes the time as a required argument, `isNight?(time)`,
  # where modern takes none or an optional one. The field key called them with none, the ArgumentError was
  # rescued into "no clock", and Insurgence never once said the time of day.
  module DayNight
    # How often the change watcher looks, in frames. Night falls on the hour; a few seconds late is fine.
    POLL_FRAMES = 200

    def self.supported?
      defined?(PBDayNight) ? true : false
    end

    # The game's current time (pbGetTimeNow where it exists, the system clock otherwise).
    def self.now
      t = (pbGetTimeNow rescue nil)
      t.is_a?(Time) ? t : Time.now
    end

    # Asks one PBDayNight predicate about a time, whichever signature this engine gives it. nil when it cannot.
    def self.ask(meth, t)
      return nil unless supported? && PBDayNight.respond_to?(meth)
      m = PBDayNight.method(meth)
      r = (m.arity == 0) ? m.call : m.call(t)
      r ? true : false
    rescue StandardError
      nil
    end

    def self.night?(t = now); ask(:isNight?, t); end

    # The spoken band key for a time. Evening before afternoon: in Essentials the afternoon runs to 8 PM and
    # the evening is its last three hours, so asking afternoon first meant dusk could never be said.
    def self.band_key(t = now)
      return nil unless supported?
      return :tod_morning   if ask(:isMorning?, t)
      return :tod_evening   if ask(:isEvening?, t)
      return :tod_afternoon if ask(:isAfternoon?, t)
      return :tod_night     if ask(:isNight?, t)
      return :tod_day       if ask(:isDay?, t)
      nil
    end

    # The time as a clock reading in the language's own format (12-hour in English, 24-hour elsewhere).
    def self.clock_text(t)
      fmt = PokeAccess::I18n.t(:tod_clock_fmt).to_s
      fmt = "%H:%M" if fmt.empty? || !fmt.include?("%")
      t.strftime(fmt).sub(/\A0(\d)/, '\1')
    rescue StandardError
      nil
    end

    # The first minute, within the next day, at which night starts or ends, as a Time; nil if it never does.
    # Stepped minute by minute through the game's own predicate rather than assumed to be 8 PM and 6 AM.
    def self.next_change(t = now)
      cur = night?(t)
      return nil if cur.nil?
      base = t - t.sec
      (1..1440).each do |m|
        tt = base + m * 60
        return tt if night?(tt) != cur
      end
      nil
    rescue StandardError
      nil
    end

    # True when the game's clock is the real one, so "in 2 hours" means two hours of her time. A game with a
    # sped-up clock gets the time the change happens and no countdown, which would be a lie.
    def self.real_clock?(t)
      (t - Time.now).abs < 90
    rescue StandardError
      false
    end

    # "8:14 PM, at night, day starts at 6:00 AM, in 9 hours 46 minutes", or nil without a clock.
    def self.status_text
      return nil unless supported?
      t = now
      parts = []
      c = clock_text(t)
      parts.push(c) if c
      b = band_key(t)
      parts.push(PokeAccess::I18n.t(b)) if b
      nx = next_change(t)
      if nx
        parts.push(PokeAccess::I18n.t(night?(t) ? :tod_next_day : :tod_next_night, :time => clock_text(nx)))
        if real_clock?(t)
          mins = ((nx - t) / 60.0).ceil
          h = mins / 60; m = mins % 60
          parts.push(h > 0 ? PokeAccess::I18n.t(:tod_in_hm, :h => h, :m => m) : PokeAccess::I18n.t(:tod_in_m, :m => m))
        end
      end
      parts.empty? ? nil : parts.join(", ")
    rescue StandardError
      nil
    end

    # Says so when night falls or day breaks while she is on the map. The first look after a load only
    # records, so loading a save at night is not announced as nightfall.
    def self.poll
      @frames = (@frames || 0) + 1
      return if (@frames % POLL_FRAMES) != 0
      return unless supported? && (PokeAccess::Config.announce_day_night rescue true)
      return unless $game_map && ($scene.is_a?(Scene_Map) rescue false)
      n = night?
      return if n.nil?
      if !@last.nil? && n != @last
        PokeAccess.speak(PokeAccess::I18n.t(n ? :tod_nightfall : :tod_daybreak), false)
      end
      @last = n
    rescue StandardError
      nil
    end

    def self.reset_watch; @last = nil; end
  end
end

PokeAccess::Keys.on_frame { PokeAccess::DayNight.poll }
