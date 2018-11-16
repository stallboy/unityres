local util = require "res.util"
local logger = require "common.Logger"

local Resources = UnityEngine.Resources

--------------------------------------------------------
--- res之下是Cache，内部实现类，是资源的cache
--- 一个资源的生命周期如下：
--- 1，res.load(a) 得到c，c依赖bundle B，bundle B依赖bundle A。c->B->A
--- 则这时c，B，A都再各自cache.loaded 中，refcnt为1
--- 2，res.free(a) 这时c进入cache.cached
--- 3，cache.purge 出c，c被真正释放，同时开始释放c的直接依赖B，B进入cache.cached
--- 4，cache.purge 出B，B被真正释放，同时开始释放B的直接依赖A，A进入cache.cached
--- 5，cache.purge 出A，A被真正释放


local Cache = {}
Cache.res = nil --- 这个由res初始化，免得重复依赖
Cache.all = {}

function Cache:new(name, maxsize)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table.insert(Cache.all, instance)

    instance.name = name
    instance.maxsize = maxsize
    instance.loaded = {} --- { assetid : { asset: xx, err: xx, refcnt: xx, assetinfo: xx}, ... }, 这个不会删除，asset 为nil也保存
    instance.cached = {} --- { assetid : { asset: xx, err: xx, touch: xx, assetinfo: xx }, ... } , 用maxsize来在做lru
    instance.serial = 0
    return instance
end

function Cache.dumpAll(print)
    print("======== Cache.dumpAll,,")
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
    print("==== Cache=" .. self.name .. ",,")
    local sorted = {}
    for assetid, _ in pairs(self.loaded) do
        table.insert(sorted, assetid)
    end
    table.sort(sorted)
    for _, assetid in ipairs(sorted) do
        local v = self.loaded[assetid]
        print("    + " .. v.assetinfo.assetpath .. ",refcnt=" .. v.refcnt .. (v.err and ",err=" .. v.err or ","))
    end

    local sorted = {}
    for assetid, _ in pairs(self.cached) do
        table.insert(sorted, assetid)
    end
    table.sort(sorted)
    for _, assetid in ipairs(sorted) do
        local v = self.cached[assetid]
        print("    - " .. v.assetinfo.assetpath .. ",touch=" .. v.touch .. (v.err and ",err=" .. v.err or ","))
    end
end


function Cache:_get(assetinfo)
    local assetid = assetinfo.assetid
    local a = self.loaded[assetid]
    if a then
        a.refcnt = a.refcnt + 1
        --print("get addrefto", assetinfo.assetpath, a.refcnt)
        return a
    else
        local c = self.cached[assetid]
        if c then
            self.cached[assetid] = nil --- 出cached，进loaded
            a = { asset = c.asset, err = c.err, refcnt = 1, assetinfo = c.assetinfo }
            self.loaded[assetid] = a
            return a
        else
            return nil
        end
    end
end

function Cache:_put(assetinfo, asset, err, refcount)
    local assetid = assetinfo.assetid
    local c = self.cached[assetid]
    if c then
        self.cached[assetid] = nil --- 不应该到这里
        logger.Error("cache.put in cached {0}", assetinfo.assetpath)
    end

    local a = self.loaded[assetid]
    if a then
        a.refcnt = a.refcnt + refcount --- 不应该到这里
        logger.Error("cache.put in loaded {0}", assetinfo.assetpath)
    else
        --print("put setref", assetinfo.assetpath, refcount)
        self.loaded[assetid] = { asset = asset, err = err, refcnt = refcount, assetinfo = assetinfo } --- 入口，先入loaded
    end
end

function Cache:_free(assetinfo)
    local assetid = assetinfo.assetid
    local a = self.loaded[assetid]
    if a then
        a.refcnt = a.refcnt - 1
        --print("free", assetpath, a.refcnt)
        if a.refcnt <= 0 then
            self.loaded[assetid] = nil --- 出loaded，进cached
            self.serial = self.serial + 1
            self.cached[assetid] = { asset = a.asset, err = a.err, touch = self.serial, assetinfo = a.assetinfo }
            self:_purge()
        end
    else
        logger.Error("cache.free not in loaded {0}", assetinfo.assetpath) --- 不应该到这里
    end
end

function Cache:_purge()
    while util.table_len(self.cached) > self.maxsize do
        local eldest_assetid
        local eldest_cache
        for assetid, cache in pairs(self.cached) do
            if eldest_assetid == nil or cache.touch < eldest_cache.touch then
                eldest_assetid = assetid
                eldest_cache = cache
            end
        end

        if eldest_assetid then
            self.cached[eldest_assetid] = nil --- 出口
            local asset = eldest_cache.asset
            local assetinfo = eldest_cache.assetinfo
            local type = assetinfo.type
            if asset then
                if type == util.assettype.assetbundle then
                    logger.Res("    AB.Unload {0}", assetinfo.assetpath)
                    asset:Unload(true)
                    --- assetbundle都没有引用了，那些个依赖它的prefab，asset肯定也没有应用了，可以放心unload(true)
                --elseif type == util.assettype.prefab then
                    --logger.Res("    Ignored Unload {0}", eldest_assetid)
                    --- 不担心，会由assetbundle释放。假设所有的prefab都来自assetbundle
                --else
                --    不能释放
                --    Resources.UnloadAsset(asset)
                end
            end
            Cache.res._realfree(assetinfo)
        end
    end
end

return Cache