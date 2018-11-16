local StateLoading = 1
local StateUsing = 2
local StateFree = 3

local res = require "res.res"
--------------------------------------------------------
--- res之上是Pool，这2者之上是loader
--- 目的是模拟一个同步的机制
--- future = loader.makeXxx(assetinfo)
--- future:load(callback)
--- future:free() 这样如果callback没有调用就不会调了
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




local GameObj = {}

function GameObj:new(pool, assetinfo)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.pool = pool
    instance.assetinfo = assetinfo
    instance.go = nil
    instance.err = nil
    instance.state = StateLoading
    instance.wantfree = false
    return instance
end

function GameObj:free()
    self.wantfree = true
    if self.state == StateFree then
        return
    end

    if self.state == StateUsing then
        if self.go ~= nil then
            self.pool:free(self.assetinfo, self.go)
        end
        self.state = StateFree
    end
end

function GameObj:load(callback)
    self.pool:load(self.assetinfo, function(go, err)
        if self.wantfree then
            if go ~= nil then
                self.pool:free(self.assetinfo, go)
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




local loader = {}

loader.StateLoading = StateLoading
loader.StateUsing = StateUsing
loader.StateFree = StateFree


function loader.makeAsset(assetinfo)
    return Asset:new(assetinfo)
end

function loader.makeGameObj(pool, assetinfo)
    return GameObj:new(pool, assetinfo)
end

function loader.makeMulti(futures)
    return Multi:new(futures)
end

return loader
