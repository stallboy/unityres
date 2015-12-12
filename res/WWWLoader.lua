local util = require "res.util"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"

local WWW = UnityEngine.WWW
local Yield = UnityEngine.Yield

local setmetatable = setmetatable
local pairs = pairs
local coroutine = coroutine
local assert = assert

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
    local cbs = self._runnings.path2cbs[path]
    local id
    if cbs then
        id = self._runnings:addcallback(cbs, callback)
        return LoadFuture:new(self._runnings, path, id)
    elseif util.table_len(self._runnings.path2cbs) < self.thread then
        id = self._runnings:addpath(path, callback)
        self:__dowww(path)
        return LoadFuture:new(self._runnings, path, id)
    else
        cbs = self._pendings.path2cbs[path]
        if cbs then
            id = self._pendings:addcallback(cbs, callback);
        else
            id = self._pendings:addpath(path, callback)
        end
        return LoadFuture:new(self._pendings, path, id, self._runnings)
    end
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
    local cbs = self._runnings:removepath(path)
    if cbs then
        for _, cb in pairs(cbs) do
            cb(www)
        end
    end

    local pendpath = self._pendings:first()
    if pendpath then
        local pendcbs = self._pendings:removepath(pendpath)
        self._runnings.path2cbs[pendpath] = pendcbs
        self:__dowww(pendpath)
    end
end

return WWWLoader