local formatAmount = require("../lib.formatAmount")

--- AE监控类
--- @class AEMonitor
--- @field _monitor table 监视器相关信息
--- @field _maxNameSize number 名称最大长度
--- @field _dataStart number 数据起始位置
--- @field _page table 分页相关信息
--- @field _meBridge table ME 桥接器对象
--- @field _AECache { items:table, fluids:table } me数据缓存对象
local AEMonitor = {}
AEMonitor.__index = AEMonitor

--- 初始化AE监控类
--- @param config table 配置参数
--- @param libs {log:Log, net:MiniNet} 依赖库集合
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

    -- 初始化屏幕
    local monitor = peripheral.wrap(config.monitor.name)
    if not monitor or peripheral.getType(config.monitor.name) ~= "monitor" then
        error("Monitor not found on: " .. config.monitor.name, 2)
    end
    monitor.setTextScale(1)
    local w, h = monitor.getSize()
    if w < config.monitor.minWidth or h < config.monitor.minHeight then
        error(string.format(
            "Monitor too small, minimum %dx%d current %dx%d",
            config.monitor.minWidth,
            config.monitor.minHeight,
            w,
            h
        ), 2)
    end

    -- 初始化meBridge
    local me = peripheral.find("meBridge")
    if not me then
        error("meBridge terminal not found!", 2)
    end

    -- 创建对象
    local obj = setmetatable({
        _maxNameSize = math.modf(w * 0.6),
        _dataStart = w - 12,
        _meBridge = me,
        -- 显示器相关
        _monitor = {
            obj = monitor,
            w = w,
            h = h
        },
        -- 分页管理相关
        _page = {
            list = self._filterConfig(config.list or {}, h - 4, libs.log),
            index = 1,
            change = true
        },
        -- 缓存相关
        _AECache = {
            items = {},
            fluids = {}
        }
    }, self)

    -- 绘制标头
    obj:_drawHeader()

    return obj
end

--- 配置过滤
--- @param data table 待过滤的原始配置
--- @param count number 每个页面包含的条目计数
--- @param log Log 日志实例
--- @return table cleanCfg 已过滤的配置
function AEMonitor._filterConfig(data, count, log)
    local cleanCfg = {}
    local mainIndex = 1
    local cellIndex = 1
    for i, e in ipairs(data) do
        local valid = true
        -- 检查本体
        if type(e) ~= "table" then valid = false end
        -- 检查 id
        if type(e.id) ~= "string" then valid = false end
        -- 检查 name
        if type(e.name) ~= "string" then valid = false end
        -- 检查 unit
        if type(e.unit) ~= "string" then valid = false end
        -- 检查 type
        if e.type ~= "fluid" and e.type ~= "item" then valid = false end

        -- 插入表
        if valid then
            if not cleanCfg[mainIndex] then
                cleanCfg[mainIndex] = {}
            end

            cleanCfg[mainIndex][cellIndex] = {
                id = e.id,
                name = e.name,
                unit = e.unit,
                type = e.type
            }

            if cellIndex >= count then
                cellIndex = 1
                mainIndex = mainIndex + 1
            else
                cellIndex = cellIndex + 1
            end
        else
            log:warn("[AEMonitor] Configuration for index", i, "is not compliant, skipping")
        end
    end

    return cleanCfg
end

