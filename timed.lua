local easing = require(RUBATO_DIR.."easing")
local subscribable = require(RUBATO_DIR.."subscribable")
local gears = require "gears"

--- Get the slope (this took me forever to find).
-- i is intro duration
-- o is outro duration
-- t is total duration
-- d is distance to cover
-- F_1 is the value of the antiderivate at 1: F_1(1)
-- F_2 is the value of the outro antiderivative at 1: F_2(1)
-- b is the y-intercept
-- m is the slope
-- @see timed
local function get_slope(i, o, t, d, F_1, F_2, b)
	return (d + i * b * (F_1 - 1)) / (i * (F_1 - 1) + o * (F_2 - 1) + t)
end

--- Get the dx based off of a bunch of factors
-- @see timed
local function get_dx(time, duration, intro, intro_e, outro, outro_e, m, b)
	-- Intro math. Scales by difference between initial slope and target slope
	if time <= intro then
		return intro_e(time / intro) * (m - b) + b

	-- Outro math
	elseif (duration - time) <= outro then
		return outro_e((duration - time) / outro) * m

	-- Otherwise (it's in the plateau)
	else return m end
end

--weak table for memoizing results
local simulate_easing_mem = {}
setmetatable(simulate_easing_mem, {__mode="kv"})

--- Simulates the easing to get the result to find an error coefficient
-- Uses the coefficient to adjust dx so that it's guaranteed to hit the target
-- This must be called when the sign of the target slope is changing
-- @see timed
local function simulate_easing(pos, duration, intro, intro_e, outro, outro_e, m, b, dt)
	local ps_time = 0
	local ps_pos = pos
	local dx


	-- Key for cacheing results
	local key = string.format("%f %f %f %s %f %s %f %f",
		pos, duration,
		intro, tostring(intro_e),
		outro, tostring(outro_e),
		m, b)

	-- Short circuits if it's already done the calculation
	if simulate_easing_mem[key] then return simulate_easing_mem[key] end

	-- Effectively runs the exact same  code to find what the target will be
	while duration - ps_time >= dt / 2 do
		--increment time
		ps_time = ps_time + dt

		--get dx, but use the pseudotime as to not mess with stuff
		dx = get_dx(ps_time, duration,
			intro, intro_e,
			outro, outro_e,
			m, b)

		--increment pos by dx
		ps_pos = ps_pos + dx * dt
	end

	simulate_easing_mem[key] = ps_pos
	return ps_pos
end

--- INTERPOLATE. bam. it still ends in a period. But this one is timed.
-- So documentation isn't super necessary here since it's all on the README and idk how to do
-- documentation correctly, so please see the README or read the code to better understand how
-- it works
local function timed(args)

	local obj = subscribable()

	--set up default arguments
	obj.duration = args.duration or 1
	obj.pos = args.pos or 0

	obj.prop_intro = args.prop_intro or false

	obj.intro = args.intro or 0.2
	obj.inter = args.inter or args.intro

	--set args.outro nicely based off how large args.intro is
	if obj.intro > (obj.prop_intro and 0.5 or obj.duration) and not args.outro then
		obj.outro = math.max((args.prop_intro and 1 or args.duration - args.intro), 0)

	elseif not args.outro then obj.outro = obj.intro
	else obj.outro = args.outro end

	--assert that these values are valid
	assert(obj.intro + obj.outro <= obj.duration or obj.prop_intro, "Intro and Outro must be less than or equal to total duration")
	assert(obj.intro + obj.outro <= 1 or not obj.prop_intro, "Proportional Intro and Outro must be less than or equal to 1")

	obj.easing = args.easing or easing.linear
	obj.easing_outro = args.easing_outro or obj.easing
	obj.easing_inter = args.easing_inter or obj.easing

	--dev interface changes
	obj.log = args.log or false
	obj.awestore_compat = args.awestore_compat or false

	--animation logic changes
	obj.override_simulate = args.override_simulate or false
	obj.rapid_set = args.rapid_set ~= nil and args.rapid_set or obj.awestore_compat

	obj.rate = args.rate or RUBATO_DEF_RATE or 30
	obj.override_dt = args.override_dt or RUBATO_OVERRIDE_DT or true

	-- hidden properties
	obj._props = {
		target = obj.pos
	}

	-- annoying awestore compatibility
	if obj.awestore_compat then
		obj._initial = obj.pos
		obj._last = 0

		function obj:initial() return obj._initial end
		function obj:last() return obj._last end

		obj.started = subscribable()
		obj.ended = subscribable()

	end

	--TODO: fix double pos thing
	-- Variables used in calculation
	local time = 0
	local dt = 1 / obj.rate
	local dx = 0
	local m
	local b
	local is_inter --whether or not it's in an intermittent state

	local last_frame_time = 0 --the time before the last frame
	local raw_dt = dt

	-- Variables used in simulation
	local ps_pos
	local coef


	-- The timer that does all the animating
	local timer = gears.timer()
	timer:connect_signal("timeout", function()

		-- Find the correct dt if it's not already correct
		if (obj.override_dt) then
			dt = os.clock() - last_frame_time

			if (raw_dt < dt) then timer.timeout = dt
			else dt = raw_dt end

			last_frame_time = os.clock()
		end

		--increment time
		time = time + dt

		--get dx
		dx = get_dx(time, obj.duration,
			(is_inter and obj.inter or obj.intro) * (obj.prop_intro and obj.duration or 1),
			is_inter and obj.easing_inter.easing or obj.easing.easing,
			obj.outro * (obj.prop_intro and obj.duration or 1),
			obj.easing_outro.easing,
			m, b)

		--increment pos by dx
		--scale by dt and correct with coef if necessary
		obj.pos = obj.pos + dx * dt * coef

		--sets up when to stop by time
		--weirdness is to try to get closest to duration
		if obj.duration - time < dt / 2 then
			obj.pos = obj._props.target --snaps to target in case of small error
			time = obj.duration --snaps time to duration

			is_inter = false --resets intermittent
			timer:stop()	 --stops itself

			--run subscribed in functions
			obj:fire(obj.pos, time, dx)

			-- awestore compatibility....
			if obj.awestore_compat then obj.ended:fire(obj.pos, time, dx) end

		--otherwise it just fires normally
		else obj:fire(obj.pos, time, dx) end
	end)


	-- Set target and begin interpolation
	local function set(target_new)

		--disallow setting it twice (because it makes it go wonky)
		if not obj.rapid_set and obj._props.target == target_new then return end

		--animation values
		obj._props.target = target_new	--sets target
		time = 0			--resets time
		coef = 1			--resets coefficient

		--rate stuff
		dt = 1 / obj.rate
		raw_dt = dt
		last_frame_time = os.clock()
		timer.timeout = dt

		-- does annoying awestore compatibility
		if obj.awestore_compat then
			obj._last = obj._props.target
			obj.started:fire(obj.pos, time, dx)
		end

		is_inter = timer.started

		--set initial position if interrupting another animation
		b = timer.started and dx or 0

		--get the slope of the plateau
		m = get_slope((is_inter and obj.inter or obj.intro) * (obj.prop_intro and obj.duration or 1),
			obj.outro * (obj.prop_intro and obj.duration or 1),
			obj.duration,
			obj._props.target - obj.pos,
			is_inter and obj.easing_inter.F or obj.easing.F,
			obj.easing_outro.F,
			b)

		--if it will make a mistake (or override_simulate is true), fix it
		if obj.override_simulate or (b ~= 0 and b / math.abs(b) ~= m / math.abs(m)) then
			ps_pos = simulate_easing(obj.pos, obj.duration,
				(is_inter and obj.inter or obj.intro) * (obj.prop_intro and obj.duration or 1),
				is_inter and obj.easing_inter.easing or obj.easing.easing,
				obj.outro * (obj.prop_intro and obj.duration or 1),
				obj.easing_outro.easing,
				m, b, dt)

			--get coefficient by calculating ratio of theoretical range : experimental range
			coef = (obj.pos - obj._props.target) / (obj.pos - ps_pos)
			if coef ~= coef then coef = 1 end --check for div by 0 resulting in nan
		end

		if not timer.started then timer:start() end

	end

	if obj.awestore_compat then function obj:set(target) set(target) end end

	-- Functions for setting state
	-- Completely resets the timer
	function obj:reset()
		timer:stop()
		time = 0
		obj._props.target = obj.pos
		dx = 0
		m = nil
		b = nil
		is_inter = false
		coef = 1
		dt = 1 / obj.rate
		timer.timeout = dt
	end

	-- Effectively pauses the timer
	function obj:abort()
		timer:stop()
		is_inter = false
	end

	--subscribe stuff initially and add callback
	obj.subscribe_callback = function(func) func(obj.pos, time, dt) end
	if args.subscribed ~= nil then obj:subscribe(args.subscribed) end


	-- Metatable for cooler api
	local mt = {}
	function mt:__index(key)
		-- Returns the state value
		if key == "state" then return timer.started

		-- If it's in _props return it from props
		elseif self._props[key] then return self._props[key]

		-- Otherwise just be nice
		else return rawget(self, key) end
	end
	function mt:__newindex(key, value)
		-- Don't allow for setting state
		if key == "state" then return

		-- Changing target should call set
		elseif key == "target" then set(value) --set target

		-- If it's in _props set it there
		elseif self._props[key] ~= nil then self._props[key] = value

		-- Otherwise just set it normally
		else rawset(self, key, value) end
	end

	setmetatable(obj, mt)

	return obj

end

return timed
