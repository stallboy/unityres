local Cache = require "res.Cache"
local util = require "res.util"
local logger = require "common.Logger"
local WWW = UnityEngine.WWW
local AssetBundle = UnityEngine.AssetBundle

local pairs = pairs
local coroutine = coroutine

local Resources = UnityEngine.Resources
local Yield = UnityEngine.Yield

local pairs = pairs
local ipairs = ipairs
local coroutine = coroutine


local GetResPath = ResUpdater.Res.GetAssetBundleLoadResPath
local EditorLoadSpriteAtPath = ResUpdater.Res.EditorLoadSpriteAtPath
local EditorLoadAssetAtPath = ResUpdater.Res.EditorLoadAssetAtPath

--------------------------------------------------------
--- res是最底层的接口，统一使用callback方式作为接口
--- 无论是prefab，assetbundle，sprite，asset都统一这一个load接口来加载。
--- load free要一一对应，无论load是否成功都会回调，应用都要记得调用free，同时只准在load回调之后才能free
--- 内带自动cache机制，策略是lru
------
--- cfg 有assets.csv，assetcachepolicy.csv，由打包程序生成
--- assets.csv 格式为 { assetpath=xx, assetid=xx, RefDirectDeps: {}, type: xx, location: xx, cachepolicy: xx }，
--- assetcachepolicy.csv 格式为{ name : xx, lruSize : xx }
--- type 可为 { assetbundle = 1, asset = 2, prefab = 3, sprite= 4  }； location 可为 { www = 1, resources = 2 }；

local res = {}

Cache.res = res

