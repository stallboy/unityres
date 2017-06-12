local loader = require "res.loader"

--------------------------------------------------------
--- loader之上是Attachment
--- 每个attackey，只对应一个go 或者 asset
--- 如果已经attach了一个a，要attach另一个b，只有在b请求加载完成后才释放正在用的a，避免加载过程中出现空白。

local Attachment = {}

function Attachment:new(before_using_free_callback)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.attachments = {}
    instance.before_using_free_callback = before_using_free_callback
    return instance
end

function Attachment:attach(attachkey, thisloader, callback)
    if thisloader == nil then ---请用detach，这里不要为nil
        return
    end

    local attach = self.attachments[attachkey]
    if attach == nil then
        --- 只有在请求加载完成后才释放正在用的，避免加载过程中出现空白。
        attach = { using = nil, loading = nil }
        self.attachments[attachkey] = attach
    end

    if thisloader:equals(attach.using) then
        if attach.loading then
            attach.loading:free()
        end
        return
    end

    if thisloader:equals(attach.loading) then
        return
    end

    if attach.loading then
        attach.loading:free()
    end

    attach.loading = thisloader
    thisloader:load(function(assetorgo, err)
        self:_free_using(attachkey, attach)
        attach.loading = nil
        attach.using = thisloader
        callback(assetorgo, err)
    end)
end

function Attachment:get(attachkey)
    local attach = self.attachments[attachkey]
    if attach then
        return attach.using
    end
    return nil
end

function Attachment:detach(attachkey)
    local attach = self.attachments[attachkey]
    if attach then
        self:_free_using(attachkey, attach)
        if attach.loading then
            attach.loading:free()
        end
        self.attachments[attachkey] = nil
    end
end

function Attachment:_free_using(attachkey, attach)
    if attach.using then
        if self.before_using_free_callback then
            self.before_using_free_callback(attachkey, attach.using)
        end
        attach.using:free()
    end
end

function Attachment:free()
    for attachkey, attach in pairs(self.attachments) do
        self:_free_using(attachkey, attach)
        if attach.loading then
            attach.loading:free()
        end
    end
    self.attachments = {}
end

return Attachment
