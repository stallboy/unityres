local module = require "module.module"

local pairs = pairs
local table = table

--------------------------------------------------------
--- UI分层系统：
--- 属于底层实现规划，不对上层开放api，可配置layer跟layer间的互斥关系
--- exc_layer        是本layer打开时，隐藏对应互斥的layer，等本layer关闭时恢复。
--- exc_panelbyclose 是本layer里有panel打开时，关闭对应互斥layer里的其他panel。
--- exc_panelbystack 是本layer里有panel打开时，把对应互斥layer里的其他panel隐藏并放栈上，等这个panel关闭时从栈中恢复。

local UILayer = {}

--- 这里realshow必然对应一个realhide。但一个show不一定对应一个hide。
--- 也就是说序列可能是show，realshow，realhide或show，hide
UILayer.status_show = 1
UILayer.status_realshow = 2
UILayer.status_realhide = 3
UILayer.status_hide = 4

local stack_maxdepth = 5

UILayer.stack = {} --- 全局栈用于exc_panelbystack
UILayer.stack_lastsource = nil

function UILayer:New(name, transform, pool, fire_panelevt)
    local instance = {}
    setmetatable(instance, self)
    self.__index = self
    instance.name = name
    instance.transform = transform
    instance.gameObject = transform.gameObject
    instance.pool = pool
    instance.fire_panelevt = fire_panelevt
    instance.panelchanged_callback = nil
    instance.exclusive = {}
    instance.activated = false
    instance.refcnt = 0
    instance.panels = {} --- 正在show的panel
    instance.canvas = transform.gameObject:GetComponent("Canvas")
    return instance
end

--- 互斥关系配置
function UILayer:exc(exclusive)
    self.exclusive = exclusive
end

--- 激活或隐藏回调
function UILayer:panelchanged(callback)
    self.panelchanged_callback = callback
end

function UILayer:onPanelStatusChange(panel, status)
    --- 注意这里用show来记录，用realshow来触发，来避免a已经show这时b.show，自动a hide但b异步加载还没加载上来导致这段时间没有ui面板
    if status == UILayer.status_show then
        self.panels[panel] = true
    elseif status == UILayer.status_realshow then
        self.panels[panel] = true
        if not self.activated then
            self.activated = true
            self:_onLayerActivate(true)
        end
        self:_onPanelShow(panel, true)
    elseif status == UILayer.status_realhide then
        self.panels[panel] = nil
        local empty = self:_isPanelEmpty()
        if empty and self.activated then
            self.activated = false
            self:_onLayerActivate(false)
        end
        self:_onPanelShow(panel, false)
    elseif status == UILayer.status_hide then
        self.panels[panel] = nil
    end
end

function UILayer:_isPanelEmpty()
    for _, _ in pairs(self.panels) do
        return false
    end
    return true
end

function UILayer:_onLayerActivate(activate)
    local exc_layer = self.exclusive.exc_layer
    if exc_layer then
        for i = 1, #exc_layer do
            local layer = exc_layer[i]
            layer:_setLayer(not activate)
        end
    end
end

function UILayer:_panelChangedCallback(fire,panel)
    if fire and self.fire_panelevt then
        module.event.evt_panel_active_changed:Trigger()
    end
    if self.panelchanged_callback then
        self:panelchanged_callback(panel)
    end
end

function UILayer:_setLayer(active)
    local change
    local old = self.refcnt
    if active then
        self.refcnt = old + 1
        if old == -1 then
            change = true
        end
    else
        self.refcnt = old - 1
        if old == 0 then
            change = false
        end
    end

    if change ~= nil then
        self.gameObject:SetActive(change)
        self:_panelChangedCallback(true)
    end
end

local tmpStackPanels
function UILayer:_onPanelShow(panel, show)
    self:_panelChangedCallback(false,panel)

    local exc_panelbyclose = self.exclusive.exc_panelbyclose
    if exc_panelbyclose and show then
        for i = 1, #exc_panelbyclose do
            local layer = exc_panelbyclose[i]
            layer:_setPanelClose(panel)
        end
    end

    local exc_panelbystack = self.exclusive.exc_panelbystack
    if exc_panelbystack then
        if show then
            local tryStack = (table.maxn(UILayer.stack) < stack_maxdepth)
            for i = 1, #exc_panelbystack do
                local layer = exc_panelbystack[i]
                if tryStack then
                    layer:_setPanelStack(panel)
                else
                    layer:_setPanelClose(panel) --- 超过最大栈深度，则变身exc_panelbyclose逻辑
                end
            end

            if tryStack and tmpStackPanels then
                --- 进栈
                UILayer.stack[#UILayer.stack + 1] = { source = panel, hides = tmpStackPanels }
                UILayer.stack_lastsource = panel
                tmpStackPanels = nil
            end
        elseif UILayer.stack_lastsource == panel then
            --- 原来没有这个while循环，可能导致abc，3层，当c关闭前，b已经hide了，那么c关闭没法触发b，没有b关闭，a就一直再栈里了，出不来
            local cnt = 0
            while cnt < stack_maxdepth do
                --- 这个是为了保险期间，不敢写while true
                cnt = cnt + 1
                local last = table.remove(UILayer.stack) --- 出栈
                if last == nil then
                    break
                end
                local n = table.maxn(UILayer.stack)
                if n > 0 then
                    UILayer.stack_lastsource = UILayer.stack[n].source
                else
                    UILayer.stack_lastsource = nil
                end

                for i = 1, #last.hides do
                    local p = last.hides[i]
                    if p:IsShowing() and p.__gameObject then
                        p.__gameObject:SetActive(true)
                        --- 出栈显示
                        p.__uilayer:_panelChangedCallback(true)
                    end
                end

                local lastsource = UILayer.stack_lastsource
                if lastsource == nil then
                    break
                elseif lastsource:IsShowing() and lastsource.__gameObject and lastsource.__gameObject.activeSelf then
                    --- 这个activeSelf也是为了保险
                    break
                else
                    --- go on
                end
            end

        end
    end
end

function UILayer:_setPanelClose(showedpanel)
    for panel, _ in pairs(self.panels) do
        if panel ~= showedpanel then
            panel:Hide() --- 这里会再触发self.panels[xx] = nil，但正好table可以在遍历时删除，这个地方感觉有问题，怕删除不干净，线上版本不敢改了
        end
    end
end

function UILayer:_setPanelStack(showedpanel)
    local changed = false
    for panel, _ in pairs(self.panels) do
        if panel ~= showedpanel and panel.__gameObject and panel.__gameObject.activeSelf then
            --- 注意这里要求panel必须是load上来的，如果正在loading，就不进栈，忽视了一点逻辑上的正确性，来换取UIComponent概念简单
            panel.__gameObject:SetActive(false)
            --- 进栈隐藏
            changed = true
            if tmpStackPanels == nil then
                tmpStackPanels = {}
            end
            tmpStackPanels[#tmpStackPanels + 1] = panel
        end
    end

    if changed then
        self:_panelChangedCallback(true)
    end
end

function UILayer.staticClearStack()
    UILayer.stack_lastsource = nil
    local last = table.remove(UILayer.stack)
    while last do
        for i = 1, #last.hides do
            local p = last.hides[i]
            p:Hide()
        end
        last = table.remove(UILayer.stack)
    end
end

function UILayer:hideAll()
    for panel, _ in pairs(self.panels) do
        panel:Hide()
    end
    self.panels = {}
    self.refcnt = 0
    self.activated = false
    self.gameObject:SetActive(true)
end

function UILayer:EnableCanvas(active)
    self.canvas.enabled = active
end

return UILayer
