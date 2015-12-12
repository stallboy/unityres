local setmetatable = setmetatable

local LoadFutureDummy = {}

function LoadFutureDummy:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function LoadFutureDummy:cancel()
end


local LoadFuture = {
    dummy = LoadFutureDummy:new()
}

function LoadFuture:new(callbackcache, path, cbid, extracache)
    local o = {}
    o.callbackcache = callbackcache
    o.path = path
    o.cbid = cbid
    o.extracache = extracache
    setmetatable(o, self)
    self.__index = self
    return o
end

function LoadFuture:cancel()
    self.callbackcache:cancel(self.path, self.cbid)
    if self.extracache then
        self.extracache:cancel(self.path, self.cbid)
    end
end

return LoadFuture
