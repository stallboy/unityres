local pairs = pairs
local cfg = require("cfg._cfgs")

local util = {}

function util.table_len(a)
    local len = 0
    for _, _ in pairs(a) do
        len = len + 1
    end
    return len
end

function util.table_isarray(t)
    local index = 0
    for _ in pairs(t) do
        index = index + 1
        local v = t[index]
        if v == nil then return false end
    end
    return true
end

function util.table_isempty(a)
    for _, _ in pairs(a) do
        return false
    end
    return true
end

function util.dump(...)
    local t = {}
    for _, mod in ipairs { ... } do
        mod.dumpAll(function(info)
            table.insert(t, info)
        end)
    end

    UnityEngine.Debug.Log(table.concat(t, "\n"))
end

function util.factor_size(orig_maxsize, factor)
    local fsize = orig_maxsize * factor
    local maxsize = math.floor(fsize)
    if maxsize == 0 and fsize > 0 then
        maxsize = 1
    end
    return maxsize
end

function util.make_net_assetinfo(url, type, netResType) -- assetinfo={url=xxx,...}
    local assetinfo = { assetid = tostring(type) .. "#" .. url, type = type, url = url,
                        directDeps = {}, location = util.assetlocation.net, assetpath = "url", netResType = netResType or cfg.asset.netrestype.DEFAULT }
    local cfg = require "cfg._cfgs"
    local refCachepolicy
    if type == util.assettype.sprite then
        refCachepolicy = cfg.asset.assetcachepolicy.netsprite
    else
        refCachepolicy = cfg.asset.assetcachepolicy.netres
    end
    assetinfo.RefCachepolicy = refCachepolicy
    assetinfo.cachepolicy = refCachepolicy.name
    assetinfo.directDeps = {}
    assetinfo.RefDirectDeps = {}
    return assetinfo
end

util.assettype = { assetbundle = 1, asset = 2, prefab = 3, sprite = 4 }
util.assetlocation = { www = 1, resources = 2, net = 3 }

return util
