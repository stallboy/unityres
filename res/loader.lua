local StateLoading = 1
local StateUsing = 2
local StateFree = 3

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

function Asset:_load(callback)
    self.assetinfo:load(function(asset, err)
        if self.wantfree then
            self.assetinfo:free()
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

function GameObj:_load(callback)
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

function Multi:_load(callback)
    for _, future in ipairs(self.futures) do
        future:_load(function(assetorgo, err)
            self.cnt = self.cnt + 1
            self.assetorgos[self.cnt] = assetorgo
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

function loader.loadAsset(assetinfo, callback)
    if assetinfo == nil then
        return
    end
    local future = Asset:new(assetinfo)
    future:_load(callback)
    return future
end

function loader.loadGameObject(pool, assetinfo, callback, attachment)
    if pool == nil or assetinfo == nil then
        return
    end
    local future = GameObj:new(pool, assetinfo, attachment)
    future:_load(callback)
    return future
end

function loader.multiloadAsset(assetinfos, callback)
    local futures = {}
    for _, assetinfo in ipairs(assetinfos) do
        table.insert(futures, Asset:new(assetinfo))
    end
    local multiGo = Multi:new(futures)
    multiGo:_load(callback)
    return multiGo
end

function loader.multiloadGameObject(pool_assetinfos, callback)
    local futures = {}
    for _, v in ipairs(pool_assetinfos) do
        table.insert(futures, GameObj:new(v.pool, v.assetinfo))
    end
    local multiGo = Multi:new(futures)
    multiGo:_load(callback)
    return multiGo
end

return loader
