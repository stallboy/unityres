local common = require "common.common"
local StateUsing = require "res.loader".StateUsing
local Vector3 = UnityEngine.Vector3
local Quaternion = UnityEngine.Quaternion
local pairs = pairs


--------------------------------------------------------
--- Avatar，它加了一个概念attachpoint，做2件事情
--- 1，保证所有attach都加载上来后整体显示，而不会单个显示出来，比如先显示个头，再显示身体就太怪了
--- 2，Avatar有个骨骼Skeleton，多个组件。组件有挂点attachpoint(可以为nil)，必须等Skeleton加载完后才挂到attachpoint上
--- 同时它本身又是一个loader可以attach 到attachment，avatar上。

local Avatar = {}

function Avatar:new(rootTransform, waitingRoomTransform, skeletonLoader, allAttachDone, allAttachDoneSelf)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.rootTransform = rootTransform
    instance.waitingRoomTransform = waitingRoomTransform
    instance.skeletonLoader = skeletonLoader
    instance.allAttachDone = allAttachDone
    instance.allAttachDoneSelf = allAttachDoneSelf
    instance.isLoadStarted = false

    instance.loading = {}
    instance.using = {}
    return instance
end

--------------------------------------------------------
--- 它本身作为loader，要满足的一系列接口
local function SkeletonLoadDone(go, err, self, callback, ...)
    if go then
        self:_set_transform_parent(go.transform, self.rootTransform)
    end

    if callback then
        callback(go, err, ...)
    end

    if self:_is_loading_all_loaded() then
        self:_move_loading_to_using()
    end
end

function Avatar:load(callback, ...)
    self.isLoadStarted = true
    if self.waiting then
        local newParts = self.waiting
        self.waiting = nil
        self:_set_parts(newParts)
    end
    self.skeletonLoader:load(SkeletonLoadDone, self, callback, ...)
end

function Avatar:free()
    self.waiting = nil
    self:_free_loading()
    self.loading = {}
    self:_free_using()
    self.using = {}

    self.skeletonLoader:free()
end

function Avatar:res()
    return self.skeletonLoader:res()
end

function Avatar:getState()
    return self.skeletonLoader:getState()
end

function Avatar:equals(_)
    return false
end


local function LoadingLoadDone(gameObject, err, self)
    if self:getState() == StateUsing and self:_is_loading_all_loaded() then
        self:_move_loading_to_using()
    elseif gameObject then
        gameObject.transform:SetParent(self.waitingRoomTransform, false) --- 放到等待室内，保证不会先出现个武器再出现人
    end
end

--------------------------------------------------------
--- 就一个核心方法，attachParts，这个会作为整体显示
--- newParts参数结构为： { <partKey>: <part>, }
--- part结构要包含：{attachpoint=xx, loader=xx}，建议类里有Render函数，在allAttachDone回调里依次调用各个part的Render
--- 每次attachParts要free掉之前的part，所以每次part要新建，跟上次不要共用
--- 这里直接保存newParts为loading，所以newParts也要新建
function Avatar:setParts(newParts)
    if self.isLoadStarted then
        self:_set_parts(newParts)
    else
        self.waiting = newParts
    end
end

function Avatar:_set_parts(newParts)
    self:_free_loading()
    self.loading = newParts

    for _, part in pairs(newParts) do
        part.loader:load(LoadingLoadDone, self)
    end
end

function Avatar:_is_loading_all_loaded()
    if next(self.loading) == nil then
        return false
    end
    for _, part in pairs(self.loading) do
        if part.loader:getState() ~= StateUsing then
            return false
        end
    end
    return true
end

function Avatar:_move_loading_to_using()
    for _, part in pairs(self.loading) do
        local go, err = part.loader:res()
        if go then
            local to = self:getTransformAtPoint(part.attachpoint, true)
            self:_set_transform_parent(go.transform, to) --- 从等待室内出来
        end
    end

    self:_free_using()
    self.using = self.loading
    self.loading = {}

    if self.allAttachDone then
        self.allAttachDone(self.allAttachDoneSelf, self.using)
    end
end

function Avatar:_free_loading()
    for _, part in pairs(self.loading) do
        if(part.free) then
            part:free()
        end
        part.loader:free()
    end
end

function Avatar:_free_using()
    for _, part in pairs(self.using) do
        if(part.free) then
            part:free()
        end
        part.loader:free()
    end
end

--------------------------------------------------------
--- 改挂点，查go
function Avatar:setAttachPoint(partKey, attachpoint)
    local loadingPart = self.loading[partKey]
    if loadingPart then
        loadingPart.attachpoint = attachpoint
    end

    local usingPart = self.using[partKey]
    if usingPart and usingPart.attachpoint ~= attachpoint then
        usingPart.attachpoint = attachpoint
        local usingPartGo, _ = usingPart.loader:res()
        if usingPartGo then
            local to = self:getTransformAtPoint(attachpoint, true)
            self:_set_transform_parent(usingPartGo.transform, to)
        end
    end
end

function Avatar:getSkeleton()
    local skeletonGo, _ = self.skeletonLoader:res()
    return skeletonGo
end

function Avatar:getTransformAtPoint(attachpoint, warnIfNotFound)
    local attachto = self.rootTransform
    local found = false
    local skeletonGo, _ = self.skeletonLoader:res()
    if skeletonGo then
        attachto = skeletonGo.transform
        if attachpoint and #attachpoint > 0 then
            local to = Utils.TransformUtils.RecursiveFind(attachto, attachpoint)
            if to then
                attachto = to
                found = true
            else
                if warnIfNotFound then
                    common.logger.Warn("attachpoint miss {0}", attachpoint)
                end
            end
        end
    end
    return attachto, found
end

function Avatar:getAttachedGameObject(partKey)
    local part = self.using[partKey]
    if part then
        local go, _ = part.loader:res()
        return go
    else
        return nil
    end
end

local VECTOR3_ZERO = Vector3.zero
local VECTOR3_ONE = Vector3.one
local QUATERNION_IDENTITY = Quaternion.identity

function Avatar:_set_transform_parent(trans, parent)
    trans:SetParent(parent, false)
    trans.localPosition = VECTOR3_ZERO
    trans.localScale = VECTOR3_ONE
    trans.localRotation = QUATERNION_IDENTITY
end

return Avatar