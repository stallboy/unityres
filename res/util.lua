local error = error
local pairs = pairs

local util = {}

function util.table_len(a)
    local len = 0
    for _, _ in pairs(a) do
        len = len + 1
    end
    return len
end

util.assettype = { assetbundle = 1, asset = 2, prefab = 3 }
util.assetlocation = { www = 1, resources = 2 }

util.errorlog = error
util.debuglog = function () end

function util.assert(v, message)
    if not v then
        util.errorlog(message)
    end
end

return util
