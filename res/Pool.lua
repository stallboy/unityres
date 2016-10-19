local res = require "res.res"
local util = require "res.util"
local logger = require "common.Logger"

local GameObject = UnityEngine.GameObject

local Pool = {}
Pool.all = {}

function Pool:new(name, maxsize, max_extra_res_size, poolparent, destroycallback)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table.insert(Pool.all, instance)

    instance.name = name
    instance.maxsize = maxsize
    instance.max_extra_res_size = max_extra_res_size
    instance.poolparent = poolparent
    instance.destroycallback = destroycallback

    instance.cache = {} --- assetinfo : { usingCnt = xx, pool = {gameobject={touch=xx, attachedData=xx} , ...}, poolCnt=xx, poolTouch=xx }
    instance.serial = 0
    return instance
end

----- 调试相关
function Pool.dumpAll(print)
    print("======== Pool.dumpAll")
    for _, pool in pairs(Pool.all) do
        if not pool:_isempty() then
            pool:_dump(print)
        end
    end
end

function Pool:_isempty()
    return util.table_isempty(self.cache)
end

function Pool:_dump(print)
    print("==== Pool=" .. self.name)
    for ai, aicache in pairs(self.cache) do
        if aicache.usingCnt > 0 then
            print("    + " .. ai.assetpath .. ",usingCnt=" .. aicache.usingCnt .. ",poolCnt=" .. aicache.poolCnt .. "," .. util.table_len(aicache.pool) .. ",poolTouch=" .. aicache.poolTouch)
        end
    end
    for ai, aicache in pairs(self.cache) do
        if aicache.usingCnt <= 0 then
            print("    - " .. ai.assetpath .. ",usingCnt=" .. aicache.usingCnt .. ",poolCnt=" .. aicache.poolCnt .. "," .. util.table_len(aicache.pool) .. ",poolTouch=" .. aicache.poolTouch)
        end
    end
end

function Pool:_debugaction(act, prefabassetinfo)
    if DebugUtils.logPool then
        logger.Pool(act .. " " .. prefabassetinfo.assetpath)
    end
end

function Pool:_debugdump()
    if DebugUtils.logPool then
        self:_dump(logger.Pool)
    end
end

----- 之后是接口
function Pool:_load(prefabassetinfo, callback)
    if prefabassetinfo == nil then
        callback(nil, "assetinfo nil")
        return
    end

    local cache = self.cache[prefabassetinfo]
    if cache == nil then
        --- 这里要先记上数，占住位。
        cache = { usingCnt = 1, pool = {}, poolCnt = 0, poolTouch = 0 }
        self.cache[prefabassetinfo] = cache
    else
        cache.usingCnt = cache.usingCnt + 1
    end

    local eldest_go
    local eldest_touch
    for go, goinfo in pairs(cache.pool) do
        if eldest_go == nil or goinfo.touch < eldest_touch then
            eldest_go = go
            eldest_touch = goinfo.touch
        end
    end

    if eldest_go then
        cache.pool[eldest_go] = nil
        cache.poolCnt = cache.poolCnt - 1
        eldest_go:SetActive(true)
        callback(eldest_go)
    else
        res.load(prefabassetinfo, function(asset, err)
            if asset == nil then
                res.free(prefabassetinfo) --- 这里要释放
                cache.usingCnt = cache.usingCnt - 1
                if cache.usingCnt == 0 and cache.poolCnt == 0 then
                    self.cache[prefabassetinfo] = nil
                end

                callback(nil, err)
            else
                --- 保持对资源的引用。
                local go = GameObject.Instantiate(asset)
                callback(go)
            end
        end)
    end
end

function Pool:load(prefabassetinfo, callback)
    self:_debugaction("load", prefabassetinfo)
    self:_load(prefabassetinfo, function(go, err)
        callback(go, err)
        self:_debugdump()
    end)
end


function Pool:makeSureInPool(prefabassetinfo, callback)
    self:_debugaction("makeSureInPool", prefabassetinfo)
    self:_load(prefabassetinfo, function(go, _)
        --- no purge
        if go then
            self:_free(prefabassetinfo, go)
        end
        callback()
        self:_debugdump()
    end)
end

function Pool:free(prefabassetinfo, gameobject, attachedData)
    self:_debugaction("free", prefabassetinfo)
    if self:_free(prefabassetinfo, gameobject, attachedData) then
        self:_purge()
    end
    self:_debugdump()
end

function Pool:_free(prefabassetinfo, gameobject, attachedData)
    if prefabassetinfo == nil then
        logger.Error("pool.free prefabassetinfo=nil")
        return false
    end

    if gameobject == nil then
        logger.Error("pool.free gameobject=nil, assetinfo=" .. prefabassetinfo.assetpath)
        return false
    end

    local cache = self.cache[prefabassetinfo]
    if cache == nil then
        logger.Error("pool.free cache=nil, assetinfo=" .. prefabassetinfo.assetpath)
        return false
    end

    local old = cache.pool[gameobject]
    if old then
        logger.Error("pool.free cache pool has this gameobject. assetinfo=" .. prefabassetinfo.assetpath)
        return false
    end

    gameobject:SetActive(false)
    if self.poolparent then
        --- 要加上false，Character里依赖free之后不改变gameobject的local transform
        gameobject.transform:SetParent(self.poolparent, false)
    end

    cache.usingCnt = cache.usingCnt - 1
    self.serial = self.serial + 1
    cache.pool[gameobject] = { attachedData = attachedData, touch = self.serial }
    cache.poolCnt = cache.poolCnt + 1
    cache.poolTouch = self.serial

    return true
end

function Pool:_purge()
    local eldestpool_assetinfo
    local eldestpool_cache
    local onlypoolcnt = 0

    local eldest_touch
    local eldest_assetinfo
    local eldest_cache
    local eldest_go
    local eldest_goinfo
    local gocnt = 0

    for ai, aicache in pairs(self.cache) do
        if aicache.usingCnt == 0 and aicache.poolCnt > 0 then
            onlypoolcnt = onlypoolcnt + 1
            if eldestpool_cache == nil or aicache.poolTouch < eldestpool_cache.poolTouch then
                eldestpool_assetinfo = ai
                eldestpool_cache = aicache
            end
        end

        for go, goinfo in pairs(aicache.pool) do
            gocnt = gocnt + 1
            if eldest_go == nil or goinfo.touch < eldest_touch then
                eldest_assetinfo = ai
                eldest_cache = aicache
                eldest_go = go
                eldest_goinfo = goinfo
                eldest_touch = goinfo.touch
            end
        end
    end

    if onlypoolcnt > self.max_extra_res_size then
        --- 删除这个资源 对应的场景中的所有对象
        for go, goinfo in pairs(eldestpool_cache.pool) do
            GameObject.Destroy(go)
            if self.destroycallback then
                self.destroycallback(goinfo.attachedData)
            end
            res.free(eldest_assetinfo)
        end
        self.cache[eldestpool_assetinfo] = nil
    elseif gocnt > self.maxsize then
        --- 删除一个场景对象
        GameObject.Destroy(eldest_go)
        if self.destroycallback then
            self.destroycallback(eldest_goinfo.attachedData)
        end
        eldest_cache.pool[eldest_go] = nil
        eldest_cache.poolCnt = eldest_cache.poolCnt - 1

        if eldest_cache.usingCnt == 0 and eldest_cache.poolCnt == 0 then
            self.cache[eldest_assetinfo] = nil
        end
    end
end


return Pool



