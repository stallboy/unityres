local util = require "res.util"
local cfg = require "cfg._cfgs"
local logger = require "common.Logger"

local pairs = pairs
local unpack = unpack
local coroutine = coroutine
local WWW = UnityEngine.WWW
local AssetBundle = UnityEngine.AssetBundle
local Resources = UnityEngine.Resources
local Yield = UnityEngine.Yield
local IsPersistentLocal = ResUpdater.Res.IsPersistentLocal
local IsStreamingAssets = ResUpdater.Res.IsStreamingAssets
local GetAssetBundleLoadResPath = ResUpdater.Res.GetAssetBundleLoadResPath
local EditorLoadSpriteAtPath = ResUpdater.Res.EditorLoadSpriteAtPath
local EditorLoadAssetAtPath = ResUpdater.Res.EditorLoadAssetAtPath
local TakenNotesUseedResInfo = ResUpdater.Res.TakenNotesUseedResInfo
local recordSmallResInfo = ResUpdater.Res.recordSmallResInfo

local CheckResIsLocal = ResUpdater.Res.CheckResIsLocal

--------------------------------------------------------
--- res是最底层的接口，统一使用callback方式作为接口
--- 无论是prefab，assetbundle，sprite，asset都统一这一个load接口来加载。
--- load free要一一对应，无论load是否成功都会回调，应用都要记得调用free，同时只准在load回调之后才能free
--- 内带自动cache机制，策略是lru
------
--- cfg 有assets.csv，assetcachepolicy.csv，由打包程序生成
--- assets.csv 格式为 { assetpath=xx, assetid=xx, RefDirectDeps: {}, type: xx, location: xx, cachepolicy: xx }，
--- assetcachepolicy.csv 格式为{ name : xx, lruSize : xx }
--- type 可为 { assetbundle = 1, asset = 2, prefab = 3, sprite= 4  }； location 可为 { www = 1, resources = 2, net = 3}

local res = {}
res.cacheFactor = 1
res.all_access = 0
res.all_hit = 0
res.loadingPath = nil
res.smallResPath = nil

if ResUpdater.Res.IsSmallApp() == 1 then
    res.isSmallApp = true
    res.loadingPath = Platform.PlatformHelper.GetHelper():GetCDN_MAINPath(1)
    res.smallResPath = res.loadingPath .. ResUpdater.Res.SMALL_RES_PATH_NAME.. "/" .. ResUpdater.Res.BUNDLE_ID.. "/"
end

