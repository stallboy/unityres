local WWW = UnityEngine.WWW
local Yield = UnityEngine.Yield

local function table_len(a)
    local len = 0
    for _, _ in pairs(a) do
        len = len + 1
    end
    return len
end

local Container = {}

function Container:new()
    local o = {}
    o.resource2cbs = {} -- { path1: { callback1: 1, callback2: 1 }, path2: ... } }
    setmetatable(o, self)
    self.__index = self
    return o
end

function Container:cancel(path, cb)
    local cbs = self.resource2cbs[path]
    if cbs then
        cbs[cb] = nil
        if table_len(cbs) == 0 then
            self.resource2cbs[path] = nil
        end
    end
end

function Container:add(path, cbs)
    self.resource2cbs[path] = cbs
end

function Container:remove(path)
    local old = self.resource2cbs[path]
    self.resource2cbs[path] = nil
    return old
end

function Container:first()
    for path, _ in pairs(self.resource2cbs) do
        return path
    end
    return nil
end


local WWWFuture = {}

function WWWFuture:new(container, path, cb)
    local o = {}
    o.container = container
    o.path = path
    o.cb = cb
    setmetatable(o, self)
    self.__index = self
    return o
end

function WWWFuture:cancel()
    self.container:cancel(self.path, self.cb)
end


local WWWLoader = {}

function WWWLoader:new()
    local o = {}
    o.thread = 5
    o._runnings = Container:new()
    o._pendings = Container:new()

    setmetatable(o, self)
    self.__index = self
    return o
end

function WWWLoader:load(path, callback)
    local container = self._runnings
    local cbs = self._runnings.resource2cbs[path]
    if cbs then
        cbs[callback] = 1;
    elseif table_len(self._runnings.resource2cbs) < self.thread then
        self._runnings:add(path, { callback = 1 })
        self:__dowww(path)
    else
        container = self._pendings
        cbs = self._pendings.resource2cbs[path]
        if cbs then
            cbs[callback] = 1
        else
            self._pendings:add(path, { callback = 1 })
        end
    end

    return WWWFuture:new(container, path, callback)
end

function WWWLoader:__dowww(path)
    local co = coroutine.create(function()
        local www = WWW(path)
        Yield(www)
        self:__wwwdone(path, www)
        www:Dispose()
    end)
    coroutine.resume(co)
end

function WWWLoader:__wwwdone(path, www)
    local cbs = self._runnings.resource2cbs[path]
    for cb, _ in pairs(cbs) do
        cb(www)
    end

    self._runnings:remove(path)
    local pend = self._pendings:first()
    if pend then
        local pendcbs = self._pendings:remove(pend)
        self._runnings:add(pend, pendcbs)
        self:__dowww(pend)
    end
end


return WWWLoader