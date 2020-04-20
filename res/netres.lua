local util = require "res.util"
local logger = require "common.Logger"
local common = require "common.common"
local cfg = require "cfg._cfgs"
local PriorityQueue = require "common.PriorityQueue"
local module = require("module.module")
local coroutine = coroutine
local WWW = UnityEngine.WWW
local Yield = UnityEngine.Yield
local Sprite = UnityEngine.Sprite
local Rect = UnityEngine.Rect
local Vector2 = UnityEngine.Vector2
local Application = UnityEngine.Application
local PlayerPrefs = UnityEngine.PlayerPrefs

--------------------------------------------
----从本地或网络加载image,返回texture
local netLoader = {}

function netLoader._downloadByLocal(url, filePath, callback)
    local co = coroutine.create(function()
        local www = WWW("file:///" .. filePath)
        Yield(www)
        local err = www.error
        local texture = www.texture
        www:Dispose()
        www = nil
        if err then
            err = "netres netLoader: load local image error, path:" .. (filePath or "nil") .. ", err:" .. err
            logger.Warn(err)
            netLoader._downloadByHttp(url, filePath, callback)
            return
        end
        callback(texture, err)
    end)
    coroutine.resume(co)
end

function netLoader._downloadByHttp(url, filePath, callback)
    local co = coroutine.create(function()
        local www = WWW(url)
        Yield(www)
        local err = www.error
        local texture = www.texture
        local bytes = www.bytes
        www:Dispose()
        www = nil
        if err then
            err = "netres netLoader: download from net error, url:" .. (url or "nil") .. ", err:" .. err
            logger.Warn(err)
            texture = nil
            bytes = nil
        else
            if filePath then
                FileUtils.WriteAllBytes(filePath, bytes)
            end
        end
        callback(texture, err)
    end)
    coroutine.resume(co)
end

function netLoader.download(url, filePath, callback)
    if filePath and FileUtils.Exist(filePath) then
        netLoader._downloadByLocal(url, filePath, callback)
    else
        netLoader._downloadByHttp(url, filePath, callback)
    end
end

--------------------------------------------
----typeCache，一种类型资源的Cache，是个优先队列
local Cache_Info_Prefs_Key_Prefix = "Net_Res_Cache_Info_Prefs_"
local typeCache = {}

function typeCache:new(netResTypeCfg)
    local instance = {
        _typeCfg = netResTypeCfg,
        _file2timeMap = {},
        _size = 0,
        _validMilliseconds = netResTypeCfg.validDays < 0 and -1 or common.timeutils.GetDayMillSeconds(netResTypeCfg.validDays),
        _maxCount = netResTypeCfg.maxCount < 0 and -1 or netResTypeCfg.maxCount,

        _dirty = false,
    }
    setmetatable(instance, self)
    self.__index = self
    return instance
end

function typeCache:_addFileCache(filePath, timestamp)
    if 0 == self._maxCount then
        return false
    end
    if self._file2timeMap[filePath] then
        return false
    end
    self._file2timeMap[filePath] = timestamp
    self._size = self._size + 1
    self:setDirty()
    if self._debug then
        logger.Info("netres typeCache: type:{0}, add:[{1}, {2}], size:{3}.", self:getType(), filePath, timestamp, self:size())
    end
    return true, self:resizeIf()
end

function typeCache:_updateFileCache(filePath, timestamp)
    if not self._file2timeMap[filePath] then
        return false
    end
    if timestamp == self._file2timeMap[filePath] then
        return true
    end
    self._file2timeMap[filePath] = timestamp
    self:setDirty()
    if self._debug then
        logger.Info("netres typeCache: type:{0}, update: [{1}, {2}], size: {3}.", self:getType(), filePath, timestamp, self:size())
    end
    return true
end

function typeCache:_removeFileCache(filePath)
    local timestamp = self._file2timeMap[filePath]
    if not timestamp then
        return
    end
    self._file2timeMap[filePath] = nil
    self._size = self._size - 1
    self:setDirty()
    if self._debug then
        logger.Info("netres typeCache: type:{0}, remove: [{1}, {2}], size: {3}.", self:getType(), filePath, timestamp, self:size())
    end
end

