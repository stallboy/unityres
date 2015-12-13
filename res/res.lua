local WWWLoader = require "res.WWWLoader"
local Cache = require "res.Cache"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"
local util = require "res.util"

local AssetDatabase = UnityEngine.AssetDatabase
local Resources = UnityEngine.Resources
local Yield = UnityEngine.Yield

local pairs = pairs
local ipairs = ipairs
local coroutine = coroutine
local error = error


local res = {}

function res.initialize(wwwlimit, editormode, abpath2assetinfo, errorlog)
    res.wwwloader = WWWLoader:new(wwwlimit)
    res.editormode = editormode
    res.abpath2assetinfo = abpath2assetinfo -- 用于依赖加载时查找是否需要cache
    res.errorlog = errorlog or error
    res._runnings = CallbackCache:new() -- assetinfo.assetpath 作为key
    res.manifest = nil
end

function res.load_manifest(assetinfo, callback)
    res.__assert(callback, "need callback")
    res.__load_ab_asset(assetinfo.assetpath, assetinfo.abpath, function(err, manifest, ab)
        res.manifest = manifest
        if ab then
            ab:Unload(false)
        end
        callback(err, manifest)
    end)
end

function res.free(assetinfo)
    assetinfo.cache:_free(assetinfo.assetpath)
end

function res.load(assetinfo, callback)
    res.__assert(callback, "need callback")
    local assetpath = assetinfo.assetpath
    local cache = assetinfo.cache

    -- 在cache里
    local cachedasset = cache:_load(assetpath)
    if cachedasset then
        callback(nil, cachedasset)
        return LoadFuture.dummy
    end

    -- 同步加载模式，只用于测试吧
    if res.editormode then
        local asset = AssetDatabase.LoadAssetAtPath(assetpath)
        if asset then
            cache:_newloaded(assetpath, asset, assetinfo.type)
            callback(nil, asset)
        else
            local err = "AssetDatabase has no asset " .. assetpath
            res.errorlog(err)
            callback(err, nil)
        end
        return LoadFuture.dummy
    end

    -- 正在加载了，等着就行
    local cbs = res._runnings.path2cbs[assetpath]
    if cbs then
        local id = res._runnings:addcallback(cbs, callback)
        return LoadFuture:new(res._runnings, assetpath, id)
    end

    -- 加载
    local id = res._runnings:addpath(assetpath, callback)
    res.__load_asset_withcache(assetinfo, function(err, asset)
        local cbs = res._runnings:removepath(assetpath)
        if cbs then
            for _, cb in pairs(cbs) do
                if err == nil then
                    cache:_newloaded(assetpath, asset, assetinfo.type)
                end
                cb(err, asset)
            end
        end
    end)
    return LoadFuture:new(res._runnings, assetpath, id)
end

function res.__load_asset_withcache(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    local abpath = assetinfo.abpath
    if assetinfo.location == util.assetlocation.resources then
        res.__assert(not assetinfo.type == util.assettype.assetbundle, "do not put assetbundle in Resources: " .. assetpath)
        res.__assert(abpath == nil or #abpath == 0, "do not set abpath when type not assetbundle: " .. assetpath)
        res.__load_asset_at_res(assetpath, callback)
    else
        res.__assert(res.manifest, "manifest not load")
        local deps = res.manifest:GetAllDependencies(abpath)
        res.__load_ab_deps_withcache(abpath, deps, function(abs)
            local ab = abs[abpath]
            if ab == nil then
                callback("load bundle error " .. abpath, nil)
                res.__free_multi_ab_withcache(abs)
            elseif assetinfo.type == util.assettype.assetbundle then
                callback(nil, ab)
                res.__free_multi_ab_withcache(abs)
            else
                res.__load_asset_at_ab(assetpath, ab, function(err, asset)
                    callback(err, asset)
                    res.__free_multi_ab_withcache(abs)
                end)
            end
        end)
    end
end

function res.__free_multi_ab_withcache(abs)
    for abpath, ab in pairs(abs) do
        local assetinfo = res.abpath2assetinfo[abpath]
        if assetinfo then
            res.free(assetinfo)
        else
            ab:Unload(false)
        end
    end
end

function res.__load_ab_deps_withcache(abpath, deps, callback)
    local abpaths = {}
    for _, dep in ipairs(deps) do
        table.insert(abpaths, dep)
    end
    table.insert(abpaths, abpath)
    res.__load_multi_ab_withcache(abpaths, callback)
end

function res.__load_multi_ab_withcache(abpaths, callback)
    local reqcnt = #abpaths
    local abs = {}
    local cnt = 0
    for _, abpath in ipairs(abpaths) do
        res.__load_ab_withcache(abpath, function(_, ab)
            cnt = cnt + 1
            abs[abpath] = ab
            if cnt == reqcnt then
                callback(abs)
            end
        end)
    end
end

function res.__load_ab_withcache(abpath, callback)
    local abcache = Cache.bundle2cache[abpath]
    if abcache then
        local cachedab = abcache:_load(abpath)
        if cachedab then
            callback(nil, cachedab)
        else
            local err = "internal err, cache has no assetBundle " .. abpath
            res.errorlog(err)
            callback(err, nil)
        end
    else
        local assetinfo = res.abpath2assetinfo[abpath]
        res.__load_ab(abpath, function(err, ab)
            if err == nil and assetinfo then
                assetinfo.cache:_newloaded(abpath, ab, assetinfo.type)
            end
            callback(err, ab)
        end)
    end
end

function res.__load_ab_asset(assetpath, abpath, callback)
    res.__load_ab(abpath, function(err, ab)
        if err == nil then
            res._load_asset_at_ab(assetpath, ab, function(err, asset)
                callback(err, asset, ab)
            end)
        else
            callback(err, nil, ab)
        end
    end)
end

function res.__load_ab(abpath, callback)
    res.wwwloader:load(abpath, function(www)
        if www.error == nil then
            local ab = www.assetBundle
            if ab then
                callback(nil, ab)
            else
                local err = "www has no assetBundle " .. abpath
                res.errorlog(err)
                callback(err, nil)
            end
        else
            callback(www.error, nil)
        end
    end)
end

function res.__load_asset_at_ab(assetpath, ab, callback)
    local co = coroutine.create(function()
        local req = ab:LoadAssetAsync(assetpath)
        Yield(req)
        if req.asset then
            callback(nil, req.asset) -- ab not unload
        else
            local err = "assetBundle has no asset " .. assetpath
            res.errorlog(err)
            callback(err, nil)
        end
    end)
    coroutine.resume(co)
end

function res.__load_asset_at_res(assetpath, callback)
    local co = coroutine.create(function()
        local req = Resources.LoadAsync(assetpath)
        Yield(req)
        if req.asset then
            callback(nil, req.asset)
        else
            local err = "Resources has no asset " .. assetpath
            res.errorlog(err)
            callback(err, nil)
        end
    end)
    coroutine.resume(co)
end

function res.__assert(v, message)
    if not v then
        res.errorlog(message)
    end
end

return res