local loader = require "res.loader"

local Attachment = {}

function Attachment:new(before_using_free_callback)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.attachments = {}
    instance.before_using_free_callback = before_using_free_callback
    return instance
end

function Attachment:attach(attachpoint, loadfunc, callback)
    local attach = self.attachments[attachpoint]
    if attach == nil then
        --- 只有在请求加载完成后才释放正在用的，避免加载过程中出现空白。
        attach = { using = nil, loading = nil }
        self.attachments[attachpoint] = attach
    end

    if attach.loading then
        attach.loading:free()
    end

    attach.loading = loadfunc(function(assetorgo, err, this)
        self:_free_using(attachpoint, attach)
        --- 这个可能异步，也可能同步，同步时attach.loading可能还没赋值，所以要用this
        attach.loading = nil
        attach.using = this
        callback(this)
    end)

    --- 同步时loading又赋值了，所以这里清除掉
    if attach.loading.state == loader.StateUsing then
        attach.loading = nil
    end
end

function Attachment:detach(attachpoint)
    local attach = self.attachments[attachpoint]
    if attach then
        self:_free_using(attachpoint, attach)
        if attach.loading then
            attach.loading:free()
        end
        self.attachments[attachpoint] = nil
    end
end

function Attachment:_free_using(attachpoint, attach)
    if attach.using then
        if self.before_using_free_callback then
            self.before_using_free_callback(attachpoint, attach.using)
        end
        attach.using:free()
    end
end

function Attachment:free()
    for attachpoint, attach in pairs(self.attachments) do
        self:_free_using(attachpoint, attach)
        if attach.loading then
            attach.loading:free()
        end
    end
    self.attachments = {}
end

return Attachment