function typeCache:_resize()
    local size = self:size()
    local removedList = {}

    local reserveCount = self._typeCfg.reserveCount
    local removeCount = size - reserveCount
    if self._debug then
        print("netres resize reserveCount: ", reserveCount, ", removeCount: ", removeCount)
    end
    if removeCount <= reserveCount then
        local pq_max = PriorityQueue:new(function(a, b)
            return b.timestamp - a.timestamp
        end, function(a)
            return a.filePath
        end)
        self:foreach(function(filePath, timestamp)
            if pq_max:size() < removeCount then
                pq_max:offer({
                    filePath = filePath,
                    timestamp = timestamp,
                })
                return
            end
            local maxE = pq_max:peek()
            if maxE.timestamp > timestamp then
                pq_max:updateAt(1, {
                    filePath = filePath,
                    timestamp = timestamp,
                })
            end
        end)
        if self._debug then
            print("netres resize pq_max", pq_max:toString())
        end
        pq_max:foreach(function(e)
            table.insert(removedList, e.filePath)
        end)
    else
        local pq_min = PriorityQueue:new(function(a, b)
            return a.timestamp - b.timestamp
        end), function(a)
            return a.filePath
        end
        self:foreach(function(filePath, timestamp)
            if pq_min:size() < reserveCount then
                pq_min:offer({
                    filePath = filePath,
                    timestamp = timestamp,
                })
                return
            end
            local minE = pq_min:peek()
            if minE.timestamp < timestamp then
                pq_min:updateAt(1, {
                    filePath = filePath,
                    timestamp = timestamp,
                })
                table.insert(removedList, minE.filePath)
            else
                table.insert(removedList, filePath)
            end
        end)
        if self._debug then
            print("netres resize pq_min", pq_min:toString())
        end
    end
    if self._debug then
        local str = "["
        for i = 1, #removedList do
            if i > 1 then
                str = str .. ", "
            end
            str = str .. removedList[i]
        end
        print("netres resize removeList", str)
    end
    self:removeFileCaches(removedList)
    if self._debug then
        logger.Info("netres typeCache resize succ, type={0}, current size:{1}, original size:{2}.", self:getType(), self:size(), size)
    end
    return removedList
end

function typeCache:_setFile2TimeMap(file2timeMap)
    self._file2timeMap = file2timeMap
    self:_recalculateSize()
    self:setDirty()
end

function typeCache:_recalculateSize()
    local size = 0
    for _, _ in pairs(self._file2timeMap) do
        size = size + 1
    end
    self._size = size
end

function typeCache:serializeToPrefs()
    if not self:isDirty() then
        return
    end
    local ok, serializeContent = pcall(common.json.encode, self._file2timeMap)
    if not ok then
        logger.Error("netres typeCache serialize to prefs fail, type={0}", self:getType())
        return false
    end
    PlayerPrefs.SetString(Cache_Info_Prefs_Key_Prefix .. self._typeCfg.type, serializeContent)
    self._dirty = false
    if self._debug then
        logger.Info("netres typeCache serialize to prefs succ, type={0}, size={1}", self:getType(), self:size())
    end
    return true
end

function typeCache:deserializeFromPrefs()
    local deserializeContent = PlayerPrefs.GetString(Cache_Info_Prefs_Key_Prefix .. self:getType())
    if not deserializeContent or 0 == #deserializeContent then
        if self._debug then
            logger.Info("netres typeCache deserialize from prefs, but no prefs, type={0}.", self:getType())
        end
        return false
    end
    local ok, map = pcall(common.json.decode, deserializeContent)
    if not ok or type(map) ~= "table" then
        logger.Error("netres typeCache deserialize from prefs fail, type={0}", self:getType())
        return false
    end
    self:_setFile2TimeMap(map)
    self._dirty = false
    if self._debug then
        logger.Info("netres typeCache deserialize from prefs succ, type={0}, size={1}", self:getType(), self:size())
    end
    return true
end

function typeCache:isValidTime(timestamp, now)
    return self._validMilliseconds < 0 or now - timestamp <= self._validMilliseconds
end

function typeCache:setDirty()
    self._dirty = true
end

function typeCache:isDirty()
    return self._dirty
end

function typeCache:getTypeCfg()
    return self._typeCfg
end

function typeCache:getType()
    return self._typeCfg.type
end

function typeCache:size()
    return self._size
end

