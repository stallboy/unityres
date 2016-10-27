local res = require "res.res"
local util = require "res.util"
local logger = require "common.Logger"

local GameObject = UnityEngine.GameObject
local FarawayPosition = UnityEngine.Vector3(10000, 10000, 10000)

local Pool = {}
Pool.all = {}

function Pool:new(name, max_extra_go_size, max_extra_res_size, poolparent, pool_by_setposition, destroycallback)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table.insert(Pool.all, instance)

    instance.name = name
    instance.max_extra_go_size = max_extra_go_size
    instance.max_extra_res_size = max_extra_res_size
    instance.poolparent = poolparent
    instance.pool_by_setposition = pool_by_setposition
    instance.destroycallback = destroycallback

    instance.serial = 0
    instance.cache = {} --- assetinfo : { usingCnt = xx, pool = {gameobject={touch=xx, attachedData=xx} , ...}, poolCnt=xx, poolTouch=xx }
    instance.usingResCount = 0
    instance.extraResCount = 0
    instance.usingObjCount = 0
    instance.extraObjCount = 0
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
    print("==== Pool=" .. self.name .. "  ===  using=" .. self.usingResCount .. "/" .. self.usingObjCount .. ", extra=" .. self.extraResCount .. "/" .. self.extraObjCount)
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

----- 接口，这里的load跟res.load不同，如果结果为nil，是不需要调用free的
function Pool:load(prefabassetinfo, callback)
    logger.Pool("load {0}", prefabassetinfo.assetpath)
    self:_load(prefabassetinfo, callback)
end

function Pool:free(prefabassetinfo, gameobject, attachedData)
    logger.Pool("free {0}", prefabassetinfo.assetpath)
    if self:_free(prefabassetinfo, gameobject, attachedData) then
        self:_purge()
    end
end

----- 实现
function Pool:_load(prefabassetinfo, callback)
    if prefabassetinfo == nil then
        callback(nil, "assetinfo nil")
        return
    end


    local eldest_go
    local eldest_touch

    local cache = self.cache[prefabassetinfo]
    if cache == nil then
        --- 这里要先记上数，占住位。
        cache = { usingCnt = 1, pool = {}, poolCnt = 0, poolTouch = 0 }
        self.cache[prefabassetinfo] = cache
        self.usingResCount = self.usingResCount + 1
        self.usingObjCount = self.usingObjCount + 1
    else
        cache.usingCnt = cache.usingCnt + 1
        self.usingObjCount = self.usingObjCount + 1
        for go, goinfo in pairs(cache.pool) do
            if eldest_go == nil or goinfo.touch < eldest_touch then
                eldest_go = go
                eldest_touch = goinfo.touch
            end
        end
    end

    if eldest_go then
        cache.pool[eldest_go] = nil
        cache.poolCnt = cache.poolCnt - 1
        self.extraObjCount = self.extraObjCount - 1
        if cache.usingCnt == 1 then
            self.usingResCount = self.usingResCount + 1
            self.extraResCount = self.extraResCount - 1
        end
        eldest_go:SetActive(true)
        callback(eldest_go)
    else
        res.load(prefabassetinfo, function(asset, err)
            if asset == nil then
                res.free(prefabassetinfo) --- 这里要释放
                cache.usingCnt = cache.usingCnt - 1
                self.usingObjCount = self.usingObjCount - 1
                if cache.usingCnt == 0 and cache.poolCnt == 0 then
                    self.cache[prefabassetinfo] = nil
                    self.usingResCount = self.usingResCount - 1
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

    if cache.usingCnt <= 0 then
        logger.Error("pool.free cache usingCnt<=0, assetinfo=" .. prefabassetinfo.assetpath .. ",usingCnt=" .. cache.usingCnt)
        return false
    end

    local old = cache.pool[gameobject]
    if old then
        logger.Error("pool.free cache pool has this gameobject. assetinfo=" .. prefabassetinfo.assetpath)
        return false
    end

    if self.pool_by_setposition then
        gameobject.transform.position = FarawayPosition
    else
        gameobject:SetActive(false)
    end

    if self.poolparent then
        --- 要加上false，Character里依赖free之后不改变gameobject的local transform
        gameobject.transform:SetParent(self.poolparent, false)
    end


    self.serial = self.serial + 1
    cache.pool[gameobject] = { attachedData = attachedData, touch = self.serial }
    cache.poolTouch = self.serial

    cache.usingCnt = cache.usingCnt - 1
    cache.poolCnt = cache.poolCnt + 1
    self.usingObjCount = self.usingObjCount - 1
    self.extraObjCount = self.extraObjCount + 1
    if cache.usingCnt == 0 then
        self.usingResCount = self.usingResCount - 1
        self.extraResCount = self.extraResCount + 1
    end

    return true
end

function Pool:_purge()
    while true do
        if not self:_purge_next() then
            break
        end
    end
end

function Pool:_purge_next()
    if self.extraResCount > self.max_extra_res_size then
        local eldestpool_assetinfo
        local eldestpool_cache
        for ai, aicache in pairs(self.cache) do
            if aicache.usingCnt == 0 and aicache.poolCnt > 0 then
                if eldestpool_cache == nil or aicache.poolTouch < eldestpool_cache.poolTouch then
                    eldestpool_assetinfo = ai
                    eldestpool_cache = aicache
                end
            end
        end
        --- 删除这个资源 对应的所有场景对象
        logger.Pool("--purge extra res {0}", eldestpool_assetinfo.assetpath)
        for go, goinfo in pairs(eldestpool_cache.pool) do
            GameObject.Destroy(go)
            if self.destroycallback then
                self.destroycallback(goinfo.attachedData)
            end
            res.free(eldestpool_assetinfo)
            self.extraObjCount = self.extraObjCount - 1
        end
        self.cache[eldestpool_assetinfo] = nil
        self.extraResCount = self.extraResCount - 1
        return self.extraResCount > self.max_extra_res_size or self.extraObjCount > self.max_extra_go_size
    elseif self.extraObjCount > self.max_extra_go_size then
        local eldest_touch
        local eldest_assetinfo
        local eldest_cache
        local eldest_go
        local eldest_goinfo
        for ai, aicache in pairs(self.cache) do
            for go, goinfo in pairs(aicache.pool) do
                if eldest_go == nil or goinfo.touch < eldest_touch then
                    eldest_assetinfo = ai
                    eldest_cache = aicache
                    eldest_go = go
                    eldest_goinfo = goinfo
                    eldest_touch = goinfo.touch
                end
            end
        end

        --- 删除一个场景对象
        logger.Pool("--purge extra go {0}", eldest_assetinfo.assetpath)
        GameObject.Destroy(eldest_go)
        if self.destroycallback then
            self.destroycallback(eldest_goinfo.attachedData)
        end
        res.free(eldest_assetinfo)
        self.extraObjCount = self.extraObjCount - 1
        eldest_cache.pool[eldest_go] = nil
        eldest_cache.poolCnt = eldest_cache.poolCnt - 1

        if eldest_cache.usingCnt == 0 and eldest_cache.poolCnt == 0 then
            self.cache[eldest_assetinfo] = nil
            self.extraResCount = self.extraResCount - 1
        end
        return self.extraObjCount > self.max_extra_go_size
    else
        return false
    end
end

return Pool