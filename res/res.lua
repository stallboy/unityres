local AssetBundleLoader = require "res.AssetBundleLoader"
local Cache = require "res.Cache"
local CallbackCache = require "res.CallbackCache"
local util = require "res.util"
local logger = require "common.Logger"

local Resources = UnityEngine.Resources
local Application = UnityEngine.Application
local Yield = UnityEngine.Yield

local pairs = pairs
local ipairs = ipairs
local coroutine = coroutine


local GetResPath = ResUpdater.Res.GetResPath
local EditorLoadSpriteAtPath = ResUpdater.Res.EditorLoadSpriteAtPath
local EditorLoadAssetAtPath = ResUpdater.Res.EditorLoadAssetAtPath
local cfgs
local dependencyBundleCache

local res = {}

function res.initialize(cfg, assetbundleLoaderLimit, callback)
    cfgs = cfg
    res.useEditorLoad = UnityEngine.Application.isEditor and not ResUpdater.Res.useAssetBundleInEditor

    local version = tonumber(string.sub(Application.unityVersion, 1, 3))
    local usewww = version < 5.4
    res.assetBundleLoader = AssetBundleLoader:new(assetbundleLoaderLimit or 5, usewww)

    for _, policy in pairs(cfg.assetcachepolicy.all) do
        policy.cache = Cache:new(policy.name, policy.lruSize)
    end
    dependencyBundleCache = Cache:new("dependencyBundle", 0) -- make bundle has cache

    for _, assetinfo in pairs(cfg.assets.all) do
        if assetinfo.type ~= util.assettype.assetbundle then
            assetinfo._assetpath_withassetsprefix = "assets/" .. assetinfo.assetpath -- make LoadAssetAsync easy
        end
        assetinfo.cache = assetinfo.RefCachepolicy.cache
    end

    res._runnings = CallbackCache:new() -- assetinfo.assetpath 作为key
    res.manifest = nil

    if res.useEditorLoad then
        callback()
    else
        local abpath = "manifest"
        local assetpath = "assetbundlemanifest"
        res.__load_ab(abpath, function(ab, aberr)
            res.__load_asset_at_ab(assetpath, ab, abpath, util.assettype.asset, function(asset, asseterr)
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
    logger.Res("    AssetBundleLoader {0}", abpath)
    res.assetBundleLoader:load(GetResPath(abpath), function(wwwOrAssetBundleCreateRequest)
        local error
        if res.assetBundleLoader.usewww then
            error = wwwOrAssetBundleCreateRequest.error
        end

        if error == nil then
            local ab = wwwOrAssetBundleCreateRequest.assetBundle
            if ab then
                callback(ab)
            else
                local err = "wwwOrAssetBundleCreateRequest not assetBundle " .. abpath
                logger.Error(err)
                callback(nil, err)
            end
        else
            local err = "wwww load " .. abpath .. ", err " .. error
            logger.Error(err)
            callback(nil, err)
        end
    end)
end

function res.__load_asset_at_ab(assetpath, ab, abpath, assettype, callback)
    if ab == nil then
        callback(nil, nil)
        return
    end

    local co = coroutine.create(function()
        logger.Res("    AssetBundle.LoadAssetAsync {0} from {1}", assetpath, abpath)
        local req
        if assettype ~= util.assettype.sprite then
            req = ab:LoadAssetAsync(assetpath)
        else
            req = ab:LoadAssetAsync(assetpath, "UnityEngine.Sprite")
        end
        Yield(req)
        if req.asset then
            callback(req.asset) -- ab not unload
        else
            local err = "assetBundle " .. abpath .. " include "
            for _, include in ipairs(ab:GetAllAssetNames().Table) do
                err = err .. include .. ","
            end
            err = err .. " LoadAssetAsync err " .. assetpath
            logger.Error(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end


function res.__load_asset_at_res(assetpath, callback)
    local co = coroutine.create(function()
        logger.Res("    Resources.LoadAsync {0}", assetpath)
        local req = Resources.LoadAsync(assetpath)
        Yield(req)
        if req.asset then
            callback(req.asset)
        else
            local err = "Resources has no asset " .. assetpath
            logger.Error(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end

--- 就算load 失败，回调callback(nil)，也会增加引用计数，
function res.load(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    if logger.IsRes() then
        logger.Res("++++load {0}", assetpath)
    end

    if res.useEditorLoad then
        local cachedasset = assetinfo.cache:_get(assetpath)
        if cachedasset then
            callback(cachedasset.asset, cachedasset.err)
        else
            logger.Res("    EditorLoadAssetAtPath {0}", assetpath)
            local loadfunc = EditorLoadAssetAtPath
            if assetinfo.type == util.assettype.sprite then
                loadfunc = EditorLoadSpriteAtPath
            end
            local asset = loadfunc(assetinfo._assetpath_withassetsprefix)
            if asset then
                assetinfo.cache:_put(assetpath, asset, nil, assetinfo.type, 1)
                callback(asset)
            else
                local err = "AssetDatabase has no asset " .. assetpath
                logger.Error(err)
                assetinfo.cache:_put(assetpath, asset, err, assetinfo.type, 1)
                callback(nil, err)
            end
        end
    else
        if assetinfo.location == util.assetlocation.resources then
            res.__load_withcache(assetinfo.assetpath, assetinfo.type, res.__load_asset_at_res, callback)
        elseif assetinfo.type == util.assettype.assetbundle then
            res.__load_ab_withdependency_withcache(assetpath, callback)
        else
            --- 这里要让 asset 依赖的 assetbundle 都 refcnt +1，所以得从头开始加
            res.__load_ab_withdependency_withcache(assetinfo.abpath, function(ab, aberr)
                res.__load_withcache(assetinfo.assetpath, assetinfo.type, function(_, callb)
                    res.__load_asset_at_ab(assetinfo._assetpath_withassetsprefix, ab, assetinfo.abpath, assetinfo.type, callb)
                end, function(asset, asseterr)
                    callback(asset, asseterr or aberr)
                end)
            end)
        end
    end
end

function res.__load_ab_withdependency_withcache(abpath, callback)
    local abpaths = res.__get_dependences(abpath)
    local reqcnt = #abpaths
    local cnt = 0
    local abresult = {}
    for _, abp in ipairs(abpaths) do
        res.__load_withcache(abp, util.assettype.assetbundle, res.__load_ab, function(ab, err)
            abresult[abp] = ab
            cnt = cnt + 1
            if cnt == reqcnt then
                callback(abresult[abpath], err)
            end
        end)
    end
end

function res.__load_withcache(assetpath, assettype, loadfunction, callback)
    local cache = res.__get_cache(assetpath)
    local cachedasset = cache:_get(assetpath)
    if cachedasset then
        --- result cache
        callback(cachedasset.asset, cachedasset.err)
    else
        --- request cache
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
end

function res.free(assetinfo)
    if logger.IsRes() then
        logger.Res("----free {0}", assetinfo.assetpath)
    end

    if res.useEditorLoad then
        assetinfo.cache:_free(assetinfo.assetpath)
    else
        if assetinfo.type == util.assettype.assetbundle then
            res.__free_ab_withdependency(assetinfo.assetpath)
        else
            --- 从assetbundle里出来的asset，load后持有所有依赖的引用，所以这里要全部释放
            assetinfo.cache:_free(assetinfo.assetpath)
            res.__free_ab_withdependency(assetinfo.abpath)
        end
    end
end

function res.__free_ab_withdependency(abpath)
    local abpaths = res.__get_dependences(abpath)
    for _, abp in ipairs(abpaths) do
        local cache = res.__get_cache(abp)
        cache:_free(abp)
    end
end

function res.__get_dependences(abpath)
    local abpaths = {}
    if res.manifest then
        local deps = res.manifest:GetAllDependencies(abpath)
        for _, dep in ipairs(deps.Table) do
            table.insert(abpaths, dep)
        end
    else
        logger.Error("manifest nil")
    end
    table.insert(abpaths, abpath)
    return abpaths
end

function res.__get_cache(assetpath)
    local assetinfo = cfgs.assets.all[assetpath]
    if assetinfo then
        return assetinfo.cache
    else
        return dependencyBundleCache
    end
end

return res