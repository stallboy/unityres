local Cache = require "res.Cache"
local Pool = require "res.Pool"

local resdumper = {}

function resdumper.dump()
    ResUpdater.ResDumper.Dump();

    local t = {}
    Pool.dumpAll(function(info)
        table.insert(t, info)
    end)
    UnityEngine.Debug.Log(table.concat(t, "\n"))

    local t = {}
    Cache.dumpAll(function(info)
        table.insert(t, info)
    end)
    UnityEngine.Debug.Log(table.concat(t, "\n"))
end

return resdumper