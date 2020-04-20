--------------------------------------------------------
--- loader之上是Attachment
--- 每个attackey，只对应一个go 或者 asset
--- 如果已经attach了一个a，要attach另一个b，只有在b请求加载完成后才释放正在用的a，避免加载过程中出现空白。

local Attachment = {}

function Attachment:new()
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.attachments = {}
    return instance
end

local function LoadDone(assetorgo, err, self, info, thisloader)
    self:_free_using(info)
    info.loading = nil
    info.using = thisloader
    if info.callback then
        info.callback(assetorgo, err, info.arg1, info.arg2, info.arg3, info.arg4, info.arg5, info.arg6)
    end
end

function Attachment:attach(attachkey, thisloader, callback, ...)
    local info = self.attachments[attachkey]
    if info == nil then
        --- 只有在请求加载完成后才释放正在用的，避免加载过程中出现空白。
        info = { using = nil, loading = nil }
        self.attachments[attachkey] = info
    end

    --- 这里保证会回调到最后一次的callback
    info.callback = callback
    info.arg1, info.arg2, info.arg3, info.arg4,  info.arg5, info.arg6 = ...

    if thisloader:equals(info.using) then
        self:_free_loading(info)
        if callback then
            local obj, err = info.using:res()
            callback(obj, err, ...)
        end
        return
    end

    if thisloader:equals(info.loading) then
        return
    end

    self:_free_loading(info)
    info.loading = thisloader
    info.loading:load(LoadDone, self, info, thisloader)
end

function Attachment:detach(attachkey)
    local info = self.attachments[attachkey]
    if info then
        self:_free_using(info)
        self:_free_loading(info)
        self.attachments[attachkey] = nil
    end
end

function Attachment:free()
    for _, info in pairs(self.attachments) do
        self:_free_using(info)
        self:_free_loading(info)
    end
    self.attachments = {}
end

function Attachment:_free_loading(info)
    if info.loading then
        info.loading:free()
        info.loading = nil
    end
end

function Attachment:_free_using(info)
    if info.using then
        info.using:free()
        info.using = nil
    end
end

return Attachment
