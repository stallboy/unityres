local util = require "res.util"

local CallbackCache = {}

function CallbackCache:new()
    local o = {}
    o.resource2cbs = {} -- { path1: { callback1: 1, callback2: 1 }, path2: ... } }
    setmetatable(o, self)
    self.__index = self
    return o
end

function CallbackCache:cancel(path, cb)
    local cbs = self.resource2cbs[path]
    if cbs then
        cbs[cb] = nil
        if util.table_len(cbs) == 0 then
            self.resource2cbs[path] = nil
        end
    end
end

function CallbackCache:add(path, cbs)
    self.resource2cbs[path] = cbs
end

function CallbackCache:remove(path)
    local old = self.resource2cbs[path]
    self.resource2cbs[path] = nil
    return old
end

function CallbackCache:first()
    for path, _ in pairs(self.resource2cbs) do
        return path
    end
    return nil
end

return CallbackCache
