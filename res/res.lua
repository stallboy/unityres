local WWWLoader = require "res.WWWLoader"

local function dummy()
end

local res = {}

function res.init(bundlecache)
    res.wwwloader = WWWLoader:new()
    res.bundlecache = bundlecache
end

function res._load_single_nocache(assetpath, abpath, callback)
    res.wwwloader:load(abpath, function(www)
        if not www.error == nil then
            callback(www.error, nil, nil)
        else
            local ab = www.assetBundle
            if assetpath == nil then
                callback(nil, ab)
            else
                res.__doload_asset_nocache(ab, assetpath, callback)
            end
        end
    end)
end


function res.__doload_asset_nocache(ab, assetpath, callback)
    local co = coroutine.create(function()
        local req = ab:LoadAssetAsync(assetpath)
        Yield(req)
        callback(nil, req.asset, ab) -- ab not unload
    end)
    coroutine.resume(co)
end

-- assetinfo {asset: xx, bundle: xx, cache: xx}

function res.load(assetinfo, callback)
    local cb = callback
    if callback == nil then
        cb = dummy
    end

    local assetpath = assetinfo.asset
    local abpath = assetinfo.bundle
    local cache = assetinfo.cache
    local asset = cache:_load(assetpath)
    if asset then
        callback(nil, asset)
    else
        local ab = res.bundlecache:_load(abpath)
        if ab then
            -- can't just ab

        else
            local justab = assetpath == abpath
        end
    end
end

function res.free(assetinfo)
    assetinfo.cache:_free(assetinfo.asset)
end

return res