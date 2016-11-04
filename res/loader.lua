local StateLoading = 1
local StateUsing = 2
local StateFree = 3

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

function GameObj:_load(callback)
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



local loader = {}
loader.StateLoading = StateLoading
loader.StateUsing = StateUsing
loader.StateFree = StateFree

function loader.loadAsset(assetinfo, callback)
    local asset = Asset:new(assetinfo)
    asset:_load(callback)
    return asset
end

function loader.loadGameObject(pool, assetinfo, callback)
    local gameobj = GameObj:new(pool, assetinfo)
    gameobj:_load(callback)
    return gameobj
end

return loader
