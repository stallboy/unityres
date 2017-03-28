local pairs = pairs

local util = {}

function util.table_len(a)
    local len = 0
    for _, _ in pairs(a) do
        len = len + 1
    end
    return len
end

function util.table_isempty(a)
    for _, _ in pairs(a) do
        return false
    end
    return true
end

function util.dump(mod)
    local t = {}
    mod.dumpAll(function(info)
        table.insert(t, info)
    end)
    UnityEngine.Debug.Log(table.concat(t, "\n"))
end


util.assettype = { assetbundle = 1, asset = 2, prefab = 3, sprite= 4 }
util.assetlocation = { www = 1, resources = 2 }

return util
