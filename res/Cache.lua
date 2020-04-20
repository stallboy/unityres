local util = require "res.util"
local res = require "res.res"
local logger = require "common.Logger"
local UnityObjectDestroy = UnityEngine.Object.Destroy
local table_insert = table.insert
local pairs = pairs

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
Cache.all = {}
local all_need_update = {} -- cache -> true
Cache.all_need_update = all_need_update

function Cache:new(name, maxsize)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table_insert(Cache.all, instance)
    instance.name = name
    instance.maxsize = maxsize
    --- 用assetid 作为key，支持实时构造的assetinfo
    instance.loaded = {} --- { assetid : { asset: xx, err: xx, refcnt: xx, assetinfo: xx}, ... }, 这个不会删除，asset 为nil也保存
    instance.loaded_size = 0
    instance.cached = {} --- { assetid : { asset: xx, err: xx, touch: xx, assetinfo: xx }, ... } , 用maxsize来在做lru
    instance.cached_size = 0
    instance.serial = 0
    return instance
end

function Cache:setCachePolicy(maxsize, timeout_seconds)
    self.maxsize = maxsize
    if self.maxsize > 0 and timeout_seconds and timeout_seconds >= 1 then
        timeout_seconds = math.floor(timeout_seconds)
        if timeout_seconds > 99 then
            timeout_seconds = 99
        end
        self.timeout_cur_accumulate = math.random() --- 防止一起来per_second
        self.timeout_need_more_free = false
        self.timeout_keys = {} --- assetid : true 一帧删除一个，防止大量删除导致卡帧
        self.timeout_seconds = timeout_seconds
        all_need_update[self] = true
    else
        all_need_update[self] = nil
        self.timeout_keys = nil
    end
end

function Cache:_next_serial()
    self.serial = self.serial + 100
    if self.timeout_seconds then
        return self.serial + self.timeout_seconds
    else
        return self.serial
    end
end

function Cache.updateAll(deltaTime)
    for c, _ in pairs(all_need_update) do
        c:_update(deltaTime)
    end
end

function Cache:_update(deltaTime)
    if self.cached_size == 0 then
        return
    end
    self.timeout_cur_accumulate = self.timeout_cur_accumulate + deltaTime
    if self.timeout_cur_accumulate > 1 then
        self.timeout_cur_accumulate = 0
        self.timeout_need_more_free = false
        local timeout_assetid
        local timeout_item
        for assetid, item in pairs(self.cached) do
            local time_left = item.touch % 100
            if time_left > 0 then
                item.touch = item.touch - 1
            elseif timeout_assetid == nil then
                timeout_assetid = assetid
                timeout_item = item
            else
                self.timeout_keys[assetid] = true
                self.timeout_need_more_free = true
            end
        end

        if timeout_assetid then
            self:_realfree(timeout_assetid, timeout_item)
        end

    elseif self.timeout_need_more_free then
        local has = false
        for assetid, _ in pairs(self.timeout_keys) do
            local item = self.cached[assetid]
            self:_realfree(assetid, item)
            has = true
            break
        end
        self.timeout_need_more_free = has
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
            if self.timeout_keys then
                self.timeout_keys[assetid] = nil
            end
            self.cached_size = self.cached_size - 1
            a = { asset = c.asset, err = c.err, refcnt = 1, assetinfo = c.assetinfo }
            self.loaded[assetid] = a
            self.loaded_size = self.loaded_size + 1
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
        if self.timeout_keys then
            self.timeout_keys[assetid] = nil
        end
        self.cached_size = self.cached_size - 1
        logger.Error("cache.put in cached {0}", assetinfo.assetpath)
    end

    local a = self.loaded[assetid]
    if a then
        a.refcnt = a.refcnt + refcount --- 不应该到这里
        logger.Error("cache.put in loaded {0}", assetinfo.assetpath)
    else
        --print("put setref", assetinfo.assetpath, refcount)
        self.loaded[assetid] = { asset = asset, err = err, refcnt = refcount, assetinfo = assetinfo } --- 入口，先入loaded
        self.loaded_size = self.loaded_size + 1
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
            self.loaded_size = self.loaded_size - 1
            local touch = self:_next_serial()
            self.cached[assetid] = { asset = a.asset, err = a.err, touch = touch, assetinfo = a.assetinfo }
            self.cached_size = self.cached_size + 1
            self:_purge()
        end
    else
        logger.Error("cache.free not in loaded {0}", assetinfo.assetpath) --- 不应该到这里
    end
end

function Cache:_purge()
    local maxsize = util.factor_size(self.maxsize, res.cacheFactor)
    while self.cached_size > maxsize do
        local eldest_assetid
        local eldest_item
        for assetid, item in pairs(self.cached) do
            if eldest_assetid == nil or item.touch < eldest_item.touch then
                eldest_assetid = assetid
                eldest_item = item
            end
        end

        if eldest_assetid then
            self:_realfree(eldest_assetid, eldest_item)
        else
            break
        end
    end
end

function Cache:_realfree(assetid, item)
    self.cached[assetid] = nil
    if self.timeout_keys then
        self.timeout_keys[assetid] = nil
    end
    self.cached_size = self.cached_size - 1
    local asset = item.asset
    local assetinfo = item.assetinfo
    if asset then
        if assetinfo.location == util.assetlocation.net then
            if assetinfo.type == util.assettype.sprite then
                local texture = asset.texture
                UnityObjectDestroy(asset)
                UnityObjectDestroy(texture) --- sprite的texture也要释放
            else
                UnityObjectDestroy(asset)  --- 这个现在不会用到
            end
        elseif assetinfo.type == util.assettype.assetbundle then
            logger.Res("AB.Unload {0}", assetinfo.assetpath)
            asset:Unload(true)
            --- assetbundle都没有引用了，那些个依赖它的prefab，asset肯定也没有应用了，可以放心unload(true)
            --- elseif type == util.assettype.prefab then
            --- 不担心，会由assetbundle释放。假设所有的prefab都来自assetbundle
            --- else
            --- 这个也不释放，比如一个panel引用sprite，这个sprite又被自己或其他panel调用setSprite，之后再释放时导致unload，
            --- 这时unity并没有按照文档所说重新加载asset，这时图片就出现白片了
            --- Resources.UnloadAsset(asset)
        end
    end
    res._realfree(assetinfo)
end

----- 调试相关
function Cache.dumpAll(print)
    print("======== Cache.dumpAll,,")
    for _, cache in pairs(Cache.all) do
        if cache.loaded_size > 0 or cache.cached_size > 0 then
            cache:_dump(print)
        end
    end
end

function Cache:_dump(print)
    print("==== Cache=" .. self.name .. ",loaded=" .. self.loaded_size .. ",cached=" .. self.cached_size)
    local sorted = {}
    for assetid, _ in pairs(self.loaded) do
        table.insert(sorted, assetid)
    end
    table.sort(sorted)
    for _, assetid in ipairs(sorted) do
        local v = self.loaded[assetid]
        print("    + " .. v.assetinfo.assetpath .. ",refcnt=" .. v.refcnt .. (v.err and ",err=" .. v.err or ","))
    end

    sorted = {}
    for assetid, _ in pairs(self.cached) do
        table.insert(sorted, assetid)
    end
    table.sort(sorted)
    for _, assetid in ipairs(sorted) do
        local v = self.cached[assetid]
        print("    - " .. v.assetinfo.assetpath .. ",touch=" .. v.touch .. (v.err and ",err=" .. v.err or ","))
    end
end

return Cache