local WWWLoader = require "res.WWWLoader"
local Cache = require "res.Cache"
local CallbackCache = require "res.CallbackCache"
local util = require "res.util"

local Resources = UnityEngine.Resources
local Yield = UnityEngine.Yield

local pairs = pairs
local ipairs = ipairs
local coroutine = coroutine


local GetResPath
local EditorLoadAssetAtPath

local res = { assettype = util.assettype, assetlocation = util.assetlocation }

function res.initialize(cfg, option, callback)
    res.cfg = cfg
    res.useEditorLoad = option.useEditorLoad
    if option.errorlog then
        util.errorlog = option.errorlog
    end
    if option.debuglog then
        util.debuglog = option.debuglog
    end
    util.assert(callback, "need callback")
    res.wwwloader = WWWLoader:new(option.wwwlimit or 5)
    GetResPath = option.GetResPath
    EditorLoadAssetAtPath = option.EditorLoadAssetAtPath

    for _, policy in pairs(cfg.assetcachepolicy.all) do
        policy.cache = Cache:new(policy.lruSize)
    end
    res.dependencyBundleCache = Cache:new(1)  -- make bundle has cache

    for _, assetinfo in pairs(cfg.assets.all) do
        if assetinfo.location == util.assetlocation.resources then
            local assetpath = assetinfo.assetpath
            local abpath = assetinfo.abpath
            util.assert(assetinfo.type ~= util.assettype.assetbundle, "DO NOT put assetbundle in Resources: " ..assetpath )
            util.assert(abpath == nil or #abpath == 0, "DO NOT set abpath when locate in Resources: " .. assetpath)
        end
        if assetinfo.type ~= util.assettype.assetbundle then
            assetinfo.assetpath = "assets/" .. assetinfo.assetpath -- make LoadAssetAsync easy
        end
        assetinfo.cache = assetinfo.RefCachepolicy.cache
    end

    res._runnings = CallbackCache:new() -- assetinfo.assetpath 作为key
    res.manifest = nil

    if res.useEditorLoad then
        callback()
    else
        local abpath = option.manifest or "manifest"
        local assetpath = "assetbundlemanifest"
        res.__load_ab(abpath, function(ab, aberr)
            res.__load_asset_at_ab(assetpath, ab, abpath, function(asset, asseterr)
                res.manifest = asset
                if ab then
                    ab:Unload(false)
                end
                callback(asseterr or aberr)
            end)
        end)
    end
end

function res.__load_ab(abpath, callback)
    util.debuglog("    WWW assetBundle "..abpath)
    res.wwwloader:load(GetResPath(abpath), function(www)
        if www.error == nil then
            local ab = www.assetBundle
            if ab then
                callback(ab)
            else
                local err = "www not assetBundle " .. abpath
                util.errorlog(err)
                callback(nil, err)
            end
        else
            local err = "www load " .. abpath .. ", err "..www.error
            util.errorlog(err)
            callback(nil, err)
        end
    end)
end

function res.__load_asset_at_ab(assetpath, ab, abpath, callback)
    if ab == nil then
        callback(nil, nil)
        return
    end

    local co = coroutine.create(function()
        util.debuglog("    AssetBundle.LoadAssetAsync " .. assetpath .. " from "..abpath)
        local req = ab:LoadAssetAsync(assetpath)
        Yield(req)
        if req.asset then
            callback(req.asset) -- ab not unload
        else
            local err = "assetBundle "..abpath.." include "
            for _, include in ipairs(ab:GetAllAssetNames().Table) do
                err = err .. include .. ","
            end
            err = err .. " LoadAssetAsync err "..assetpath
            util.errorlog(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end



function res.load(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    util.assert(callback, "load "..assetpath.." callback nil")
    util.debuglog("res.load " .. assetpath)
    if res.useEditorLoad then
        local cachedasset = assetinfo.cache:_get(assetpath)
        if cachedasset then
            callback(cachedasset.asset, cachedasset.err)
        else
            util.debuglog("    EditorLoadAssetAtPath " .. assetpath)
            local asset = EditorLoadAssetAtPath(assetpath)
            if asset then
                assetinfo.cache:_put(assetpath, asset, nil, assetinfo.type, 1)
                callback(asset)
            else
                local err = "AssetDatabase has no asset " .. assetpath
                util.errorlog(err)
                assetinfo.cache:_put(assetpath, asset, err, assetinfo.type, 1)
                callback(nil, err)
            end
        end
        return
    end

    if (assetinfo.type ~= util.assettype.assetbundle) then
        res.__load_asset_withcache(assetinfo, callback)
    else
        res.__load_ab_withdependency_withcache(assetpath, callback)
    end
end

function res.__load_asset_withcache(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    local abpath = assetinfo.abpath
    local cache = assetinfo.cache
    local cachedasset = cache:_get(assetpath)
    if cachedasset then
        callback(cachedasset.asset, cachedasset.err)
        return
    end

    if assetinfo.location == util.assetlocation.resources then
        res.__load_withcache(assetpath, assetinfo.type, cache, res.__load_asset_at_res, callback)
        return
    end

    res.__load_ab_withdependency_withcache(abpath, function(ab, aberr)
        local loadfunction = function(assetp, callb)
            res.__load_asset_at_ab(assetp, ab, abpath, callb)
        end
        res.__load_withcache(assetpath, assetinfo.type, cache, loadfunction, function(asset, asseterr)
            callback(asset, asseterr or aberr)
            res.__free_ab_withdependency(abpath)
        end)
    end)
end

function res.__load_ab_withdependency_withcache(abpath, callback)
    local abpaths = res.__get_dependences(abpath)
    local reqcnt = #abpaths
    local cnt = 0
    local abresult = {}
    for _, abp in ipairs(abpaths) do
        res.__load_ab_withcache(abp, function(ab, err)
            abresult[abp] = ab
            cnt = cnt + 1
            if cnt == reqcnt then
                callback(abresult[abpath], err)
            end
        end)
    end
end

function res.__load_ab_withcache(abpath, callback)
    local cache = res.__get_cache(abpath)
    local cachedab = cache:_get(abpath)
    if cachedab then
        callback(cachedab.asset, cachedab.err)
        return
    end

    res.__load_withcache(abpath, util.assettype.assetbundle, cache, res.__load_ab, callback)
end


function res.__load_withcache(assetpath, assettype, cache, loadfunction, callback)
    local cbs = res._runnings.path2cbs[assetpath]
    if cbs then
        res._runnings:addcallback(cbs, callback)
    else
        res._runnings:addpath(assetpath, callback)
        loadfunction(assetpath, function(asset, err)
            local cbs = res._runnings:removepath(assetpath)
            local count = util.table_len(cbs)
            cache:_put(assetpath, asset, err, assettype, count)
            for _, cb in pairs(cbs) do
                cb(asset, err)
            end
        end)
    end
end

function res.__load_asset_at_res(assetpath, callback)
    local co = coroutine.create(function()
        util.debuglog("    Resources.LoadAsync " .. assetpath)
        local req = Resources.LoadAsync(assetpath)
        Yield(req)
        if req.asset then
            callback(req.asset)
        else
            local err = "Resources has no asset " .. assetpath
            util.errorlog(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end


function res.free(assetinfo)
    util.debuglog("res.free "..assetinfo.assetpath)
    if res.useEditorLoad or assetinfo.type ~= util.assettype.assetbundle then
        assetinfo.cache:_free(assetinfo.assetpath)
    else
        res.__free_ab_withdependency(assetinfo.assetpath)
    end
end

function res.__free_ab_withdependency(abpath)
    local abpaths = res.__get_dependences(abpath)
    for _, abp in ipairs(abpaths) do
        local cache = res.__get_cache(abp)
        cache:_free(abp)
    end
end

function res.loadmulti(assetinfos, callback)
    local result = {}
    local len = #assetinfos
    local loadedcnt = 0
    for index, assetinfo in ipairs(assetinfos) do
        res.load(assetinfo, function(asset, err)
            result[index] = { asset = asset, err = err  }
            loadedcnt = loadedcnt + 1
            if loadedcnt == len then
                callback(result)
            end
        end)
    end
end

function res.__get_dependences(abpath)
    util.assert(res.manifest, "manifest nil")
    local deps = res.manifest:GetAllDependencies(abpath)
    local abpaths = {}
    for _, dep in ipairs(deps.Table) do
        table.insert(abpaths, dep)
    end
    table.insert(abpaths, abpath)
    return abpaths
end

function res.__get_cache(abpath)
    local assetinfo = res.cfg.assets.all[abpath]
    if assetinfo then
        return assetinfo.cache
    else
        return res.dependencyBundleCache
    end
end

return res