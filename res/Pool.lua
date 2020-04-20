local res = require "res.res"
local util = require "res.util"
local logger = require "common.Logger"

local GameObject = UnityEngine.GameObject
--local FarawayPosition = UnityEngine.Vector3(10000, 10000, 10000)
local pairs = pairs

--------------------------------------------------------
--- res之上是Pool
--- 这一层控制场景对象的cache，因为GameObject.Instantiate这个太费了。
--- 可使用SetActive来pool这个场景对象，但有时SetActive也太费，可使用SetPosition把它放到摄像机视锥体外
--- 允许设置额外的资源数量max_extra_res_size，用于控制内存大小
--- 跟res接口基本一致load，free，但这里load如果失败，不要调用free

--- Note: pool_by_setposition 好像会引发unity崩溃，不确定原因，不要用了。

local Pool = {}
Pool.all = {}
local all_need_update = {}
Pool.all_need_update = all_need_update

Pool.all_access = 0
Pool.all_hit = 0

function Pool:new(name, pool_parent, max_extra_go_size, max_extra_res_size)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    table.insert(Pool.all, instance)

    instance.name = name
    instance.pool_parent = pool_parent
    instance.max_extra_go_size = max_extra_go_size
    instance.max_extra_res_size = max_extra_res_size

    instance.serial = 0
    instance.cache = {} --- assetinfo : { usingCnt = xx, pool = {gameObject=touch , ...}, poolCnt=xx, poolTouch=xx }
    instance.usingResCount = 0
    instance.extraResCount = 0
    instance.usingObjCount = 0
    instance.extraObjCount = 0
    return instance
end

function Pool:setCachePolicy(max_extra_go_size, max_extra_res_size, timeout_seconds)
    self.max_extra_go_size = max_extra_go_size
    self.max_extra_res_size = max_extra_res_size

    if max_extra_go_size > 0 and timeout_seconds and timeout_seconds >= 1 then
        timeout_seconds = math.floor(timeout_seconds)
        if timeout_seconds > 99 then
            timeout_seconds = 99
        end
        self.timeout_cur_accumulate = math.random() --- 防止一起来per_second
        self.timeout_need_more_free = false
        self.timeout_keys = {} --- assetinfo : true 一帧删除一个，防止大量删除导致卡帧
        self.timeout_seconds = timeout_seconds
        all_need_update[self] = true
    else
        self.timeout_keys = nil
        all_need_update[self] = nil
    end
end

function Pool:_next_serial()
    self.serial = self.serial + 100
    if self.timeout_seconds then
        return self.serial + self.timeout_seconds
    else
        return self.serial
    end
end

function Pool.updateAll(deltaTime)
    for c, _ in pairs(all_need_update) do
        c:_update(deltaTime)
    end
end

function Pool:_update(deltaTime)
    if self.extraObjCount == 0 then
        return
    end

    self.timeout_cur_accumulate = self.timeout_cur_accumulate + deltaTime
    if self.timeout_cur_accumulate > 1 then
        self.timeout_cur_accumulate = 0
        self.timeout_need_more_free = false

        local timeout_assetinfo
        local timeout_go_cache
        local timeout_go
        for assetinfo, go_cache in pairs(self.cache) do
            local go_pool = go_cache.pool
            local has = false
            for go, touch in pairs(go_pool) do
                local time_left = touch % 100
                if time_left > 0 then
                    go_pool[go] = touch - 1
                elseif timeout_go == nil then
                    timeout_go = go
                    timeout_assetinfo = assetinfo
                    timeout_go_cache = go_cache
                else
                    has = true
                end
            end
            if has then
                self.timeout_keys[assetinfo] = true
                self.timeout_need_more_free = true
            else
                self.timeout_keys[assetinfo] = nil
            end
        end

        if timeout_go then
            self:_realfree(timeout_assetinfo, timeout_go_cache, timeout_go)
        end

    elseif self.timeout_need_more_free then
        local first_assetinfo
        local timeout_go_cache
        local timeout_go
        local has = false
        for assetinfo, _ in pairs(self.timeout_keys) do
            has = true
            first_assetinfo = assetinfo
            local go_cache = self.cache[assetinfo]
            if go_cache then
                for go, touch in pairs(go_cache.pool) do
                    local time_left = touch % 100
                    if time_left <= 0 then
                        timeout_go = go
                        timeout_go_cache = go_cache
                        break
                    end
                end
            end
            break
        end

        self.timeout_need_more_free = has
        if timeout_go then
            self:_realfree(first_assetinfo, timeout_go_cache, timeout_go)
        elseif first_assetinfo then
            self.timeout_keys[first_assetinfo] = nil
        end
    end
end

----- 接口，这里的load跟res.load不同，如果结果为nil，是不需要调用free的，当然调用也行
function Pool:load(prefabassetinfo, callback, ...)
    self:_doload(prefabassetinfo, callback, ...)
end

function Pool:free(prefabassetinfo, gameobject)
    if self:_dofree(prefabassetinfo, gameobject) then
        self:_purge()
    end
end

function Pool:clear()
    local old = self.max_extra_go_size
    self.max_extra_go_size = 0
    self:_purge()
    self.max_extra_go_size = old
end

----- 实现
local function ResLoadDone(asset, err, self, prefabassetinfo, cache, callback, ...)
    if asset == nil then
        --- 这里要释放
        res.free(prefabassetinfo)
        cache.usingCnt = cache.usingCnt - 1
        self.usingObjCount = self.usingObjCount - 1
        if cache.usingCnt == 0 and cache.poolCnt == 0 then
            self.cache[prefabassetinfo] = nil
            self.usingResCount = self.usingResCount - 1
        end

        callback(nil, err, ...)
    else
        --- 保持对资源的引用。
        local go = GameObject.Instantiate(asset)
        callback(go, nil, ...)
    end
