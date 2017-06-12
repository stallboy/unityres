local StateLoading = 1
local StateUsing = 2
local StateFree = 3

local res = require "res.res"
--------------------------------------------------------
--- res之上是Pool，这2者之上是loader
--- 目的是模拟一个同步的机制
--- future = loader.loadXxx(assetinfo, callback)
--- 可以future:free 这样如果callback没有调用就不会调了
--- 应用主要就使用这个api

local Asset = {}

function Asset:new(assetinfo)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.assetinfo = assetinfo
    instance.asset = nil
    instance.err = nil
    instance.state = StateLoading
    instance.wantfree = false
    return instance
end

function Asset:free()
    self.wantfree = true
    if self.state == StateFree then
        return
    end
    if self.state == StateUsing then
        self.assetinfo:free()
        self.state = StateFree
    end
end

function Asset:load(callback)
    res.load(self.assetinfo, function(asset, err)
        if self.wantfree then
            res.free(self.assetinfo)
            self.state = StateFree
            return
        end

        self.state = StateUsing
        self.asset = asset
        self.err = err
        callback(asset, err, self)
    end)
end

function Asset:equals(other)
    return other and other.__index == Asset and other.assetinfo == self.assetinfo
end

local GameObj = {}

function GameObj:new(pool, assetinfo, attachment)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.pool = pool
    instance.assetinfo = assetinfo
    instance.go = nil
    instance.err = nil
    instance.state = StateLoading
    instance.wantfree = false
    instance.attachment = attachment
    return instance
end

function GameObj:free()
    self.wantfree = true
    if self.state == StateFree then
        return
    end

    if self.state == StateUsing then
        if self.go ~= nil then
            self.pool:free(self.assetinfo, self.go, self.attachment)
        end
        self.state = StateFree
    end
end

function GameObj:load(callback)
    self.pool:load(self.assetinfo, function(go, err)
        if self.wantfree then
            if go ~= nil then
                self.pool:free(self.assetinfo, go, self.attachment)
            end
            self.state = StateFree
            return
        end

        self.state = StateUsing
        self.go = go
        self.err = err
        callback(go, err, self)
    end)
end

function GameObj:equals(other)
    return other and other.__index == GameObj and other.assetinfo == self.assetinfo
end


local Multi = {}

function Multi:new(futures)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.futures = futures
    instance.state = StateLoading

    instance.allcnt = #futures
    instance.assetorgos = {}
    instance.cnt = 0
    instance.errcnt = 0
    return instance
end

function Multi:load(callback)
    if self.allcnt == 0 then
        self.state = StateUsing
        callback(self.assetorgos, self.errcnt, self)
        return
    end

    for idx, future in ipairs(self.futures) do
        future:load(function(assetorgo, err)
            self.cnt = self.cnt + 1
            self.assetorgos[idx] = assetorgo
            if err then
                self.errcnt = self.errcnt + 1
            end
            if self.cnt == self.allcnt then
                self.state = StateUsing
                callback(self.assetorgos, self.errcnt, self)
            end
        end)
    end
end

function Multi:free()
    self.state = StateFree
    for _, future in ipairs(self.futures) do
        future:free()
    end
end

function Multi:equals(_)
    return false
end

local loader = {}

loader.StateLoading = StateLoading
loader.StateUsing = StateUsing
loader.StateFree = StateFree

function loader.loadAsset(assetinfo, callback)
    local future = Asset:new(assetinfo)
    future:load(callback)
    return future
end

function loader.loadGameObject(pool, assetinfo, callback, attachment)
    local future = GameObj:new(pool, assetinfo, attachment)
    future:load(callback)
    return future
end

function loader.multiloadAsset(assetinfos, callback)
    local futures = {}
    for _, assetinfo in ipairs(assetinfos) do
        table.insert(futures, Asset:new(assetinfo))
    end
    local multiGo = Multi:new(futures)
    multiGo:load(callback)
    return multiGo
end

function loader.multiloadGameObject(pool_assetinfos, callback)
    local futures = {}
    for _, v in ipairs(pool_assetinfos) do
        table.insert(futures, GameObj:new(v.pool, v.assetinfo))
    end
    local multiGo = Multi:new(futures)
    multiGo:load(callback)
    return multiGo
end

function loader.multiloadMixed(goargs, assetargs, callback)
    local mixed = loader.makeMulti(goargs, assetargs)
    mixed:load(callback)
    return mixed
end

function loader.makeAsset(assetinfo)
    return Asset:new(assetinfo)
end

function loader.makeGameObj(pool, assetinfo, attachment)
    return GameObj:new(pool, assetinfo, attachment)
end

function loader.makeMulti(goargs, assetargs)
    --    混 合 加 载 gameobject 和 asset ， 例 如 加 载 人 物 部 件 模 型 ， 同 时 加 载 3 S 材 质
    --    示 例 ：
    --    local loadargs = {
    --        { isGameObject = true, pool = module.pool.attachment, assetinfo = assetinfo, callback = callback, },
    --        { isAsset = true, assetinfo = assetinfo, },
    --    }
    local futures = {}
    for _, arg in pairs(goargs) do
        table.insert(futures, GameObj:new(arg.pool, arg.assetinfo, arg.attachment))
    end
    for _, arg in pairs(assetargs) do
        table.insert(futures, Asset:new(arg.assetinfo))
    end
    return Multi:new(futures)
end

return loader
