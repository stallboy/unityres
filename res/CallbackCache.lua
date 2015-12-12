local util = require "res.util"

local setmetatable = setmetatable
local pairs = pairs


local CallbackCache = {
    __serial = 0
}

function CallbackCache:new()
    local o = {}
    o.path2cbs = {} -- { path1: { {cb1id: cb1, ...}, ...}
    setmetatable(o, self)
    self.__index = self
    return o
end

function CallbackCache:addcallback(cbs, callback)
    local id = self:nextid()
    cbs[id] = callback
    return id
end

function CallbackCache:addpath(path, callback)
    local id = self:nextid()
    local cbs = {}
    cbs[id] = callback
    self.path2cbs[path] = cbs
    return id
end

function CallbackCache:nextid()
    local id = CallbackCache.__serial + 1
    CallbackCache.__serial = id
    return id
end

function CallbackCache:removepath(path)
    local cbs = self.path2cbs[path]
    self.path2cbs[path] = nil
    return cbs
end

function CallbackCache:first()
    for path, _ in pairs(self.path2cbs) do
        return path
    end
    return nil
end

function CallbackCache:cancel(path, cbid)
    local cbs = self.path2cbs[path]
    if cbs then
        cbs[cbid] = nil
        if util.table_len(cbs) == 0 then
            self.path2cbs[path] = nil
        end
    end
end

return CallbackCache
