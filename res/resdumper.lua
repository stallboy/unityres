local Cache = require "res.Cache"
local util = require "res.util"
local Pool = require "res.Pool"
local Timer = require "common.Timer"
local SimpleEvent = require "common.SimpleEvent"

local resdumper = {}

function resdumper.dump()
    ResUpdater.ResDumper.Dump();
    util.dump(Pool)
    util.dump(Cache)
    util.dump(Timer)
    util.dump(SimpleEvent)
end

return resdumper