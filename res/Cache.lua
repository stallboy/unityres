local util = require "res.util"

local Resources = UnityEngine.Resources

local Cache = {}

function Cache:new(maxsize)
    local o = {}
    o.maxsize = maxsize
    o.loaded = {} -- { assetpath : { asset: xx, err: xx, refcnt: xx, type: xx}, ... }, 这个不会删除，asset 为nil也保存
    o.cached = {} -- { assetpath : { asset: xx, err: xx, touch: xx, type: xx }, ... } , 用maxsize来在做lru
    o.serial = 0
    setmetatable(o, self)
    self.__index = self
    return o
end

function Cache:_get(assetpath)
    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + 1
        return a
    else
        local c = self.cached[assetpath]
        if c then
            self.cached[assetpath] = nil --出cached，进loaded
            a = { asset = c.asset, err = c.err, refcnt = 1, type = c.type }
            self.loaded[assetpath] = a
            return a
        else
            return nil
        end
    end
end

function Cache:_put(assetpath, asset, err, type, refcount)
    local c = self.cached[assetpath]
    if c then
        self.cached[assetpath] = nil
    end

    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + refcount
    else
        self.loaded[assetpath] = { asset = asset, err = err, refcnt = refcount, type = type } --入口，先入loaded
    end
end

function Cache:_free(assetpath)
    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt - 1
        if a.refcnt <= 0 then
            self.loaded[assetpath] = nil --出loaded，进cached
            self.serial = self.serial + 1
            self.cached[assetpath] = { asset = a.asset, err = a.err, touch = self.serial, type = a.type }
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
                util.debuglog("    AssetBundle.Unload "..eldest_assetpath)
                eldest_cache.asset:Unload(false)
            elseif (eldest_cache.type == util.assettype.asset) then
                util.debuglog("    Resources.UnloadAsset "..eldest_assetpath)
                Resources.UnloadAsset(eldest_cache.asset)
            else
                util.debuglog("    Ignored Unload "..eldest_assetpath)
                -- do not UnloadUnusedAssets
            end
        end
    end
end

return Cache