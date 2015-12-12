local WWWLoader = require "res.WWWLoader"
local Cache = require "res.Cache"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"
local util = require "res.util"

local AssetDatabase = UnityEngine.AssetDatabase
local Resources = UnityEngine.Resources
local Yield = UnityEngine.Yield

local assert = assert
local pairs = pairs
local ipairs = ipairs
local coroutine = coroutine


local res = {}

function res.init(editormode, abpath2assetinfo)
    if not editormode then
        assert(abpath2assetinfo, "need abpath2assetinfo when not in editor mode")
    end
    res.editormode = editormode
    res.abpath2assetinfo = abpath2assetinfo -- 用于依赖加载时查找是否需要cache
    res.wwwloader = WWWLoader:new()
    res.manifest = nil
    res._runnings = CallbackCache:new() -- assetinfo.assetpath 作为key
end

function res.load_manifest(assetinfo, callback)
    assert(callback, "need callback!")
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

--  assetinfo {assetpath: xx, abpath: xx, type: xx, location: xx, cache: xx}
--  type, location 参考util.assettype, util.assetlocation
--  约定所有assetinfo的asetpath不为nil，且assetinfo.csv以assetpath作为key，当type为asetbundle时assetpath==abpath

function res.load(assetinfo, callback)
    assert(callback, "need callback! if no callback, how to free")
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
            callback("LoadAssetAtPath return nil", nil)
        end
        return LoadFuture.dummy
    end

    -- 正在加载了，等着就行
    local cbs = res._runnings.path2cbs[assetpath]
    if cbs then
        local id = res._runnings:addcallback(cbs, callback)
        return LoadFuture:new(res._runnings, assetpath, id)
    end

    -- 加载Resources目录下的asset，不用分析依赖的； 或加载有依赖的asetbundle里的
    local id = res._runnings:addpath(assetpath, callback)
    res.__load_asset_withcache(assetinfo, function(err, asset)
        local cbs = res._runnings:removepath(assetpath)
        if cbs then
            for _, cb in pairs(cbs) do
                if err == nil then
                    cache:_newloaded(assetpath, asset, assetinfo.type)
                end
                cb(err, asset) --可能cb里把这个asset给free了，但没关系，有cache基本保证了asset肯定还在。
            end
        end
    end)
    return LoadFuture:new(res._runnings, assetpath, id)
end

function res.__load_asset_withcache(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    local abpath = assetinfo.abpath
    if assetinfo.location == util.assetlocation.resources then
        assert(not assetinfo.type == util.assettype.assetbundle, "do not put assetbundle in Resources: " .. assetpath)
        assert(abpath == nil or #abpath == 0, "do not set abpath when type not assetbundle: " .. assetpath)
        res.__load_asset_at_res(assetpath, callback)
    else
        assert(res.manifest, "manifest not load")
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
            callback("internal err, should not happen", nil)
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
            callback(nil, www.assetBundle)
        else
            callback(www.error, nil)
        end
    end)
end

function res.__load_asset_at_ab(assetpath, ab, callback)
    local co = coroutine.create(function()
        local req = ab:LoadAssetAsync(assetpath)
        Yield(req)
        callback(nil, req.asset) -- ab not unload
    end)
    coroutine.resume(co)
end

function res.__load_asset_at_res(assetpath, callback)
    local co = coroutine.create(function()
        local req = Resources.LoadAsync(assetpath)
        Yield(req)
        callback(nil, req.asset)
    end)
    coroutine.resume(co)
end

return res