end

function Pool:_doload(prefabassetinfo, callback, ...)
    if prefabassetinfo == nil then
        callback(nil, "assetinfo nil", ...)
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
        for go, touch in pairs(cache.pool) do
            if eldest_go == nil or touch < eldest_touch then
                eldest_go = go
                eldest_touch = touch
            end
        end
    end

    Pool.all_access = Pool.all_access + 1
    if eldest_go then
        Pool.all_hit = Pool.all_hit + 1
        cache.pool[eldest_go] = nil
        cache.poolCnt = cache.poolCnt - 1
        self.extraObjCount = self.extraObjCount - 1
        if cache.usingCnt == 1 then
            self.usingResCount = self.usingResCount + 1
            self.extraResCount = self.extraResCount - 1
        end
        eldest_go:SetActive(true)
        callback(eldest_go, nil, ...)
    else
        res.load(prefabassetinfo, ResLoadDone, self, prefabassetinfo, cache, callback, ...)
    end
end

function Pool:_dofree(prefabassetinfo, gameobject)
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

    --if self.pool_by_setposition then
    --    gameobject.transform.position = FarawayPosition
    --else
    gameobject:SetActive(false)

    if self.pool_parent then
        --- 要加上false，Character里依赖free之后不改变gameobject的local transform
        gameobject.transform:SetParent(self.pool_parent, false)
    end

    local touch = self:_next_serial()
    cache.pool[gameobject] = touch
    cache.poolTouch = touch

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
    local max_extra_go_size = util.factor_size(self.max_extra_go_size, res.cacheFactor)
    local max_extra_res_size = util.factor_size(self.max_extra_res_size, res.cacheFactor)
    while true do
        if not self:_purge_next(max_extra_go_size, max_extra_res_size) then
            break
        end
    end
end

function Pool:_purge_next(max_extra_go_size, max_extra_res_size)
    if self.extraResCount > max_extra_res_size then
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
        --logger.Pool("--purge extra res {0}", eldestpool_assetinfo.assetpath)
        for go, _ in pairs(eldestpool_cache.pool) do
            GameObject.Destroy(go)
            res.free(eldestpool_assetinfo)
            self.extraObjCount = self.extraObjCount - 1
        end
        self.cache[eldestpool_assetinfo] = nil
        self.extraResCount = self.extraResCount - 1
        return self.extraResCount > max_extra_res_size or self.extraObjCount > max_extra_go_size
    elseif self.extraObjCount > max_extra_go_size then
        local eldest_touch
        local eldest_assetinfo
        local eldest_cache
        local eldest_go
        for ai, aicache in pairs(self.cache) do
            for go, touch in pairs(aicache.pool) do
                if eldest_go == nil or touch < eldest_touch then
                    eldest_assetinfo = ai
                    eldest_cache = aicache
                    eldest_go = go
                    eldest_touch = touch
                end
            end
        end

        --- 删除一个场景对象
        --logger.Pool("--purge extra go {0}", eldest_assetinfo.assetpath)
        self:_realfree(eldest_assetinfo, eldest_cache, eldest_go)
        return self.extraObjCount > max_extra_go_size
    else
        return false
    end
end


function Pool:_realfree(assetinfo, go_cache, go)
    GameObject.Destroy(go)
    res.free(assetinfo)
    self.extraObjCount = self.extraObjCount - 1
    go_cache.poolCnt = go_cache.poolCnt - 1
    if go_cache.usingCnt == 0 and go_cache.poolCnt == 0 then
        self.cache[assetinfo] = nil
        self.extraResCount = self.extraResCount - 1
    else
        go_cache.pool[go] = nil
    end
end

----- 调试相关
function Pool.dumpAll(print)
    print("======== Pool.dumpAll,,")
    for _, pool in pairs(Pool.all) do
        if not util.table_isempty(pool.cache) then
            pool:_dump(print)
        end
    end
end

function Pool:_dump(print)
    print("==== Pool=" .. self.name .. ",===  using=" .. self.usingResCount .. "/" .. self.usingObjCount .. ",extra=" .. self.extraResCount .. "/" .. self.extraObjCount)
    local sorted = {}
    local cnt = 0
    for ai, _ in pairs(self.cache) do
        cnt = cnt + 1
        sorted[cnt] = ai
    end
    table.sort(sorted, function(a, b)
        return a.assetpath < b.assetpath
    end)
    for i = 1, cnt do
        local ai = sorted[i]
        local aicache = self.cache[ai]
        if aicache.usingCnt > 0 then
            print("    + " .. ai.assetpath .. ",usingCnt=" .. aicache.usingCnt .. ",poolCnt=" .. aicache.poolCnt .. "=" .. util.table_len(aicache.pool) .. "/poolTouch=" .. aicache.poolTouch)
        end
    end
    for i = 1, cnt do
        local ai = sorted[i]
        local aicache = self.cache[ai]
        if aicache.usingCnt <= 0 then
            print("    - " .. ai.assetpath .. ",usingCnt=" .. aicache.usingCnt .. ",poolCnt=" .. aicache.poolCnt .. "=" .. util.table_len(aicache.pool) .. "/poolTouch=" .. aicache.poolTouch)
        end
    end
end

return Pool