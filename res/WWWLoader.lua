local util = require "res.util"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"

local WWW = UnityEngine.WWW
local Yield = UnityEngine.Yield


local WWWLoader = {}

function WWWLoader:new()
    local o = {}
    o.thread = 5
    o._runnings = CallbackCache:new()
    o._pendings = CallbackCache:new()

    setmetatable(o, self)
    self.__index = self
    return o
end

function WWWLoader:load(path, callback)
    local callbackcache = self._runnings
    local cbs = self._runnings.resource2cbs[path]
    if cbs then
        cbs[callback] = 1;
    elseif util.table_len(self._runnings.resource2cbs) < self.thread then
        self._runnings:add(path, { callback = 1 })
        self:__dowww(path)
    else
        callbackcache = self._pendings
        cbs = self._pendings.resource2cbs[path]
        if cbs then
            cbs[callback] = 1
        else
            self._pendings:add(path, { callback = 1 })
        end
    end

    return LoadFuture:new(callbackcache, path, callback)
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
    if cbs then
        for cb, _ in pairs(cbs) do
            cb(www)
        end
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