local util = require "res.util"
local logger = require "common.Logger"

local Resources = UnityEngine.Resources

local Cache = {}
Cache.all = {}

function Cache:new(name, maxsize)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table.insert(Cache.all, instance)

    instance.name = name
    instance.maxsize = maxsize
    instance.loaded = {} -- { assetpath : { asset: xx, err: xx, refcnt: xx, type: xx}, ... }, 这个不会删除，asset 为nil也保存
    instance.cached = {} -- { assetpath : { asset: xx, err: xx, touch: xx, type: xx }, ... } , 用maxsize来在做lru
    instance.serial = 0
    return instance
end

function Cache.dumpAll(print)
    print("======== Cache.dumpAll")
    for _, cache in pairs(Cache.all) do
        if not cache:_isempty() then
            cache:_dump(print)
        end
    end
end

function Cache:_isempty()
    return util.table_isempty(self.loaded) and util.table_isempty(self.cached)
end

function Cache:_dump(print)
    print("==== Cache=" .. self.name)
    for assetpath, v in pairs(self.loaded) do
        print("    + " .. assetpath .. ",refcnt=" .. v.refcnt .. (v.err and ",err=" .. v.err or ""))
    end

    for assetpath, v in pairs(self.cached) do
        print("    - " .. assetpath .. ",touch=" .. v.touch .. (v.err and ",err=" .. v.err or ""))
    end
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
        logger.Error("cache.put in cached {0}", assetpath)
    end

    local a = self.loaded[assetpath]
    if a then
        a.refcnt = a.refcnt + refcount
        logger.Error("cache.put in loaded {0}", assetpath)
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
        logger.Error("cache.free not in loaded {0}", assetpath)
    end
end

function Cache:_purge()
    while util.table_len(self.cached) > self.maxsize do
        local eldest_assetpath
        local eldest_cache
        for assetpath, cache in pairs(self.cached) do
            if eldest_assetpath == nil or cache.touch < eldest_cache.touch then
                eldest_assetpath = assetpath
                eldest_cache = cache
            end
        end

        if eldest_assetpath then
            self.cached[eldest_assetpath] = nil --出口
            local asset = eldest_cache.asset
            if asset then
                if eldest_cache.type == util.assettype.assetbundle then
                    logger.Res("    AssetBundle.Unload {0}", eldest_assetpath)
                    asset:Unload(true)
                    --- assetbundle都没有引用了，那些个依赖它的prefab，asset肯定也没有应用了，可以放心unload(true)
                elseif eldest_cache.type == util.assettype.prefab then
                    logger.Res("    Ignored Unload {0}", eldest_assetpath)
                    --- 不担心，会由assetbundle释放。假设所有的prefab都来自assetbundle
                else
                    logger.Res("    Resources.UnloadAsset {0}", eldest_assetpath)
                    Resources.UnloadAsset(asset)
                end
            end
        end
    end
end

return Cache