function typeCache:isEmpty()
    return 0 == self._size
end

function typeCache:getMaxCount()
    return self._maxCount
end

function typeCache:getValidMilliseconds()
    return self._validMilliseconds
end

function typeCache:setDebug(isDebug)
    self._debug = isDebug
end

function typeCache:retime(now)
    local removedList = {}
    self:foreach(function(filePath, timestamp)
        if 0 == timestamp or not self:isValidTime(timestamp, now) then
            table.insert(removedList, filePath)
        end
    end)
    if #removedList > 0 then
        self:removeFileCaches(removedList)
        if self._debug then
            logger.Info("netres typeCache retime succ, type={0}, size:{1}, invalid size:{2}.", self:getType(), self:size(), #removedList)
        end
    end
end

function typeCache:revalid()
    local removedList = {}
    self:foreach(function(filePath, timestamp)
        if type(filePath) ~= "string" or #filePath == 0 or type(timestamp) ~= "number" then
            table.insert(removedList, filePath)
        end
    end)
    if #removedList > 0 then
        self:removeFileCaches(removedList)
        if self._debug then
            logger.Info("netres typeCache reFilePath succ, type={0}, size:{1}, invalid size:{2}.", self:getType(), self:size(), #removedList)
        end
    end
end

function typeCache:resizeIf()
    if 0 > self._maxCount or self._size <= self._maxCount then
        return
    end
    return self:_resize()
end

function typeCache:init(now)
    self:deserializeFromPrefs()
    self:revalid()
    self:retime(now)
    self:resizeIf()
    if self._debug then
        logger.Info("netres typeCache init succ, type={0}, size={1}", self:getType(), self:size())
    end
end

function typeCache:initByFile2TimeMap(file2timeMap, now)
    self:_setFile2TimeMap(file2timeMap)
    self:retime(now)
    self:resizeIf()
    if self._debug then
        logger.Info("netres typeCache init by file2timeMap succ, type={0}, size={1}", self:getType(), self:size())
    end
end

function typeCache:addOrUpdateFileCache(filePath, timestamp, now, addCallback, updateCallback)
    if not self:isValidTime(timestamp, now) then
        return false
    end
    if self:_updateFileCache(filePath, timestamp) then
        if updateCallback then
            updateCallback()
        end
        return true
    end
    local ok, nullableRemovedList = self:_addFileCache(filePath, timestamp)
    if ok then
        if addCallback then
            addCallback(nullableRemovedList or {})
        end
        return true
    end
    return false
end

function typeCache:removeFileCaches(removedList)
    if #removedList == 0 then
        return
    end
    for _, removed in ipairs(removedList) do
        self:_removeFileCache(removed)
    end
end

function typeCache:foreach(doTask)
    local index = 0
    for filePath, timestamp in pairs(self._file2timeMap) do
        index = index + 1
        doTask(filePath, timestamp, index)
    end
end

--------------------------------------------
----网络资源管理
local netResMgr = {}
netResMgr.data = {
    caches = {
        type2cacheMap = {},
        file2useCountMap = {},
        serializeDurationSeconds = 10, -- 本地序列化间隔时间
        isClose = true,
    },
    folderMap = {},
    delTask = {
        stopTimer = nil,
        delTimes = 0,
        maxTimes = 50,
        countPerTime = 10,
        timesPerTask = 10,
        waitDelFiles = {},
    },
}
local data_mgr = netResMgr.data
local caches_mgr = data_mgr.caches
local delTask = data_mgr.delTask

local function formatPath(folder)
    -- 配置的目录，规范为: test/image/cache 的格式
    if #folder == 0 then
        return ""
    end
    local ok, formattedFolder = pcall(string.gsub, folder, "^[%s\\/]*(.-)[%s\\/]*$", "%1")
    if not ok then
        logger.Error("netres formatFolder trim error: folder={0}", folder)
        return folder
    end
    local ok, formattedFolder = pcall(string.gsub, formattedFolder, "[\\/]+", "/")
    if not ok then
        logger.Error("netres formatFolder switch error: folder={0}, formattedFolder={1}.", formattedFolder)
        return formattedFolder
    end
    return formattedFolder
end

function netResMgr._initFolders()
    data_mgr.folderMap = {}
    local folderMap = data_mgr.folderMap
    local formattedPersistentDataPath = formatPath(Application.persistentDataPath)
    for _, config in pairs(cfg.asset.netrestype.all) do
        local formattedFolder = formatPath(config.cacheFolder)
        folderMap[config] = common.utils.SafeFormat("{0}/{1}/", formattedPersistentDataPath, formattedFolder)
    end
end

function netResMgr._initCache()
    caches_mgr.isClose = not cfg.common.moduleopen.Net_Res_Cache.isOpen
    if caches_mgr.isClose then
        return
    end
    local oldVersionTypeCfg = cfg.asset.netrestype.OLD_VERSION
    local now = Utils.TimeUtils.GetLocalTime()

    local allEmpty = true
    caches_mgr.type2cacheMap = {}
    local type2cacheMap = caches_mgr.type2cacheMap
    for _, config in pairs(cfg.asset.netrestype.all) do
        local cache = typeCache:new(config)
        cache:setDebug(netResMgr.debug)
        cache:init(now)
        type2cacheMap[config] = cache
        if not cache:isEmpty() then
            allEmpty = false
        end
    end
    local isNeedInitOldVersionCache = allEmpty and oldVersionTypeCfg.maxCount ~= 0

    local scanFolders = {} -- 可能有重复的目录配置
    for _, folder in pairs(data_mgr.folderMap) do
        scanFolders[folder] = true
    end
    local folder4OldVersion = data_mgr.folderMap[oldVersionTypeCfg]

    caches_mgr.file2useCountMap = {}
    delTask.waitDelFiles = {}
    local file2useCountMap = caches_mgr.file2useCountMap
    local waitDelFiles = delTask.waitDelFiles
    for folder, _ in pairs(scanFolders) do
        local isInitOldVersionPq = isNeedInitOldVersionCache and folder4OldVersion == folder
        local file2timeMap = isInitOldVersionPq and {} or nil

        local fileAttrs = FileUtils.GetAllFileAttrsByDir(folder)
        local size = fileAttrs.Length
        for i = 1, size do
            local fileAttr = fileAttrs[i]
            local formattedFilePath = formatPath(fileAttr.filePath)
            file2useCountMap[formattedFilePath] = 0
            waitDelFiles[formattedFilePath] = true
            if file2timeMap then
                file2timeMap[formattedFilePath] = fileAttr.createTime
            end
        end

        if isInitOldVersionPq and next(file2timeMap) then
            local oldVersionCache = type2cacheMap[oldVersionTypeCfg]
            oldVersionCache:initByFile2TimeMap(file2timeMap, now)
            oldVersionCache:serializeToPrefs()
        end
    end
    for _, cache in pairs(type2cacheMap) do
        local removedList = {}
        cache:foreach(function(filePath)
            local useCount = file2useCountMap[filePath]
            if not useCount then
                -- 文件不存在
                table.insert(removedList, filePath)
            else
                netResMgr._addFileUseCount(filePath)
            end
        end)
        cache:removeFileCaches(removedList)
    end
    local serializeTimer = caches_mgr.serializeDurationSeconds
    module.event.evt_update_per_second:Register(function()
        serializeTimer = serializeTimer - 1
        if serializeTimer <= 0 then
            netResMgr.serialize()
            serializeTimer = caches_mgr.serializeDurationSeconds
        end
    end)
    netResMgr._doDeleteTask()
end

function netResMgr.serialize()
    for _, cache in pairs(caches_mgr.type2cacheMap) do
        cache:serializeToPrefs()
    end
end

function netResMgr._removeFileInCache(filePath)
    caches_mgr.file2useCountMap[filePath] = nil
    delTask.waitDelFiles[filePath] = nil
    if netResMgr.debug then
        logger.Info("netres netResMgr removeFileInCache: filePath: {0}.", filePath)
    end
end

function netResMgr._addFileUseCount(filePath)
    local file2useCountMap = caches_mgr.file2useCountMap
    file2useCountMap[filePath] = 1 + (file2useCountMap[filePath] or 0)
    delTask.waitDelFiles[filePath] = nil
    if netResMgr.debug then
        logger.Info("netres netResMgr addFileUseCount: filePath: {0}，current count: {1}.", filePath, file2useCountMap[filePath])
    end
end

function netResMgr._reduceFileUseCount(filePath)
    local file2useCountMap = caches_mgr.file2useCountMap
    local count = file2useCountMap[filePath] or 0
    count = count > 0 and count - 1 or 0
    file2useCountMap[filePath] = count
    if count == 0 then
        delTask.waitDelFiles[filePath] = true
    end
    if netResMgr.debug then
        logger.Info("netres netResMgr reduceFileUseCount: filePath: {0}，current count: {1}", filePath, file2useCountMap[filePath])
    end
end

function netResMgr._doDeleteTask()
    if delTask.stopTimer then
        delTask.delTimes = math.min(delTask.delTimes + delTask.timesPerTask, delTask.maxTimes)
        if netResMgr.debug then
            logger.Info("netres netResMgr doDeleteTask addTimes: delTimes: {0}.", delTask.delTimes)
        end
        return
    end
    if not next(delTask.waitDelFiles) then
        if netResMgr.debug then
            logger.Info("netres netResMgr doDeleteTask, but waitDelFiles is empty, delTimes: {0}.", delTask.delTimes)
        end
        return
    end
    delTask.delTimes = delTask.timesPerTask
    delTask.stopTimer = module.event.evt_update_per_second:Register(function()
        local delTimes = delTask.delTimes
        delTimes = delTimes - 1
        if delTimes < 0 then
            delTask.stopTimer()
            delTask.delTimes = 0
            delTask.stopTimer = nil
            return
        end
        delTask.delTimes = delTimes
        local countPerTime = delTask.countPerTime
        local delFiles = {}
        local cnt = 0
        for filePath, _ in pairs(delTask.waitDelFiles) do
            cnt = cnt + 1
            if cnt > countPerTime then
                break
            end
            table.insert(delFiles, filePath)
        end
        FileUtils.deleteFiles(delFiles)
        for _, filePath in ipairs(delFiles) do
            netResMgr._removeFileInCache(filePath)
        end
        if #delFiles < countPerTime then
            delTask.stopTimer()
            delTask.delTimes = 0
            delTask.stopTimer = nil
        end
    end)
    if netResMgr.debug then
        logger.Info("netres netResMgr doDeleteTask createTask: delTimes: {0}.", delTask.delTimes)
    end
end

function netResMgr.updateFileUsageNow(filePath, netResType)
    if caches_mgr.isClose then
        return
    end
    local now = Utils.TimeUtils.GetLocalTime()
    local cache = caches_mgr.type2cacheMap[netResType]
    cache:addOrUpdateFileCache(filePath, now, now, function(removedList)
        netResMgr._addFileUseCount(filePath)
        for _, removed in ipairs(removedList) do
            netResMgr._reduceFileUseCount(removed)
        end
    end)
    netResMgr._doDeleteTask()
end

function netResMgr.makeFilePath(url, netResType)
    local cacheFolder = data_mgr.folderMap[netResType]
    local md5Url = Utils.StringUtils.GetStringMD5Hash(url)
    return cacheFolder .. md5Url
end

function netResMgr.init()
    netResMgr.debug = UnityEngine.Application.isEditor
    netResMgr._initFolders()
    local start = Utils.TimeUtils.GetLocalTime()
    netResMgr._initCache()
    if netResMgr.debug then
        print("netres netResMgr initCache time: ", (Utils.TimeUtils.GetLocalTime() - start) / 1000)
    end
end

--------------------------------------------
----网络资源加载，暂时不考虑依赖关系
local netres = {}
netres.mgr = netResMgr
netres.netLoader = netLoader

function netres._load_asset_by_net(assetinfo, callback)
    local url = assetinfo.url
    local type = assetinfo.type
    local netResType = assetinfo.netResType or cfg.asset.netrestype.DEFAULT
    local filePath = netResMgr.makeFilePath(url, netResType)
    netLoader.download(url, filePath, function(texture, err)
        if not texture then
            callback(nil, err)
            return
        end
        netResMgr.updateFileUsageNow(filePath, netResType)
        local asset
        if type == util.assettype.sprite then
            asset = Sprite.Create(texture, Rect(0.0, 0.0, texture.width, texture.height), Vector2(0.5, 0.5))
        else
        end
        callback(asset, nil)
    end)
end

function netres.initialize()
    netResMgr:init()
end

return netres