--- 绘制表头
function AEMonitor:_drawHeader()
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.clear()

    -- 第一行：标题居中
    self._monitor.obj.setCursorPos(1, 1)
    self._monitor.obj.setBackgroundColor(colors.cyan)
    self._monitor.obj.setTextColor(colors.black)
    self._monitor.obj.clearLine()
    local title = "AE2 STORAGE MONITOR"
    self._monitor.obj.setCursorPos(math.floor((self._monitor.w - #title) / 2) + 1, 1)
    self._monitor.obj.write(title)
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.setTextColor(colors.white)

    -- 第二行：列标题
    self._monitor.obj.setCursorPos(1, 2)
    self._monitor.obj.write(" Resource")
    local rightHead = "Amount "
    self._monitor.obj.setCursorPos(self._monitor.w - #rightHead + 1, 2)
    self._monitor.obj.write(rightHead)

    -- 第三行：分隔线
    self._monitor.obj.setCursorPos(1, 3)
    self._monitor.obj.write(string.rep("-", self._monitor.w))
end

--- 绘制分页管理
function AEMonitor:_drawPageBar()
    if not self._page.change or #self._page.list == 1 then return end
    self._monitor.obj.setCursorPos(1, self._monitor.h)
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.clearLine()

    -- 预生成按钮颜色
    local lastBg, nextBg
    if #self._page.list == 1 then
        lastBg = colors.lightGray
        nextBg = colors.lightGray
    elseif self._page.index == 1 then
        lastBg = colors.lightGray
        nextBg = colors.cyan
    elseif self._page.index == #self._page.list then
        lastBg = colors.cyan
        nextBg = colors.lightGray
    end

    -- 渲染上一页按钮
    self._monitor.obj.setBackgroundColor(lastBg)
    self._monitor.obj.setTextColor(colors.black)
    self._monitor.obj.write("< Last")

    -- 渲染下一页按钮
    local txt0 = "Next >"
    self._monitor.obj.setCursorPos(self._monitor.w - #txt0 + 1, self._monitor.h)
    self._monitor.obj.setBackgroundColor(nextBg)
    self._monitor.obj.setTextColor(colors.black)
    self._monitor.obj.write(txt0)

    -- 渲染页数
    local txt1 = self._page.index .. "/" .. #self._page.list
    self._monitor.obj.setCursorPos(math.floor((self._monitor.w - #txt1) / 2) + 1, self._monitor.h)
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.setTextColor(colors.lightBlue)
    self._monitor.obj.write(txt1)
end

--- 渲染单行数据
--- @param index number 行索引
--- @param name string 资源名称
--- @param value number 资源数值
--- @param unit string 资源单位
--- @param trend string 近期趋势
function AEMonitor:_renderRow(index, name, value, unit, trend)
    if index > self._monitor.h - 1 or index < 4 then return end

    -- 渲染名称
    if self._page.change then
        self._monitor.obj.setCursorPos(1, index)
        self._monitor.obj.setTextColor(colors.white)
        self._monitor.obj.setBackgroundColor(colors.black)
        self._monitor.obj.clearLine()
        if #name > self._maxNameSize then -- 过长截断
            name = string.sub(name, 1, self._maxNameSize - 3) .. "..."
        end
        self._monitor.obj.write(name)
    end

    -- 预处理趋势相关
    local trendStr = "  "
    local trendColor = colors.lightBlue
    if trend == "up" then
        trendStr = "+ "
        trendColor = colors.green
    elseif trend == "down" then
        trendStr = "- "
        trendColor = colors.red
    end

    -- 渲染数量
    local valStr = string.format("%13s", trendStr .. formatAmount(value) .. " " .. unit)
    self._monitor.obj.setCursorPos(self._dataStart, index)
    self._monitor.obj.setTextColor(trendColor)
    self._monitor.obj.write(valStr)
end

--- 获取需要注册的事件配置
function AEMonitor:getEventList()
    return {
        poll = true,
        monitor = true,
        monitorName = peripheral.getName(self._monitor.obj),
        other = {}
    }
end

--- 定时器触发函数: 刷新显示
function AEMonitor:poll()
    -- 获取实时数据
    local rawItems = self._meBridge.listItems() or {}
    local rawFluids = self._meBridge.listFluid() or {}
    local newCache = { items = {}, fluids = {} }

    -- 建立id名称索引表
    for _, data in ipairs(rawItems) do
        newCache.items[data.name] = data
    end
    for _, data in ipairs(rawFluids) do
        newCache.fluids[data.name] = data
    end

    -- 事件发送
    os.queueEvent("ae2_cache_update", newCache)

    -- 渲染分页管理
    self:_drawPageBar()

    -- 遍历配置渲染每一行
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then
        return
    end

    for i, cfg in ipairs(pageData) do
        local isFluid = cfg.type == "fluid"

        local newSource = isFluid and newCache.fluids or newCache.items
        local newData = newSource[cfg.id] or {}
        local newCount = newData.amount or 0

        local oldSource = isFluid and self._AECache.fluids or self._AECache.items
        local oldData = oldSource[cfg.id] or {}
        local oldCount = oldData.amount or 0

        -- 流体转换为桶（B）
        if isFluid then
            newCount = newCount / 1000
            oldCount = oldCount / 1000
        end

        -- 趋势判断
        local trend = "none"
        if newCount > oldCount then
            trend = "up"
        elseif newCount < oldCount then
            trend = "down"
        end

        -- 渲染该行
        self:_renderRow(
            i + 3,
            cfg.name,
            newCount,
            cfg.unit,
            trend
        )
    end

    -- 更新全局缓存
    self._AECache = {
        items = newCache.items,
        fluids = newCache.fluids
    }

    if self._page.change then self._page.change = false end
end

--- 事件触发函数: 按钮点击判断
--- @param data table 事件对象
function AEMonitor:epoll(data)
    if type(data) ~= "table" or type(data[3]) ~= "number" or type(data[4]) ~= "number" then
        return
    end

    if #self._page.list == 1 or data[4] ~= self._monitor.h then
        return
    end

    if self._page.index ~= 1 then -- 判断上一页
        if data[3] > 0 and data[3] < 6 then
            self._page.index = self._page.index - 1
            self._page.change = true
            self:poll()
        end
    elseif self._page.index ~= #self._page.list then -- 判断下一页
        if data[3] > self._monitor.w - 6 and data[3] < self._monitor.w then
            self._page.index = self._page.index + 1
            self._page.change = true
            self:poll()
        end
    end
end

-- 导出模块
return AEMonitor
