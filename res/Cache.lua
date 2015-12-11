local util = require "res.util"

local Resources = UnityEngine.Resources

local Cache = {
    bundle2cache = {}
}

function Cache:new(maxsize)
    local o = {}
    o.maxsize = maxsize -- 一定要 > 0
    o.loaded = {} -- { assetpath : { asset: xx, refcnt: xx, type: xx}, ... }, 这个不会删除
    o.cached = {} -- { assetpath : { asset: xx, touch: xx, type: xx }, ... } , 用maxsize来在做lru
    o.serial = 0
    setmetatable(o, self)
    self.__index = self
    return o
end

function Cache:_load(assetpath)
    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + 1
        return a.asset
    else
        local c = self.cached[assetpath]
        if c then
            self.cached[assetpath] = nil --出cached，进loaded
            self.loaded[assetpath] = { asset = c.asset, refcnt = 1, type = c.type }
            return c.asset
        else
            return nil
        end
    end
end

function Cache:_newloaded(assetpath, asset, type)
    local c = self.cached[assetpath]
    if c then
        self.cached[assetpath] = nil
    end

    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + 1
    else
        self.loaded[assetpath] = { asset = asset, refcnt = 1, type = type } --入口，先入loaded
        if type == util.assettype.assetbundle then
            Cache.bundle2cache[assetpath] = self
        end
    end
end

function Cache:_free(assetpath)
    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt - 1
        if a.refcnt <= 0 then
            self.loaded[assetpath] = nil --出loaded，进cached
            self.serial = self.serial + 1
            self.cached[assetpath] = { asset = a.asset, touch = self.serial, type = a.type }
            self:_purge()
        end
    else
        local c = self.cached[assetpath]
        if c then
            self.serial = self.serial + 1
            c.touch = self.serial
        end
    end
end

function Cache:_purge()
    if (util.table_len(self.cached) > self.maxsize) then
        local eldest_assetpath
        local eldest_cache
        for assetpath, cache in pairs(self.cached) do
            if eldest_assetpath == nil then
                eldest_assetpath = assetpath
                eldest_cache = cache
            elseif cache.touch < eldest_cache.touch then
                eldest_assetpath = assetpath
                eldest_cache = cache
            end
        end

        if eldest_assetpath then
            self.cached[eldest_assetpath] = nil --出口
            if (eldest_cache.type == util.assettype.assetbundle) then
                eldest_cache.asset:Unload(false)
                Cache.bundle2cache[eldest_assetpath] = nil
            elseif (eldest_cache.type == util.assettype.asset) then
                Resources.UnloadAsset(eldest_cache.asset)
            else
                -- do not UnloadUnusedAssets
            end
        end
    end
end

return Cache