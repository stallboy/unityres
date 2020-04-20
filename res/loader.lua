local res = require "res.res"
local util = require "res.util"
local LocalizationMgr = require "res.LocalizationMgr"
local StateLoading = 1
local StateUsing = 2
local StateFree = 3
--------------------------------------------------------
--- res之上是Pool，这2者之上是loader
--- 目的是模拟一个同步的机制
--- future = loader.makeXxx(assetinfo)
--- future:load(callback)
--- future:free() 这样如果callback没有调用就不会调了
--- 应用主要就使用这个api

--------------------------------------------------------
--- 资源加载
local Asset = {}

function Asset:new(assetinfo)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    local lanAssetInfo = LocalizationMgr.GetMultiLanguageAssetinfo(assetinfo)
    if lanAssetInfo then
        assetinfo = lanAssetInfo
    end
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
        res.free(self.assetinfo)
        self.asset = nil
        self.err = "free"
        self.state = StateFree
    end
end

local function AssetLoadDone(asset, err, self, callback, ...)
    if self.wantfree then
        res.free(self.assetinfo)
        self.state = StateFree
        return
    end

    self.state = StateUsing
    self.asset = asset
    self.err = err
    if callback then
        callback(asset, err, ...)
    end
end

function Asset:load(callback, ...)
    res.load(self.assetinfo, AssetLoadDone, self, callback, ...)
end

function Asset:res()
    return self.asset, self.err
end

function Asset:getState()
    return self.state
end

function Asset:equals(other)
    return other and other.__index == Asset and
            (other.assetinfo == self.assetinfo or
                    (other.assetinfo and self.assetinfo and other.assetinfo.assetid == self.assetinfo.assetid)) --- netres
end



--------------------------------------------------------
--- 场景对象加载
local GameObj = {}

function GameObj:new(pool, assetinfo)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self

    local lanAssetInfo = LocalizationMgr.GetMultiLanguageAssetinfo(assetinfo)
    if lanAssetInfo then
        assetinfo = lanAssetInfo
    end
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
            self.go = nil
            self.err = "free"
        end
        self.state = StateFree
    end
end

local function GameObjLoadDone(go, err, self, callback, ...)
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
    if callback then
        callback(go, err, ...)
    end
end

function GameObj:load(callback, ...)
    self.pool:load(self.assetinfo, GameObjLoadDone, self, callback, ...)
end

function GameObj:res()
    return self.go, self.err
end

function GameObj:getState()
    return self.state
end

function GameObj:equals(other)
    return other and other.__index == GameObj and other.pool == self.pool and other.assetinfo == self.assetinfo
end


--------------------------------------------------------
--- 多个资源或场景对象加载,这里假设2个，是想避免alloc table
local Multi = {}

function Multi:new(future1, future2)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.future1 = future1
    instance.future2 = future2
    instance.allcnt = 2
    instance.state = StateLoading

    instance.res1 = nil
    instance.res2 = nil
    instance.cnt = 0
    instance.errcnt = 0
    instance.err = nil
    return instance
end

local function MultiLoadDone(assetorgo, err, self, callback, ...)
    self.cnt = self.cnt + 1
    if assetorgo == nil then
        self.errcnt = self.errcnt + 1
        self.err = err
    end
    if self.cnt == self.allcnt then
        self.state = StateUsing
        callback(self, self.err, ...)
    end
end

function Multi:load(callback, ...)
    self.future1:load(MultiLoadDone, self, callback, ...)
    self.future2:load(MultiLoadDone, self, callback, ...)
end

function Multi:free()
    self.state = StateFree
    self.future1:free()
    self.future2:free()
end

function Multi:res()
    return self, self.err
end

function Multi:getState()
    return self.state
end

function Multi:equals(_)
    return false
end

--------------------------------------------------------
--- 访问接口
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

function loader.makeMulti(future1, future2)
    return Multi:new(future1, future2)
end

function loader.makeNetAsset(url, type)
    local netassertinfo = util.make_net_assetinfo(url, type)
    return Asset:new(netassertinfo)
end

return loader
