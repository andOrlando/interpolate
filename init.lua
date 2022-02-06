RUBATO_DEF_RATE = 30
RUBATO_OVERRIDE_DT = true

if not RUBATO_DIR then RUBATO_DIR = (...):match("(.-)[^%.]+$").."rubato." end
if not RUBATO_MANAGER then RUBATO_MANAGER = require(RUBATO_DIR.."manager") end

return {
	--Overarching functions to set defaults
	set_def_rate = function(rate) RUBATO_DEF_RATE = rate end,
	set_override_dt = function(value) RUBATO_OVERRIDE_DT = value end,

	--Modules
	timed = require(RUBATO_DIR.."timed"),
	easing = require(RUBATO_DIR.."easing"),
	subscribable = require(RUBATO_DIR.."subscribable"),
	manager = RUBATO_MANAGER,
}
