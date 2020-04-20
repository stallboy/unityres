local Cache = require "res.Cache"
local util = require "res.util"
local Pool = require "res.Pool"
local SingltonPool = require "res.SingltonPool"
local MultiPool = require "res.MultiPool"

local Timer = require "common.Timer"
local SimpleEvent = require "common.SimpleEvent"
local res = require "res.res"

local ipairs = ipairs
local unpack = unpack

local resmgr = {}
resmgr.cachePolicyType = 0

function resmgr.dump()
    --ResUpdater.ResDumper.Dump()
    util.dump(Pool, Cache)
    util.dump(Timer)
    util.dump(SimpleEvent)
end

local function purge(Cls)
    for _, cache in ipairs(Cls.all) do
        cache:_purge()
    end
end

function resmgr.setCacheFactor(cacheFactor)
    if res.cacheFactor == cacheFactor then
        return
    end

    res.cacheFactor = cacheFactor
    purge(SingltonPool)
    purge(MultiPool)
    purge(Pool)
    purge(Cache)
end

function resmgr.setCachePolicyParam(cacheOrPool, ...)
    cacheOrPool._cachePolicyParams = { ... }
end

local function setPolicy(Cls)
    for _, cache in ipairs(Cls.all) do
        if cache._cachePolicyParams then
            local param = cache._cachePolicyParams[resmgr.cachePolicyType]
            if param then
                cache:setCachePolicy(unpack(param))
                cache:_purge()
            end
        end
    end
end

function resmgr.chooseCachePolicy(type)
    if resmgr.cachePolicyType == type then
        return
    end
    resmgr.cachePolicyType = type
    setPolicy(SingltonPool)
    setPolicy(MultiPool)
    setPolicy(Pool)
    setPolicy(Cache)
end

function resmgr.purgeOnly(cacheFactor)
    local oldCacheFactor = res.cacheFactor
    resmgr.setCacheFactor(cacheFactor)
    res.cacheFactor = oldCacheFactor
end

return resmgr