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
--- @field _page {index:number,change:boolean,size:number,source:table,list:table<number,table<number,UnitItem>>} 分页相关信息
--- @field _columns table 各列宽度和起始坐标信息
--- @field _idMap {map:table,pollWaitCount:number} 实例id映射表
--- @field _libs {log:Log, net:MiniNet, root:string} 依赖库集合
local UnitStatus = {}
UnitStatus.__index = UnitStatus

--- 单元状态映射表
UnitStatus.STATUS = {
    [0] = { "Unknown", colors.red },
    [1] = { "Unknown", colors.red },
    [2] = { "Disabled", colors.lightGray },
    [3] = { "Stopped", colors.yellow },
    [4] = { "Running", colors.green },
    [5] = { "Standby", colors.lightBlue },
}

--- 表头占用行数
UnitStatus.HEADER_ROWS = 3
--- 默认超时心跳计数 (基于 poll 调用次数)
UnitStatus.POLL_TIMEOUT = 6

--- 初始化单元状态控制类
--- @param config table 配置参数
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
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

    -- 创建对象
    local obj = setmetatable({
        _libs = libs,
        _dataChange = true,
        -- 显示器相关
        _monitor = {
            obj = monitor,
            name = config.monitor.name,
            minWidth = config.monitor.minWidth,
            minHeight = config.monitor.minHeight,
            w = w,
            h = h
        },
        -- 分页相关
        _page = {
            size = 1,
            source = {},
            list = {},
            index = 1,
            change = true
        },
        -- 行列位置相关
        _columns = {},
        -- ID映射表相关
        _idMap = {
            map = {},
            pollWaitCount = 0
        }
    }, self)

    -- 配置处理与布局
    obj._page.source = self._filterConfig(config.list, libs.log)
    obj:_applyLayout()
    obj:_repage()

    -- 绘制标头
    obj:_drawHeader()

    -- 初始化主服务
    obj:_initCellNetServer()

    -- 监听客户端单元控制请求
    libs.net:setMessageListener(205, function(message, _) obj:_onClientMessage(message) end)

    -- 广播主机上线
    libs.net:broadcast("ALL", 100)

    return obj
end

--- 配置过滤
--- @param data table 待过滤的原始配置
--- @param log Log 日志实例
--- @return table<UnitItem> cleanCfg 已过滤的单元列表
function UnitStatus._filterConfig(data, log)
    local cleanCfg = {}

    for i, e in ipairs(data) do
        local valid = type(e) == "table"
            and type(e.name) == "string"
            and type(e.tag) == "string"
            and e.tag ~= ""

        if valid then
            cleanCfg[#cleanCfg + 1] = {
                status = 1,
                tag = e.tag,
                name = e.name,
                inProcess = false,
            }
        elseif log then
            log:warn("[UnitStatus] Configuration for index", i, "is not compliant, skipping")
        end
    end

    return cleanCfg
end