function res.__load_asset_at_res(assetinfo, callback)
    local co = coroutine.create(function()
        logger.Res("    Resources.LoadAsync {0}", assetinfo.assetpath)
        local req = Resources.LoadAsync(assetinfo.assetpath)
        Yield(req)
        local asset = req.asset
        if asset then
            callback(asset)
        else
            local err = "Resources has no asset " .. assetinfo.assetpath
            logger.Error(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end


function res.__load_ab(assetinfo, callback)
    local path = GetResPath(assetinfo.assetpath)
    logger.Res("    AB.LoadFromFileAsync {0}", path)
    local co = coroutine.create(function()
        local assetBundleCreateRequest = AssetBundle.LoadFromFileAsync(path)
        Yield(assetBundleCreateRequest)
        local ab = assetBundleCreateRequest.assetBundle
        if ab then
            callback(ab, nil)
        else
            local err = "LoadFromFileAsync.assetBundle nil " .. path
            logger.Error(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end

function res.__load_asset_at_ab(assetinfo, ab, aberr, callback)
    if ab == nil then
        callback(nil, aberr)
        return
    end

    local co = coroutine.create(function()
        logger.Res("    LoadAssetAsync {0}", assetinfo.assetpath)
        local fixedassetpath = "assets/" .. assetinfo.assetpath
        local req
        if assetinfo.type ~= util.assettype.sprite then
            req = ab:LoadAssetAsync(fixedassetpath)
        else
            req = ab:LoadAssetAsync(fixedassetpath, "UnityEngine.Sprite")
        end
        Yield(req)
        local asset = req.asset
        if asset then
            callback(asset) -- ab not unload
        else
            local err = "LoadAssetAsync err " .. assetinfo.assetpath
            logger.Error(err)
            callback(nil, err)
        end
    end)
    coroutine.resume(co)
end

function res._loadInEditor(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    logger.Res("++++loadInEditor {0}", assetpath)

    local cachedasset = assetinfo.RefCachepolicy.cache:_get(assetinfo)
    if cachedasset then
        callback(cachedasset.asset, cachedasset.err)
    else
        logger.Res("    EditorLoadAssetAtPath {0}", assetpath)
        local loadfunc = EditorLoadAssetAtPath
        if assetinfo.type == util.assettype.sprite then
            loadfunc = EditorLoadSpriteAtPath
        end
        local asset = loadfunc("assets/" .. assetinfo.assetpath)
        if asset then
            assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, nil, 1)
            callback(asset)
        else
            local err = "AssetDatabase has no asset " .. assetpath
            logger.Error(err)
            assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, err, 1)
            callback(nil, err)
        end
    end
end

function res._realfreeInEditor(assetinfo)
    logger.Res("----realfreeInEditor {0}", assetinfo.assetpath)
end


function res.initialize(assetcachepolicys)
    res.useEditorLoad = UnityEngine.Application.isEditor and not ResUpdater.Res.useAssetBundleInEditor
	res.useEditorLoad then
        res.load = res._loadInEditor
        res._realfree = res._realfreeInEditor
    end

    for _, policy in pairs(assetcachepolicys) do
        policy.cache = Cache:new(policy.name, policy.lruSize)
    end

    res._loadingAssetid2CallbackLists = {} -- {assetid: { cb1, cb2 },  }
end


--- 就算load 失败，也会回调callback(nil)，并且也会增加引用计数，
function res.load(assetinfo, resLoadCallback)
    logger.Res("++++load {0}", assetinfo.assetpath)
    res._doload(assetinfo, resLoadCallback)
end

function res._doload(assetinfo, resLoadCallback)
    --- 在cache中，直接callback
    local cachedasset = assetinfo.RefCachepolicy.cache:_get(assetinfo)
    if cachedasset then
        resLoadCallback(cachedasset.asset, cachedasset.err)
        return
    end

    --- 在loading过程中,加到callback列表里
    local assetid = assetinfo.assetid
    local cbs = res._loadingAssetid2CallbackLists[assetid]
    if cbs then
        table.insert(cbs, resLoadCallback)
        return
    end

    cbs = { resLoadCallback }
    res._loadingAssetid2CallbackLists[assetid] = cbs
    local putCacheThenCallback = function(asset, err)
        --- 加载结束，放到cache，调用所有callback，(要先put再调用callback，可能callback里会发起新的load）
        local thisCbs = res._loadingAssetid2CallbackLists[assetid]
        local thisCbsCount = #thisCbs
        assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, err, thisCbsCount)
        res._loadingAssetid2CallbackLists[assetid] = nil
        for _, cb in ipairs(thisCbs) do
            cb(asset, err)
        end
    end

    --- 开始load
    if assetinfo.location == util.assetlocation.resources then
        res.__load_asset_at_res(assetinfo, putCacheThenCallback)
    elseif assetinfo.type == util.assettype.assetbundle then
        local depcnt = #assetinfo.RefDirectDeps
        if depcnt == 0 then
            res.__load_ab(assetinfo, putCacheThenCallback)
        else
            local deploadedcnt = 0
            for _, depassetinfo in ipairs(assetinfo.RefDirectDeps) do
                res._doload(depassetinfo, function()
                    deploadedcnt = deploadedcnt + 1
                    if deploadedcnt == depcnt then
                        res.__load_ab(assetinfo, putCacheThenCallback)
                    end
                end)
            end
        end
    else
        local depcnt = #assetinfo.RefDirectDeps
        if depcnt ~= 1 then
            logger.Error("asset {0} depcnt {1} not 1", assetinfo.assetpath, depcnt)
        end

        local abassetinfo = assetinfo.RefDirectDeps[1]
        res._doload(abassetinfo, function(ab, aberr)
            res.__load_asset_at_ab(assetinfo, ab, aberr, putCacheThenCallback)
        end)
    end
end



--- 无论load成功失败，都需要free，以保证引用计数平衡
--- 但要保证在load 返回之后，再free，要不然会出错的，这里没有提示
--- 这个只free自己的计数，它的依赖仍然不释放计数，要等待真正它从cache.cached里也释放了，才释放它的依赖
function res.free(assetinfo)
    logger.Res("----free {0}", assetinfo.assetpath)
    assetinfo.RefCachepolicy.cache:_free(assetinfo)
end

--- 真正从cache.cached里也释放了，这时释放它的依赖
function res._realfree(assetinfo)
    logger.Res("----realfree {0}", assetinfo.assetpath)
    --- 释放这个assetbundle依赖的其他bundle
    for _, dep in ipairs(assetinfo.RefDirectDeps) do
        dep.RefCachepolicy.cache:_free(dep)
    end
end

return res

