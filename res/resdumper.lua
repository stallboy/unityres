local Cache = require "res.Cache"
local Pool = require "res.Pool"
local Timer = require "common.Timer"
local SimpleEvent = require "common.SimpleEvent"

local resdumper = {}

local function _dump(mod)
    local t = {}
    mod.dumpAll(function(info)
        table.insert(t, info)
    end)
    UnityEngine.Debug.Log(table.concat(t, "\n"))
end

function resdumper.dump()
    ResUpdater.ResDumper.Dump();
    _dump(Pool)
    _dump(Cache)
    _dump(Timer)
    _dump(SimpleEvent)
end

return resdumper