function res.__load_asset_at_res(assetinfo, callback)
    local co = coroutine.create(function()
        logger.Res("Resources.LoadAsync {0}", assetinfo.assetpath)
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


-- 验证是否下本地，如果不在，下载资源，缓存请求，回调使用
function res._load_AB_To_Local(assetinfo, callback)

    --res._loadingAssetidCallbackListsByCDN[assetinfo.assetid] = {assetinfo, callback}
    if res.smallResPath == nil then return end

    local cdnPath = res.smallResPath .. assetinfo.assetpath;
    local c = coroutine.create(function()
        local www = WWW(cdnPath)
        Yield(www)
        local err = www.error
        if err then
            www:Dispose()
            www = nil
        else
            local saveURL = UnityEngine.Application.persistentDataPath.."/"..assetinfo.assetpath
            if FileUtils.WriteAllBytes(saveURL, www.bytes) then
                -- 写入本地数据中 GetLength
                ResUpdater.Res.LuaLoadingResToLocal(assetinfo.assetpath, www.bytes.Length)

                local co = coroutine.create(function()
                    local assetBundleCreateRequest = AssetBundle.LoadFromFileAsync(saveURL)
                    Yield(assetBundleCreateRequest)
                    local ab = assetBundleCreateRequest.assetBundle
                    if ab then
                        callback(ab, nil)
                    else
                        local err = "LoadFromFileAsync.assetBundle nil " .. saveURL
                        callback(nil, err)
                    end
                end)
                coroutine.resume(co)
            end
        end

    end)
    coroutine.resume(c)
    return

end


function res.__load_ab(assetinfo, callback)

    -- 需要把所有本地资源信息 都放到内存里面，方便读取使用
    -- 先判断本地是否有，如果用，走正常流程； 如果没有，需要先下载然后回调
    local path
    if res.isSmallApp then
        path = CheckResIsLocal(assetinfo.assetpath)
        if path == "0" then
            res._load_AB_To_Local(assetinfo, callback)
            return
        end
    else
        path = GetAssetBundleLoadResPath(assetinfo.assetpath)
    end

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
        local fixedassetpath = "assets/" .. assetinfo.assetpath
        logger.Res("LoadAssetAsync {0}", assetinfo.assetpath)
        local isSprite = assetinfo.type == util.assettype.sprite
        local req
        if isSprite then
            req = ab:LoadAssetAsync(fixedassetpath, "UnityEngine.Sprite")
        else
            req = ab:LoadAssetAsync(fixedassetpath)
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

function res._loadInEditor(assetinfo, callback, ...)
    res.all_access = res.all_access + 1
    local assetpath = assetinfo.assetpath
    --print("@@@@::::", assetpath)
    res.GetAssetbundle(assetpath, 0)
    local cachedasset = assetinfo.RefCachepolicy.cache:_get(assetinfo)
    if cachedasset then
        res.all_hit = res.all_hit + 1
        callback(cachedasset.asset, cachedasset.err, ...)
    elseif assetinfo.location == util.assetlocation.net then
        res._doload(assetinfo, callback, ...)
    else
        logger.Res("EditorLoadAssetAtPath {0}", assetpath)
        local loadfunc = EditorLoadAssetAtPath
        if assetinfo.type == util.assettype.sprite then
            loadfunc = EditorLoadSpriteAtPath
        end
        local asset = loadfunc("assets/" .. assetinfo.assetpath)
        if asset then
            assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, nil, 1)
            callback(asset, nil, ...)
        else
            local err = "AssetDatabase has no asset " .. assetpath
            logger.Error(err)
            assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, err, 1)
            callback(nil, err, ...)
        end
    end
end

function res.IsLoadingLowScene(resPath)

    if resPath == "zc01_qixiazhen" or resPath == "zc01_xincheng" then
        return true
    end

    return false
end

function res.GetAssetbundle(resPath, isScene)

    if not UnityEngine.Application.isEditor then return end
    if not recordSmallResInfo then return end

    if isScene == 1 then

        if resPath == "zc01_qixiazhen" or resPath == "zc01_xincheng" then
            res.GetAssetbundle(resPath.."_low", 1)
        end

        resPath = "scene/"..resPath..".unity.bundle"
    end

    local assetinfo = cfg.asset.assets.get(resPath)
    if not assetinfo then

        TakenNotesUseedResInfo(resPath)
        return
    end

    TakenNotesUseedResInfo(resPath)
    -- 是否 有依赖
    local deps = assetinfo.RefDirectDeps
    if #deps == 0 then

        TakenNotesUseedResInfo(assetinfo.assetpath)
        return
    end

    for i = 1, #deps do
        local depassetinfo = deps[i]

        res.GetAssetbundle(depassetinfo.assetpath, 0)
    end
end

function res._realfreeInEditor(assetinfo)
end

function res.initialize(assetcachepolicys)
    res.useEditorLoad = UnityEngine.Application.isEditor and not ResUpdater.Res.useAssetBundleInEditor
    if res.useEditorLoad then
        res.load = res._loadInEditor
        res._realfree = res._realfreeInEditor
    end
    local Cache = require "res.Cache"
    for _, policy in pairs(assetcachepolicys) do
        policy.cache = Cache:new(policy.name, policy.lruSize)
    end
    res._loadingAssetid2CallbackLists = {} -- {assetid: { cb1, cb2 },  }
    res._loadingAssetidCallbackListsByCDN = {} -- {assetid:{ callback }, }

    res.netres = require "res.netres"
    res.netres.initialize()
end

