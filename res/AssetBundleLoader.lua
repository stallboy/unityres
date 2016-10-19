local util = require "res.util"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"

local WWW = UnityEngine.WWW
local AssetBundle = UnityEngine.AssetBundle
local Yield = UnityEngine.Yield

local setmetatable = setmetatable
local pairs = pairs
local coroutine = coroutine
local table_len = util.table_len

local AssetBundleLoader = {}

--- unity 新版本好像可以用 AssetBundle.LoadFromFileAsync 来加载了。
function AssetBundleLoader:new(limit, usewww)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self

    instance.thread = limit
    instance.usewww = usewww
    instance._runnings = CallbackCache:new()
    instance._pendings = CallbackCache:new()
    return instance
end

function AssetBundleLoader:load(path, callback)
    local cbs = self._runnings.path2cbs[path]
    local id
    if cbs then
        id = self._runnings:addcallback(cbs, callback)
        return LoadFuture:new(self._runnings, path, id)
    elseif table_len(self._runnings.path2cbs) < self.thread then
        id = self._runnings:addpath(path, callback)
        self:__load(path)
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

function AssetBundleLoader:__load(path)
    local co = coroutine.create(function()
        if self.usewww then
            local www = WWW(path)
            Yield(www)
            self:__loaddone(path, www)
            www:Dispose()
        else
            local assetBundleCreateRequest = AssetBundle.LoadFromFileAsync(path)
            Yield(assetBundleCreateRequest)
            self:__loaddone(path, assetBundleCreateRequest)
        end
    end)
    coroutine.resume(co)
end

function AssetBundleLoader:__loaddone(path, wwwOrAssetBundleCreateRequest)
    local cbs = self._runnings:removepath(path)
    if cbs then
        for _, cb in pairs(cbs) do
            cb(wwwOrAssetBundleCreateRequest)
        end
    end

    local pendpath = self._pendings:first()
    if pendpath then
        local pendcbs = self._pendings:removepath(pendpath)
        self._runnings.path2cbs[pendpath] = pendcbs
        self:__load(pendpath)
    end
end

return AssetBundleLoader