--- 根据当前监视器尺寸计算排版参数
function UnitStatus:_applyLayout()
    local w, h = self._monitor.w, self._monitor.h

    -- 动态计算列宽与起始位置
    local c1_w = math.max(4, math.floor(w * 0.4))
    local c2_start = 1 + c1_w
    local c2_w = math.max(1, math.floor((w - c1_w) / 2))
    local c3_start = math.min(w, c2_start + c2_w)
    local c3_w = math.max(1, w - c3_start + 1)

    local btnText = "[ TOGGLE ]"
    if #btnText > c3_w then btnText = "[T]" end
    local btnX = c3_start + math.floor((c3_w - #btnText) / 2)
    btnX = math.min(math.max(btnX, c3_start), math.max(c3_start, w - #btnText + 1))

    self._columns = {
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
    }
    -- 可渲染行数: 去掉表头与底部分页栏
    self._page.size = math.max(1, h - self.HEADER_ROWS - 1)
end

--- 按当前页容量重新分页
function UnitStatus:_repage()
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

--- 居中绘图函数
--- @param text string 要打印的字符串
--- @param startX number 起始X坐标
--- @param width number 字符宽度
--- @param y number Y坐标
function UnitStatus:_drawCentered(text, startX, width, y)
    local x = startX + math.floor((width - #text) / 2)
    x = math.max(1, math.min(x, math.max(1, self._monitor.w - #text + 1)))
    self._monitor.obj.setCursorPos(x, y)
    self._monitor.obj.write(text)
end

--- 初始化单元网络控制系统
function UnitStatus:_initCellNetServer()
    local tasks = {}
    local idMap = {}

    -- 遍历所有单元
    local ids = self._libs.net:genMessageID(math.max(1, #self._page.source))
    for i, cell in ipairs(self._page.source) do
        local mid = ids[i]
        idMap[cell.tag] = mid
        -- 生成网络任务
        tasks[#tasks + 1] = {
            mid = mid,
            rawCount = self.POLL_TIMEOUT,
            callback = function(_, code, isTimeout, data)
                if code == 193 and type(data) == "table" and type(data.status) == "number" then
                    -- 更新状态缓存
                    local status = data.status
                    if status > 0 and status < 6 and cell.status ~= status then
                        cell.status = status
                        self._dataChange = true
                        os.queueEvent("unit_status_change", self._page.source)
                        self._libs.log:debug("[UnitStatus]", cell.tag, "unit status switch, new status id", status)
                    end
                elseif cell.status ~= 1 and cell.status ~= 0 then
                    -- 单元处于不稳定状态 (超时/未知应答)
                    if isTimeout then
                        self._libs.log:warn("[UnitStatus] Unit", cell.tag, "heartbeat timeout, state unknown")
                    else
                        self._libs.log:warn("[UnitStatus] Unit", cell.tag, "has entered an unknown state")
                    end
                    cell.status = 0
                    self._dataChange = true
                    os.queueEvent("unit_status_change", self._page.source)
                end
                return true
            end
        }
    end

    -- 开始网络任务
    self._idMap.map = idMap
    self._libs.net:startTasks(tasks)
    self._libs.net:broadcast("ALL", 102, idMap)
end

--- 绘制表头
function UnitStatus:_drawHeader()
    local monitor = self._monitor.obj
    local w = self._monitor.w

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    -- 第一行: 标题居中
    local title = "Unit Status Control"
    if #title > w then title = title:sub(1, w) end
    monitor.setCursorPos(1, 1)
    monitor.setBackgroundColor(colors.cyan)
    monitor.setTextColor(colors.black)
    monitor.clearLine()
    monitor.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    monitor.write(title)

    -- 第二行: 列标题
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    self:_drawCentered("Unit", self._columns.c1_start, self._columns.c1_w, 2)
    self:_drawCentered("Status", self._columns.c2_start, self._columns.c2_w, 2)
    self:_drawCentered("Control", self._columns.c3_start, self._columns.c3_w, 2)

    -- 第三行: 分隔线
    monitor.setCursorPos(1, 3)
    monitor.write(string.rep("-", w))
end

--- 绘制分页管理
function UnitStatus:_drawPageBar()
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

    monitor.setBackgroundColor(canPrev and colors.cyan or colors.lightGray)
    monitor.setTextColor(colors.black)
    monitor.write("< Last")

    local nextText = "Next >"
    monitor.setCursorPos(math.max(1, w - #nextText + 1), h)
    monitor.setBackgroundColor(canNext and colors.cyan or colors.lightGray)
    monitor.write(nextText)

    local pageText = self._page.index .. "/" .. total
    monitor.setCursorPos(math.floor((w - #pageText) / 2) + 1, h)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightBlue)
    monitor.write(pageText)
end

--- 清空数据区
function UnitStatus:_clearDataArea()
    local monitor = self._monitor.obj
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    for row = self.HEADER_ROWS + 1, self._monitor.h - 1 do
        monitor.setCursorPos(1, row)
        monitor.clearLine()
    end
end

--- 渲染单行数据
--- @param index number 行索引
function UnitStatus:_renderRow(index)
    local monitor = self._monitor.obj
    if index > self._monitor.h - 1 or index < self.HEADER_ROWS + 1 then return end

    -- 获取行配置
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then return end
    local data = pageData[index - self.HEADER_ROWS]
    if type(data) ~= "table" then return end

    -- 渲染名称
    if self._page.change then
        monitor.setCursorPos(1, index)
        monitor.setTextColor(colors.white)
        monitor.setBackgroundColor(colors.black)
        monitor.clearLine()
        local txt = data.name
        if #data.name > self._columns.c1_w then -- 过长截断
            txt = data.name:sub(1, math.max(0, self._columns.c1_w - 3)) .. "..."
        end
        monitor.write(txt)
    end

    -- 状态列居中绘制
    local status = self.STATUS[data.status] or self.STATUS[1]
    monitor.setTextColor(status[2])
    self:_drawCentered(status[1], self._columns.c2_start, self._columns.c2_w, index)

    -- 控制按钮居中绘制
    local btnColor = data.status > 2 and colors.blue or colors.gray
    if data.inProcess then btnColor = colors.lightBlue end
    monitor.setCursorPos(self._columns.btn.x, index)
    monitor.setBackgroundColor(btnColor)
    monitor.setTextColor(colors.white)
    monitor.write(self._columns.btn.text)
    monitor.setBackgroundColor(colors.black)
end

--- 渲染当前页所有行
function UnitStatus:_renderPage()
    local pageData = self._page.list[self._page.index]
    if type(pageData) ~= "table" then return end
    if self._page.change then
        self:_clearDataArea()
    end
    for i = 1, #pageData do
        self:_renderRow(i + self.HEADER_ROWS)
    end
    self:_drawPageBar()
end

--- 获取需要注册的事件配置
function UnitStatus:getEventList()
    return {
        poll = true,
        monitor = true,
        monitorName = self._monitor.name,
        other = { "monitor_resize", "client_disconnect", "client_connect" }
    }
end

--- 定时器触发函数
function UnitStatus:poll()
    -- idMap 周期性广播 (单元可能重启, 需要重新拿到心跳 mid)
    self._idMap.pollWaitCount = self._idMap.pollWaitCount + 1
    if (self._idMap.pollWaitCount % self.POLL_TIMEOUT) == 0 then
        self._libs.net:broadcast("ALL", 102, self._idMap.map)
        self._libs.log:debug("[UnitStatus] Unit idMap broadcast")
    end

    -- 刷新显示
    if not self._dataChange and not self._page.change then return end
    self:_renderPage()
    self._dataChange = false
    self._page.change = false
end

--- 向单元转发控制请求
--- @param cell UnitItem 目标单元
--- @param code number 状态码 (200/201/202)
--- @param data any 载荷
--- @param reply? fun(ok:boolean, status:number|nil) 结果回调
function UnitStatus:_sendControl(cell, code, data, reply)
    if not cell or cell.inProcess then
        if reply then reply(false, nil) end
        return
    end
    cell.inProcess = true
    self._dataChange = true
    self._libs.net:send(cell.tag, code, data, 2, function(_, nCode, isTimeout, returnedData)
        cell.inProcess = false
        self._dataChange = true
        local newStatus = type(returnedData) == "table" and tonumber(returnedData.status) or nil
        if isTimeout or nCode == 104 then
            self._libs.log:error("[UnitStatus]", cell.tag, "unit control signal failed")
            if cell.status ~= 1 and cell.status ~= 0 then
                cell.status = 0
            end
            os.queueEvent("unit_status_change", self._page.source)
            self:poll()
            if reply then reply(false, nil) end
        elseif nCode == 103 then
            if newStatus and newStatus > 0 and newStatus < 6 then
                cell.status = newStatus
            end
            os.queueEvent("unit_status_change", self._page.source)
            self._libs.log:info("[UnitStatus]", cell.tag, "unit switch, new status id", cell.status)
            self:poll()
            if reply then reply(true, cell.status) end
        else
            if reply then reply(false, nil) end
        end
        return false
    end)
end

--- 事件触发函数
--- @param data table 事件对象
function UnitStatus:epoll(data)
    if type(data) ~= "table" then return end

    -- 客户端断开连接事件
    if data[1] == "client_disconnect" then

    end

    -- 客户端连接事件
    if data[1] == "client_connect" then

    end

    -- 显示器缩放事件
    if data[1] == "monitor_resize" then
        if data[2] ~= self._monitor.name then return end
        local wRaw, hRaw = self._monitor.obj.getSize()
        local w, h = tonumber(wRaw) or 0, tonumber(hRaw) or 0
        if w < self._monitor.minWidth or h < self._monitor.minHeight or w == self._monitor.w and h == self._monitor.h then
            return
        end
        self._monitor.w, self._monitor.h = w, h
        self:_applyLayout()
        self:_repage()
        self:_drawHeader()
        self._dataChange = true
        self:poll()
        return
    end

    -- 显示器点击事件
    if data[1] ~= "monitor_touch" then return end
    local x, y = tonumber(data[3]), tonumber(data[4])
    if not x or not y then return end

    local total = #self._page.list

    -- 底部分页栏
    if y == self._monitor.h then
        if total <= 1 then return end
        local nextStart = self._monitor.w - #"Next >" + 1
        if x <= #"< Last" and self._page.index > 1 then
            self._page.index = self._page.index - 1
            self._page.change = true
            self:poll()
        elseif x >= nextStart and self._page.index < total then
            self._page.index = self._page.index + 1
            self._page.change = true
            self:poll()
        end
        return
    end

    -- 只处理按钮列
    if y <= self.HEADER_ROWS or x <= self._columns.c3_start then return end

    -- 评估是否是有效单元行
    local pageData = self._page.list[self._page.index]
    local rowIndex = y - self.HEADER_ROWS
    if type(pageData) ~= "table" or rowIndex < 1 or rowIndex > #pageData then
        return
    end

    -- 执行控制操作
    local cellData = pageData[rowIndex]
    if cellData and cellData.status > 2 and cellData.status < 6 then
        self:_sendControl(cellData, 200, nil)
    end
end

--- 处理客户端直连控制请求
--- @param message table 网络消息体
function UnitStatus:_onClientMessage(message)
    local tag = message.tag
    local mid = message.mid
    local net = self._libs.net

    local cell
    for _, unit in ipairs(self._page.source) do
        if unit.tag == tag then
            cell = unit
            break
        end
    end

    if not cell or cell.status <= 2 or cell.status >= 6 then
        net:broadcast("CLIENT", 104, { tag = tag }, mid)
        return
    end

    self._libs.log:debug("[UnitStatus] Client control request for", cell.tag)
    self:_sendControl(cell, 200, message.data, function(ok, status)
        net:broadcast("CLIENT", ok and 103 or 104, {
            tag = tag,
            status = status,
        }, mid)
    end)
end

return UnitStatus
