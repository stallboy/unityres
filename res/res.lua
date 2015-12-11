local WWWLoader = require "res.WWWLoader"
local Cache = require "res.Cache"
local CallbackCache = require "res.CallbackCache"
local LoadFuture = require "res.LoadFuture"

local AssetDatabase = UnityEngine.AssetDatabase
local Resources = UnityEngine.Resources

local res = {}

function res.init(editormode, abpath2assetinfo)
    res.editormode = editormode
    res.abpath2assetinfo = abpath2assetinfo -- 用于依赖加载时查找是否需要cache
    res.wwwloader = WWWLoader:new()
    res.manifest = nil
    res._loadings = CallbackCache:new() -- { assetinfo: {callback1: 1, callback2: 1}, ... } ,
    -- assetinfo 约定就用同一个引用来访问，上层不用自己构造assetinfo，而是直接拿到assetinfo.csv中的引用.
    -- callback 约定也不会注册2个相同的callback，所以一直都是1，没有考虑更新为2
end

function res.load_manifest(assetinfo, callback)
    res.__load_ab_asset(assetinfo.assetpath, assetinfo.abpath, function(err, manifest, ab)
        res.manifest = manifest -- load and stay resistent, no in cache, no free
        if ab then
            ab:Unload(false)
        end
        callback(err, manifest)
    end)
end

function res.load(assetinfo, callback)
    local cbs = res._loadings.resource2cbs[assetinfo]
    if cbs then
        cbs[callback] = 1
    else
        res._loadings:add(assetinfo, { callback = 1 })
        res.__load(assetinfo, function(err, asset)
            local cbs = res._loadings:remove(assetinfo)
            if cbs then
                for cb, _ in pairs(cbs) do
                    cb(err, asset) --可能cb里把这个asset给free了，但没关系，有cache基本保证了asset肯定还在。
                end
            end
        end)
    end
    return LoadFuture:new(res._loadings, assetinfo, callback)
end

function res.free(assetinfo)
    assetinfo.cache:_free(assetinfo.assetpath)
end

--  assetinfo {assetpath: xx, abpath: xx, type: xx, location: xx, cache: xx}
--  type, location 参考util.assettype, util.assetlocation
function res.__load(assetinfo, callback)
    local assetpath = assetinfo.assetpath
    local abpath = assetinfo.abpath
    local cache = assetinfo.cache

    local cachedasset = cache:_load(assetpath)
    if cachedasset then
        callback(nil, cachedasset)
    elseif res.editormode then
        local asset = AssetDatabase.LoadAssetAtPath(assetpath) --TODO, type
        if asset then
            cache:_newloaded(assetpath, asset, assetinfo.type)
            callback(nil, asset)
        else
            callback("LoadAssetAtPath return nil", nil)
        end
    elseif abpath == nil or #abpath == 0 then
        if assetinfo.location == util.assetlocation.www or assetinfo.type == util.assettype.assetbundle then
            callback("no abpath, but location is www or type is assetbundle", nil)
        else
            res.__load_asset_at_res(assetpath, function(err, asset)
                if err == nil then
                    cache:_newloaded(assetpath, asset, assetinfo.type)
                end
                callback(err, asset)
            end)
        end
    elseif res.manifest == nil then
        callback("manifest not load", nil)
    elseif assetinfo.location == util.assetlocation.resources then
        callback("do not put assetbundle in resources", nil)
    else
        local deps = res.manifest:GetAllDependencies(abpath)
        res.__load_ab_deps_withcache(abpath, deps, function(abs)
            local ab = abs[abpath]
            if ab == nil then
                callback("load bundle error " .. abpath, nil)
                res.__free_multi_ab_withcache(abs)
            elseif assetinfo.type == util.assettype.assetbundle then
                callback(nil, ab)
                abs[abpath] = nil
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
        local req = ab:LoadAssetAsync(assetpath) --can do many times, that's ok
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