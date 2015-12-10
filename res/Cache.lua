local Resources = UnityEngine.Resources


local function table_len(a)
    local len = 0
    for _, _ in pairs(a) do
        len = len + 1
    end
    return len
end

local Cache = {
    _UNLOAD_ASSETBUNDLE = 1,
    _UNLOAD_RESOURCE = 2,
    _UNLOAD_GAMEOBJECT = 3,
}

function Cache:new(maxsize, unloadtype)
    local o = {}
    o.maxsize = maxsize
    o.unloadtype = unloadtype;
    o.loaded = {} -- { assetpath : { asset: xx, refcnt: xx}, ... }, 这个不会删除
    o.cached = {} -- { assetpath : { asset: xx, touch: xx }, ... } , 用maxsize来在做lru
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
            self.cached[assetpath] = nil
            self.loaded[assetpath] = { asset = c.asset, refcnt = 1 }
            return c.asset
        else
            return nil
        end
    end
end

function Cache:_newloaded(assetpath, asset)
    local c = self.cached[assetpath]
    if c then
        self.cached[assetpath] = nil
    end

    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + 1
    else
        self.loaded[assetpath] = { asset = asset, refcnt = 1 }
    end
end

function Cache:_free(assetpath)
    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt - 1
        if a.refcnt <= 0 then
            self.serial = self.serial + 1
            self.cached[assetpath] = { asset = a.asset, touch = self.serial }
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
    if (table_len(self.cached) > self.maxsize) then
        local eldest_assetpath = nil
        local eldest_asset
        local eldest_touch
        local touched = false
        for assetpath, at in pair(self.cached) do
            if not touched then
                touched = true
                eldest_assetpath = assetpath
                eldest_asset = at.asset
                eldest_touch = at.touch
            elseif at.touch < eldest_touch then
                eldest_assetpath = assetpath
                eldest_asset = at.asset
                eldest_touch = at.touch
            end
        end

        if eldest_assetpath then
            self.cached[eldest_assetpath] = nil
            if (self.unloadtype == Cache._UNLOAD_ASSETBUNDLE) then
                eldest_asset:Unload(false)
            elseif (self.unloadtype == Cache._UNLOAD_RESOURCE) then
                Resources.UnloadAsset(eldest_asset)
            else
                -- do not UnloadUnusedAssets
            end
        end
    end
end

return Cache