--- 就算load 失败，也会回调callback(nil)，并且也会增加引用计数，
function res.load(assetinfo, resLoadCallback, ...)
    res.all_access = res.all_access + 1
    local cachedasset = assetinfo.RefCachepolicy.cache:_get(assetinfo)
    if cachedasset then
        res.all_hit = res.all_hit + 1
        resLoadCallback(cachedasset.asset, cachedasset.err, ...)
        return
    end
    res._doload2(assetinfo, resLoadCallback, ...)
end

function res._doload(assetinfo, resLoadCallback, ...)
    --- 在cache中，直接callback
    local cachedasset = assetinfo.RefCachepolicy.cache:_get(assetinfo)
    if cachedasset then
        resLoadCallback(cachedasset.asset, cachedasset.err, ...)
        return
    end
    res._doload2(assetinfo, resLoadCallback, ...)
end

function res._doload2(assetinfo, resLoadCallback, ...)
    --- 在loading过程中,加到callback列表里
    local ctx = { cb = resLoadCallback, args = { ... } }
    local assetid = assetinfo.assetid
    local cbs = res._loadingAssetid2CallbackLists[assetid]
    if cbs then
        table.insert(cbs, ctx)
        return
    end

    res._loadingAssetid2CallbackLists[assetid] = { ctx }
    local putCacheThenCallback = function(asset, err)
        --- 加载结束，放到cache，调用所有callback，(要先put再调用callback，可能callback里会发起新的load）
        local thisCbs = res._loadingAssetid2CallbackLists[assetid]
        local thisCbsCount = #thisCbs
        assetinfo.RefCachepolicy.cache:_put(assetinfo, asset, err, thisCbsCount)
        res._loadingAssetid2CallbackLists[assetid] = nil
        for i = 1, thisCbsCount do
            ctx = thisCbs[i]
            ctx.cb(asset, err, unpack(ctx.args))
        end
    end

    --- 开始load
    if assetinfo.location == util.assetlocation.net then
        ----暂不支持依赖
        res.netres._load_asset_by_net(assetinfo, putCacheThenCallback)
    elseif assetinfo.location == util.assetlocation.resources then
        res.__load_asset_at_res(assetinfo, putCacheThenCallback)
    elseif assetinfo.type == util.assettype.assetbundle then
        local depcnt = #assetinfo.RefDirectDeps
        if depcnt == 0 then
            res.__load_ab(assetinfo, putCacheThenCallback)
        else
            local deploadedcnt = 0
            --- 关键的一点：直接依赖，在资源第一次加载的时候，要确保它直接依赖的资源要增加一个引用计数，保证不会被释放
            --- 第二次的时候，资源已经在池子中或正在加载，这都不会增加它直接依赖的资源的引用计数
            local deps = assetinfo.RefDirectDeps
            for i = 1, #deps do
                local depassetinfo = deps[i]
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
        if depcnt == 1 then
            local abassetinfo = assetinfo.RefDirectDeps[1]
            res._doload(abassetinfo, function(ab, aberr)
                res.__load_asset_at_ab(assetinfo, ab, aberr, putCacheThenCallback)
            end)
        else
            --- 不应该到这里
            logger.Error("asset {0} depcnt {1} not 1", assetinfo.assetpath, depcnt)
            putCacheThenCallback(nil, "asset depcnt not 1")
        end
    end
end

--- 无论load成功失败，都需要free，以保证引用计数平衡
--- 但要保证在load 返回之后，再free，要不然会出错的，这里没有提示
--- 这个只free自己的计数，它的依赖仍然不释放计数，要等待真正它从cache.cached里也释放了，才释放它的依赖
function res.free(assetinfo)
    assetinfo.RefCachepolicy.cache:_free(assetinfo)
end

--- 真正从cache.cached里也释放了，这时释放它的依赖
function res._realfree(assetinfo)
    --- 释放这个assetbundle依赖的其他bundle
    local deps = assetinfo.RefDirectDeps
    for i = 1, #deps do
        local dep = deps[i]
        dep.RefCachepolicy.cache:_free(dep)
    end
end

return res