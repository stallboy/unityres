local LoadFuture = {}

function LoadFuture:new(callbackcache, path, cb)
    local o = {}
    o.callbackcache = callbackcache
    o.path = path
    o.cb = cb
    setmetatable(o, self)
    self.__index = self
    return o
end

function LoadFuture:cancel()
    self.callbackcache:cancel(self.path, self.cb)
end

return LoadFuture