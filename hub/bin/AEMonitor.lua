local formatAmount = require("lib.formatAmount")

--- AE 存储监控类
--- * 在监视器上分页展示指定物品/流体的储量与趋势
--- * 依赖 Advanced Peripherals 的 meBridge 外设
--- @class AEMonitor
--- @field _monitor table 监视器相关信息
--- @field _maxNameSize number 名称最大长度
--- @field _page table 分页相关信息
--- @field _meBridge table ME 桥接器对象
--- @field _wanted {items:table<string,table>,fluids:table<string,table>} 需要采集的条目集合
--- @field _AECache {items:table,fluids:table} me数据缓存对象
--- @field _offline boolean ME 桥接器当前是否不可用
local AEMonitor = {}
AEMonitor.__index = AEMonitor

--- 数值列宽度
AEMonitor.VALUE_WIDTH = 13

--- 提示信息
AEMonitor.INFOTEXT = {
    PREV = "< Last",
    NEXT = "Next >",
    TITLE = "AE2 STORAGE MONITOR",
    SUBTITLE_RES = " Resource",
    SUBTITLE_AMOUNT = "Amount "
}

--- 初始化AE监控类
--- @param config table 配置参数
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @return AEMonitor
function AEMonitor:new(config, libs)
    if
        type(config) ~= "table"
        or type(config.list) ~= "table"
        or type(config.monitor) ~= "table"
        or type(config.monitor.minWidth) ~= "number"
        or type(config.monitor.minHeight) ~= "number"
    then
        error("Config file format error!", 2)
    end
    if type(config.monitor.name) ~= "string" then
        error("Config file format error: monitor.name is missing!", 2)
    end

    -- 初始化屏幕
    local monitor = peripheral.wrap(config.monitor.name)
    if type(monitor) ~= "table" or peripheral.getType(config.monitor.name) ~= "monitor" then
        error("Monitor not found on: " .. config.monitor.name, 2)
    end
    monitor.setTextScale(1)
    local wRaw, hRaw = monitor.getSize()
    local w, h = tonumber(wRaw) or 0, tonumber(hRaw) or 0
    if w < config.monitor.minWidth or h < config.monitor.minHeight then
        error(string.format(
            "Monitor too small, minimum %dx%d current %dx%d",
            config.monitor.minWidth,
            config.monitor.minHeight,
            w,
            h
        ), 2)
    end

    -- 初始化 meBridge (兼容 1.21.1 起的新外设名 me_bridge)
    local me
    for _, name in ipairs({ "meBridge", "me_bridge" }) do
        me = peripheral.find(name)
        if me then break end
    end
    if type(me) ~= "table" then
        error("meBridge terminal not found!", 2)
    end

    -- 创建对象
    local obj = setmetatable({
        _libs = libs,
        _meBridge = me,
        _offline = false,
        -- 显示器相关
        _monitor = {
            obj = monitor,
            name = config.monitor.name,
            minWidth = config.monitor.minWidth,
            minHeight = config.monitor.minHeight,
            w = w,
            h = h
        },
        _maxNameSize = 1,
        -- 分页管理相关
        _page = {
            size = 1,
            source = {},
            list = {},
            index = 1,
            change = true
        },
        -- 需要采集的条目集合
        _wanted = {
            items = {},
            fluids = {}
        },
        -- 缓存相关
        _AECache = {
            items = {},
            fluids = {}
        }
    }, self)

    -- 配置过滤和布局计算
    obj._wanted, obj._page.source = obj:_filterConfig(config.list)
    obj:_applyLayout()
    obj:_repage()

    -- 绘制标头
    obj:_drawHeader()

    return obj
end

