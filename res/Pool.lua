local res = require "res.res"
local GameObject = UnityEngine.GameObject

local Pool = {}

function Pool:new(maxsize)
    local o = {}
    o.maxsize = maxsize
    o.pool = {} -- {{ assetinfo : xx, gameobject: xx }, } , 用maxsize来在做lru
    setmetatable(o, self)
    self.__index = self
    return o
end

function Pool:load(prefabassetinfo, callback)
    if prefabassetinfo == nil then
        callback(nil, "assetinfo nil")
        return
    end

    for i, item in ipairs(self.pool) do
        if item.assetinfo == prefabassetinfo then
            table.remove(self.pool, i)
            --print("take and reuse", i, item.assetinfo.assetpath)
            item.gameobject:SetActive(true)
            callback(item.gameobject)
            return
        end
    end

    res.load(prefabassetinfo, function(asset, err)
        if asset == nil then
            res.free(prefabassetinfo)
            callback(nil, err)
        else
            local go = GameObject.Instantiate(asset)
            res.free(prefabassetinfo)
            callback(go)
        end
    end)
end

function Pool:free(prefabassetinfo, gameobject)
    if gameobject == nil then
        return
    end
    --print("put pool", prefabassetinfo.assetpath, gameobject)
    gameobject:SetActive(false)
    table.insert(self.pool, {assetinfo = prefabassetinfo, gameobject = gameobject} )
    if #self.pool > self.maxsize then
        local item = self.pool[1]
        --print("free latest", item.assetinfo.assetpath, item.gameobject)
        GameObject.Destroy(item.gameobject)
        table.remove(self.pool, 1)
    end
end

return Pool



