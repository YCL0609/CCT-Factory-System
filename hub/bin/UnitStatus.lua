--- 单个单元模块
--- @class UnitItem
--- @field tag string 单元标签
--- @field name string 单元名称
--- @field status number 单元状态
--- @field inProcess boolean 是否正处理中

--- 单元状态控制
--- @class UnitStatus
--- @field _dataChange boolean 数据是否变更
--- @field _monitor table 监视器相关信息
--- @field _page {index:number,change:boolean,list:table<number,UnitItem>} 分页相关信息
--- @field _columns table 各列宽度和起始坐标信息
--- @field _idMap {map:table,pollWaitCount:number} 实例id映射表
--- @field _libs {log:Log, net:MiniNet} 依赖库集合
local UnitStatus = {}
UnitStatus.__index = UnitStatus

--- 初始化AE监控类
--- @param config table 配置参数
--- @param libs {log:Log, net:MiniNet} 依赖库集合
--- @return UnitStatus
function UnitStatus:new(config, libs)
    if
        type(config) ~= "table"
        or type(config.list) ~= "table"
        or type(config.monitor) ~= "table"
        or type(config.monitor.minWidth) ~= "number"
        or type(config.monitor.minHeight) ~= "number"
    then
        error("Config file format error!", 2)
    end

    -- 广播主机上线
    libs.net:broadcast("ALL", 100)

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

    -- 动态计算列宽与起始位置
    local c1_w = math.floor(w * 0.4)
    local c2_start = 1 + c1_w
    local c2_w = math.floor((w - c1_w) / 2)
    local c3_start = c2_start + c2_w
    local c3_w = w - c3_start + 1
    local btnText = "[ TOGGLE ]"
    local btnX = c3_start + math.floor((c3_w - #btnText) / 2)

    -- 创建对象
    local obj = setmetatable({
        _libs = libs,
        _dataChange = true,
        -- 显示器相关
        _monitor = {
            obj = monitor,
            w = w,
            h = h
        },
        -- 分页相关
        _page = {
            list = self._filterConfig(config.list or {}, h - 4),
            index = 1,
            change = true
        },
        -- 行列位置相关
        _columns = {
            c1_start = 1,
            c1_w = c1_w,
            c2_start = c2_start,
            c2_w = c2_w,
            c3_start = c3_start,
            c3_w = c3_w,
            btn = {
                text = btnText,
                x = btnX
            }
        },
        -- ID映射表相关
        _idMap = {
            map = {},
            pollWaitCount = 0
        }
    }, self)

    -- 绘制标头
    obj:_drawHeader()

    -- 初始化主服务
    obj:_initCellNetServer()

    return obj
end

--- 定义消息id映射
UnitStatus._statusQueue = {
    [1] = { "Unknown", colors.red },
    [2] = { "Disabled", colors.lightGray },
    [3] = { "Stopped", colors.yellow },
    [4] = { "Running", colors.green },
    [5] = { "Standby", colors.lightBlue },
}

--- 配置过滤
--- @param data table 待过滤的原始配置
--- @param count number 每个页面包含的条目计数
--- @return table<UnitItem> cleanCfg 已过滤的配置
function UnitStatus._filterConfig(data, count)
    local cleanCfg = {}
    local mainIndex = 1
    local cellIndex = 1
    for i, e in ipairs(data) do
        local valid = true
        -- 检查本体
        if type(e) ~= "table" then valid = false end
        -- 检查 name
        if type(e.name) ~= "string" then valid = false end
        -- 检查 tag
        if type(e.tag) ~= "string" then valid = false end

        -- 插入表
        if valid then
            if not cleanCfg[mainIndex] then
                cleanCfg[mainIndex] = {}
            end

            cleanCfg[mainIndex][cellIndex] = {
                status = 1,
                tag = e.tag,
                name = e.name,
                inProcess = false,
            }

            if cellIndex == count then
                -- 下一个单元插入下一页
                cellIndex = 1
                mainIndex = mainIndex + 1
            else
                -- 下一个单元插入当前页
                cellIndex = cellIndex + 1
            end
        else
            log:warn("[UnitStatus] Configuration for index", i, "is not compliant, skipping")
        end
    end

    return cleanCfg
end

--- 居中绘图函数
--- @param text string 要打印的字符串
--- @param startX number 起始X坐标
--- @param width number 字符宽度
--- @param y number Y坐标
function UnitStatus:_drawCentered(text, startX, width, y)
    local x = startX + math.floor((width - #text) / 2)
    self._monitor.obj.setCursorPos(x, y)
    self._monitor.obj.write(text)
end

--- 初始化单元网络控制系统
function UnitStatus:_initCellNetServer()
    local tasks = {}
    local idMap = {}

    -- 遍历处理每页
    for _, page in ipairs(self._page.list) do
        -- 每页独立获取消息id防止碰撞
        local ids = self._libs.net:genMessageID(#page)
        for i, cell in ipairs(page) do
            idMap[cell.tag] = ids[i]
            -- 生成网络任务
            tasks[#tasks + 1] = {
                mid = ids[i],
                ping = true,
                rawCount = 6, -- 默认配置时为 30s 超时时间
                callback = function(_, code, _, data)
                    if code == 193 and type(data) == "table" and type(data.status) == "number" then
                        -- 更新状态缓存
                        if cell.status ~= data.status and data.status > 0 and data.status < 6 then
                            cell.status = data.status
                            self._dataChange = true
                            os.queueEvent("unit_status_change", self._page.list)
                            self._libs.log:debug("[UnitStatus]", cell.tag, "unit status switch, new status id",
                                data.status)
                        end
                    elseif cell.status ~= 1 then
                        -- 单元处于不稳定状态
                        self._libs.log:warn("[UnitStatus] Unit", cell.tag, "has entered an unknown state")
                        cell.status = 0
                        self._dataChange = true
                        os.queueEvent("unit_status_change", self._page.list)
                    end
                    return true
                end
            }
        end
    end

    -- 开始网络任务
    self._idMap.map = idMap
    self._libs.net:startTasks(tasks)
    self._libs.net:broadcast("ALL", 102, idMap)
end

--- 绘制表头
function UnitStatus:_drawHeader()
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.clear()

    -- 第一行: 标题居中
    self._monitor.obj.setCursorPos(1, 1)
    self._monitor.obj.setBackgroundColor(colors.cyan)
    self._monitor.obj.setTextColor(colors.black)
    self._monitor.obj.clearLine()
    local title = "Unit Status Control"
    self._monitor.obj.setCursorPos(math.floor((self._monitor.w - #title) / 2) + 1, 1)
    self._monitor.obj.write(title)

    -- 第二行: 列标题
    self._monitor.obj.setBackgroundColor(colors.black)
    self._monitor.obj.setTextColor(colors.white)
    self:_drawCentered("Unit", self._columns.c1_start, self._columns.c1_w, 2)
    self:_drawCentered("Status", self._columns.c2_start, self._columns.c2_w, 2)
    self:_drawCentered("Control", self._columns.c3_start, self._columns.c3_w, 2)

    -- 第三行: 分隔线
    self._monitor.obj.setCursorPos(1, 3)
    self._monitor.obj.write(string.rep("-", self._monitor.w))
end

--- 绘制分页管理
function UnitStatus:_drawPageBar()
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
function UnitStatus:_renderRow(index)
    if index > self._monitor.h - 1 or index < 4 then return end

    -- 获取行配置
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then return end
    local data = pageData[index - 3]
    if type(data) ~= "table" then return end

    -- 渲染名称
    if self._page.change then
        self._monitor.obj.setCursorPos(1, index)
        self._monitor.obj.setTextColor(colors.white)
        self._monitor.obj.setBackgroundColor(colors.black)
        self._monitor.obj.clearLine()
        local txt = data.name
        if #data.name > self._columns.c1_w then -- 过长截断
            self._libs.log:warn("[UnitStatus] Unit name '", data.name, "' triggered an overlength truncation")
            txt = string.sub(data.name, 1, self._columns.c1_w - 3) .. "..."
        end
        self._monitor.obj.write(txt)
    end

    -- 状态列居中绘制
    local status = self._statusQueue[data.status] or self._statusQueue[1]
    self._monitor.obj.setTextColor(status[2])
    self:_drawCentered(status[1], self._columns.c2_start, self._columns.c2_w, index)

    -- 控制按钮居中绘制
    local btnColor = data.status > 2 and colors.blue or colors.gray
    if data.inProcess then btnColor = colors.lightBlue end
    self._monitor.obj.setCursorPos(self._columns.btn.x, index)
    self._monitor.obj.setBackgroundColor(btnColor)
    self._monitor.obj.setTextColor(colors.white)
    self._monitor.obj.write(self._columns.btn.text)
    self._monitor.obj.setBackgroundColor(colors.black)
end

--- 获取需要注册的事件配置
function UnitStatus:getEventList()
    return {
        poll = true,
        monitor = true,
        monitorName = peripheral.getName(self._monitor.obj),
        other = {}
    }
end

--- 定时器触发函数
function UnitStatus:poll()
    -- idMap广播
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then return end
    self._idMap.pollWaitCount = self._idMap.pollWaitCount + 1
    if (self._idMap.pollWaitCount % 6) == 0 then
        self._libs.net:broadcast("ALL", 102, self._idMap.map)
        self._libs.log:debug("[UnitStatus] Unit idMap broadcast")
    end

    -- 刷新显示
    if not self._dataChange then return end
    for i = 1, #self._page.list[self._page.index], 1 do
        self:_renderRow(i + 3)
    end
end

--- 事件触发函数: 屏幕点击按钮
--- @param data table 事件对象
function UnitStatus:epoll(data)
    if type(data) ~= "table" or data[1] ~= "monitor_touch" then
        return
    end

    -- 只处理按钮列
    local x, y = data[3], data[4]
    if y <= 3 or x <= self._columns.c3_start then return end

    -- 评估是否是有效单元行
    local rowIndex = y - 3
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" or rowIndex < 1 or rowIndex > #pageData then
        return
    end

    -- 执行控制操作
    local cellData = pageData[rowIndex]
    if cellData and not cellData.inProcess and cellData.status > 2 and cellData.status < 6 then
        cellData.inProcess = true
        self:_renderRow(y)
        self._libs.net:send(
            cellData.tag,
            200,
            nil,
            2,
            function(_, code, isTimeout, returnedData)
                if isTimeout and cellData.status ~= 1 then
                    self._libs.log:error("[UnitStatus]", cellData.tag, "unit switch signal timeout")
                    cellData.status = 1
                    cellData.inProcess = false
                    os.queueEvent("unit_status_change", self._page.list)
                    self:_renderRow(y)
                elseif code == 103 and type(returnedData) == "table" then
                    local status = returnedData.status or 0
                    if type(status) == "number" and status > 0 and status < 6 then
                        cellData.status = status
                        cellData.inProcess = false
                        os.queueEvent("unit_status_change", self._page.list)
                        self._libs.log:info("[UnitStatus]", cellData.tag, "unit switch, new status id", status)
                        self:_renderRow(y)
                    end
                end
                return false
            end
        )
    end
end

return UnitStatus