--- 配置过滤
--- @param data table 待过滤的原始配置
--- @return {items:table<string,table>,fluids:table<string,table>} wanted 已过滤的根据类型分类的列表
--- @return table<number,table> flat 已过滤的条目完整列表
function AEMonitor:_filterConfig(data)
    local wanted = { items = {}, fluids = {} }
    local flat = {}

    for i, e in ipairs(data) do
        local valid = type(e) == "table"
            and type(e.id) == "string"
            and type(e.name) == "string"
            and type(e.unit) == "string"
            and (e.type == "fluid" or e.type == "item")

        if valid then
            local cell = {
                id = e.id,
                name = e.name,
                unit = e.unit,
                type = e.type,
            }
            flat[#flat + 1] = cell
            if e.type == "fluid" then
                wanted.fluids[e.id] = cell
            else
                wanted.items[e.id] = cell
            end
        else
            self._libs.log:warn("[AEMonitor] Configuration for index", i, "is not compliant, skipping")
        end
    end

    return wanted, flat
end

--- 根据当前监视器尺寸计算排版参数
function AEMonitor:_applyLayout()
    local w, h = self._monitor.w, self._monitor.h
    -- 名称列最多占用 60% 宽度, 数值列固定宽度
    self._maxNameSize = math.max(4, math.min(w - self.VALUE_WIDTH - 1, math.floor(w * 0.6)))
    -- 可渲染行数: 去掉表头与底部分页栏
    self._page.size = math.max(1, h - 3 - 1)
end

--- 按当前页容量重新分页
function AEMonitor:_repage()
    local source = self._page.source
    local size = self._page.size
    local list = {}
    local page
    for i = 1, #source do
        if (i - 1) % size == 0 then
            page = {}
            list[#list + 1] = page
        end
        page[#page + 1] = source[i]
    end
    self._page.list = list
    if #list == 0 then
        self._page.index = 1
    else
        self._page.index = math.min(math.max(self._page.index, 1), #list)
    end
    self._page.change = true
end

--- 绘制表头
function AEMonitor:_drawHeader()
    local monitor = self._monitor.obj
    local w = self._monitor.w

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    -- 第一行：标题居中
    local title = AEMonitor.INFOTEXT.TITLE
    if #title > w then title = title:sub(1, w) end
    monitor.setCursorPos(1, 1)
    monitor.setBackgroundColor(colors.cyan)
    monitor.setTextColor(colors.black)
    monitor.clearLine()
    monitor.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    monitor.write(title)

    -- 第二行：列标题
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, 2)
    monitor.write(AEMonitor.INFOTEXT.SUBTITLE_RES)
    monitor.setCursorPos(math.max(1, w - #AEMonitor.INFOTEXT.SUBTITLE_AMOUNT + 1), 2)
    monitor.write(AEMonitor.INFOTEXT.SUBTITLE_AMOUNT)

    -- 第三行：分隔线
    monitor.setCursorPos(1, 3)
    monitor.write(string.rep("-", w))
end

--- 绘制分页管理
function AEMonitor:_drawPageBar()
    local monitor = self._monitor.obj
    local w, h = self._monitor.w, self._monitor.h
    local total = #self._page.list

    monitor.setCursorPos(1, h)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clearLine()

    if total <= 1 then return end

    local canPrev = self._page.index > 1
    local canNext = self._page.index < total

    -- 渲染上一页按钮
    monitor.setBackgroundColor(canPrev and colors.cyan or colors.lightGray)
    monitor.setTextColor(colors.black)
    monitor.write(AEMonitor.INFOTEXT.PREV)

    -- 渲染下一页按钮
    monitor.setCursorPos(math.max(1, w - #AEMonitor.INFOTEXT.NEXT + 1), h)
    monitor.setBackgroundColor(canNext and colors.cyan or colors.lightGray)
    monitor.write(AEMonitor.INFOTEXT.NEXT)

    -- 渲染页数
    local pageText = self._page.index .. "/" .. total
    monitor.setCursorPos(math.floor((w - #pageText) / 2) + 1, h)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightBlue)
    monitor.write(pageText)
end

--- 渲染单行数据
--- @param index number 行索引
--- @param name string 资源名称
--- @param value number 资源数值
--- @param unit string 资源单位
--- @param trend number 近期趋势 ( 1: up| 0: none | -1: down )
function AEMonitor:_renderRow(index, name, value, unit, trend)
    local monitor = self._monitor.obj
    if index > self._monitor.h - 1 or index < 4 then return end

    -- 渲染名称
    if self._page.change then
        monitor.setCursorPos(1, index)
        monitor.setTextColor(colors.white)
        monitor.setBackgroundColor(colors.black)
        monitor.clearLine()
        if #name > self._maxNameSize then -- 过长截断
            name = name:sub(1, math.max(0, self._maxNameSize - 3)) .. "..."
        end
        monitor.write(name)
    end

    -- 预处理趋势相关
    local trendStr = "  "
    local trendColor = colors.lightBlue
    if trend == 1 then
        trendStr = "+ "
        trendColor = colors.green
    elseif trend == -1 then
        trendStr = "- "
        trendColor = colors.red
    end

    -- 渲染数量 (右对齐到监视器右边)
    local valueText = trendStr .. formatAmount(value) .. " " .. tostring(unit)
    local valStr = string.format("%" .. self.VALUE_WIDTH .. "s", valueText)
    monitor.setCursorPos(math.max(1, self._monitor.w - #valStr + 1), index)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(trendColor)
    monitor.write(valStr)
end

--- 获取需要注册的事件配置
function AEMonitor:getEventList()
    return {
        poll = true,
        monitor = true,
        monitorName = self._monitor.name,
        other = { "monitor_resize" }
    }
end

--- 从 ME 桥接器采集数据
--- @return {items:table,fluids:table}
function AEMonitor:_fetchCache()
    local newCache = { items = {}, fluids = {} }

    local sources = {
        { type = "items",  list = "listItems" },
        { type = "fluids", list = "listFluid" },
    }

    local offline = false
    for _, source in ipairs(sources) do
        local wanted = self._wanted[source.type]
        -- 没有配置该类型条目时无需查询
        if next(wanted) then
            local ok, data = pcall(self._meBridge[source.list])
            if not ok or type(data) ~= "table" then
                offline = true
            else
                local cache = newCache[source.type]
                for _, entry in ipairs(data) do
                    local name = type(entry) == "table" and entry.name or nil
                    if name and wanted[name] and cache[name] == nil then
                        cache[name] = entry
                    end
                end
            end
        end
    end

    if offline and not self._offline then
        self._libs.log:warn("[AEMonitor] ME bridge is unreachable, keeping the last known values")
    elseif not offline and self._offline then
        self._libs.log:info("[AEMonitor] ME bridge is back online")
    end
    self._offline = offline

    return newCache
end

--- 计算某条目的当前数值 (流体自动折算为桶)
--- @param cfg table 条目配置
--- @param cache {items:table,fluids:table} 数据缓存
--- @return number value
function AEMonitor._getAmount(cfg, cache)
    local isFluid = cfg.type == "fluid"
    local source = isFluid and cache.fluids or cache.items
    local data = source[cfg.id]
    local amount = type(data) == "table" and tonumber(data.amount) or nil
    if not amount then amount = 0 end
    if isFluid then amount = amount / 1000 end -- 流体转换为桶（B）
    return amount
end

--- 定时器触发函数: 刷新显示
function AEMonitor:poll()
    -- 获取实时数据
    local newCache = self:_fetchCache()

    -- 事件发送
    os.queueEvent("ae2_cache_update", newCache)

    -- 遍历配置渲染每一行
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then
        self._page.change = false
        return
    end

    if self._page.change then
        -- 清理数据区
        local monitor = self._monitor.obj
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        for row = 3 + 1, self._monitor.h - 1 do
            monitor.setCursorPos(1, row)
            monitor.clearLine()
        end

        -- 渲染分页管理
        self:_drawPageBar()
    end

    for i, cfg in ipairs(pageData) do
        local newCount = self._getAmount(cfg, newCache)
        local oldCount = self._getAmount(cfg, self._AECache)

        -- 趋势判断
        local trend = 0
        if newCount > oldCount then
            trend = 1  -- up
        elseif newCount < oldCount then
            trend = -1 -- down
        end

        self:_renderRow(i + 3, cfg.name, newCount, cfg.unit, trend)
    end

    -- 更新全局缓存
    self._AECache = newCache
    self._page.change = false
end

--- 事件触发函数
--- @param data table 事件对象
function AEMonitor:epoll(data)
    if type(data) ~= "table" then return end

    -- 显示器缩放事件
    if data[1] == "monitor_resize" then
        if data[2] ~= self._monitor.name then return end
        local wRaw, hRaw = self._monitor.obj.getSize()
        local w, h = tonumber(wRaw) or 0, tonumber(hRaw) or 0
        if w == self._monitor.w and h == self._monitor.h then return end
        if w < self._monitor.minWidth or h < self._monitor.minHeight then
            local txt = "X Error Too small"
            local monitor = self._monitor

            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.red)
            monitor.setCursorPos(1, 1)
            monitor.clear()
            local wNew = monitor.getSize()
            if #txt > wNew then
                local line = 1
                for i = 1, #txt, wNew do
                    local sepTxt = string.sub(txt, i, math.min(i + wNew - 1, #txt))

                    monitor.setCursorPos(1, line)
                    monitor.write(sepTxt)
                    line = line + 1
                end
            else
                monitor.write(txt)
            end

            return
        end
        self._monitor.w, self._monitor.h = w, h
        self:_applyLayout()
        self:_repage()
        self:_drawHeader()
        self:poll()
        return
    end

    -- 显示器点击事件
    if data[1] ~= "monitor_touch" then return end
    local x, y = tonumber(data[3]), tonumber(data[4])
    if not x or not y or y ~= self._monitor.h then return end

    local total = #self._page.list
    if total <= 1 then return end

    local prevWidth = #"< Last"
    local nextStart = self._monitor.w - #"Next >" + 1

    if x <= prevWidth and self._page.index > 1 then
        self._page.index = self._page.index - 1
        self._page.change = true
        self:poll()
    elseif x >= nextStart and self._page.index < total then
        self._page.index = self._page.index + 1
        self._page.change = true
        self:poll()
    end
end

-- 导出模块
return AEMonitor
