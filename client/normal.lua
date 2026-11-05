-- 单元状态映射表
local STATUS_MAP = {
    [0] = { "Unknown", colors.red },
    [1] = { "Unknown", colors.red },
    [2] = { "Disabled", colors.lightGray },
    [3] = { "Stopped", colors.yellow },
    [4] = { "Running", colors.green },
    [5] = { "Standby", colors.lightBlue },
}

local STATUS_WIDTH = 10 -- 状态列宽度
local PAGE_PREV = "< Prev"
local PAGE_NEXT = "Next >"

local RECONNECT_DELAY = 5    -- 重连间隔 (秒)
local HANDSHAKE_TIMEOUT = 15 -- 单次握手超时 (秒)
local HANDSHAKE_INTERVAL = 3 -- 握手请求重发间隔 (秒)
local PING_INTERVAL = 5      -- 心跳间隔 (秒)

--- 获取可用的无线调制解调器
local function findWirelessModem()
    for _, modem in ipairs({ peripheral.find("modem") }) do
        if modem.isWireless() then return modem end
    end
    error("modem peripheral not found", 0)
end

--- 读取设置项
--- @param name string 设置项名称
--- @return any
local function readSetting(name)
    local ok, value = pcall(settings.get, name)
    if not ok then return nil end
    return value
end

-- 注册设置项声明
settings.define("factoryhub.serverId", { description = "Factory hub communication channel ID", type = "number" })
settings.define("factoryhub.monitorName", { description = "Monitor name for display cell status", type = "string" })

-- 初始化外设
local modem = findWirelessModem()
local serverId = readSetting("factoryhub.serverId")
local monitorName = readSetting("factoryhub.monitorName")

if type(serverId) ~= "number" or serverId < 0 or serverId > 65535 then
    printError("ServerId settings is wrong or not set.")
    print("Use 'set factoryhub.serverId <id>' in shell to set it.")
    error()
end
if type(monitorName) ~= "string" or not peripheral.isPresent(monitorName)
    or peripheral.getType(monitorName) ~= "monitor" then
    printError("monitorName settings is wrong or not set.")
    print("Use 'set factoryhub.monitorName <name>' in shell to set it.")
    error()
end

local graph = peripheral.wrap(monitorName)
graph.setTextScale(1)

-- 运行状态
local view = {
    w = 0,
    h = 0,
    pageSize = 1,
    startIndex = 1,
    data = {},
    online = false,
}

--- 重新读取监视器尺寸并校验
--- @return boolean isOK
local function refreshSize()
    local w, h = graph.getSize()
    view.w, view.h = w, h
    if w < #PAGE_PREV + #PAGE_NEXT + 4 or h < 4 then return false end
    view.pageSize = math.max(1, h - 2)
    return true
end

--- 绘制分页控制栏
local function drawPageBar()
    local w, h = view.w, view.h
    graph.setCursorPos(1, h)
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.white)
    graph.clearLine()

    local total = #view.data
    local stopIndex = math.min(view.startIndex + view.pageSize - 1, total)
    local prevColor = view.startIndex > 1 and colors.cyan or colors.lightGray
    local nextColor = stopIndex < total and colors.cyan or colors.lightGray

    graph.setBackgroundColor(prevColor)
    graph.setTextColor(colors.black)
    graph.write(PAGE_PREV)

    local pageText = total == 0 and "0 / 0" or string.format("%d - %d / %d", view.startIndex, stopIndex, total)
    local pageTextX = math.max(1, math.floor((w - #pageText) / 2) + 1)
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.lightBlue)
    graph.setCursorPos(pageTextX, h)
    graph.write(pageText)

    graph.setBackgroundColor(nextColor)
    graph.setTextColor(colors.black)
    graph.setCursorPos(math.max(1, w - #PAGE_NEXT + 1), h)
    graph.write(PAGE_NEXT)

    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.white)
end

--- 渲染整个视图
local function draw()
    local w, h = view.w, view.h
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.white)
    graph.clear()

    -- 标题
    local title = view.online and "Unit Status" or "Unit Status (offline)"
    graph.setBackgroundColor(colors.cyan)
    graph.setTextColor(colors.black)
    graph.setCursorPos(1, 1)
    graph.clearLine()
    graph.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    graph.write(title)
    graph.setTextColor(colors.white)
    graph.setBackgroundColor(colors.black)

    -- 数据
    local total = #view.data
    if total == 0 then
        graph.setCursorPos(1, 2)
        graph.setTextColor(colors.lightGray)
        graph.write(view.online and "Waiting for server data..." or "Disconnected, reconnecting...")
        graph.setTextColor(colors.white)
    else
        local endIndex = math.min(view.startIndex + view.pageSize - 1, total)
        local row = 2
        for itemIndex = view.startIndex, endIndex do
            local cell = view.data[itemIndex]
            if not cell or row >= h then break end

            local statusData = STATUS_MAP[cell.status] or STATUS_MAP[1]
            local nameText = tostring(cell.name or cell.tag or "?")
            local maxName = w - STATUS_WIDTH - 1
            if #nameText > maxName then
                nameText = nameText:sub(1, math.max(1, maxName - 3)) .. "..."
            end

            graph.setCursorPos(1, row)
            graph.setTextColor(colors.white)
            graph.setBackgroundColor(colors.black)
            graph.clearLine()
            graph.write(nameText)
            graph.setTextColor(statusData[2])
            graph.setCursorPos(math.max(1, w - STATUS_WIDTH + 1), row)
            graph.write(statusData[1])

            row = row + 1
        end
        graph.setTextColor(colors.white)
        graph.setBackgroundColor(colors.black)
    end

    drawPageBar()
end

--- 翻页
--- @param forward boolean 是否向后翻
--- @return boolean changed
local function turnPage(forward)
    local total = #view.data
    if total == 0 then return false end
    local stopIndex = math.min(view.startIndex + view.pageSize - 1, total)

    if forward then
        if stopIndex >= total then return false end
        view.startIndex = math.min(view.startIndex + view.pageSize, total)
    else
        if view.startIndex <= 1 then return false end
        view.startIndex = math.max(1, view.startIndex - view.pageSize)
    end
    return true
end

--- 收到新的单元数据
--- @param data table 单元列表 (扁平数组)
local function updateData(data)
    if type(data) ~= "table" then return end
    view.data = data
    -- 数据变少时修正起始索引
    local total = #view.data
    if total == 0 then
        view.startIndex = 1
    elseif view.startIndex > total then
        view.startIndex = math.max(1, total - view.pageSize + 1)
    end
end

-- 初始化显示
if not refreshSize() then
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.red)
    graph.setCursorPos(1, 1)
    graph.clear()
    graph.write("X The screen is too small")
    graph.setTextColor(colors.white)
    error("The screen is too small", 0)
end
graph.setBackgroundColor(colors.black)
graph.setTextColor(colors.white)
print("Trying to connect to the server")
draw()

--- 客户端标识
local CLIENT_ID = "normal_" .. os.getComputerID()

--- 建立握手 (带重试)
--- @return string mid 会话 mid
local function connect()
    local attempt = 0
    while true do
        attempt = attempt + 1
        local sessionMid
        parallel.waitForAny(
            function() -- 发送握手请求
                while true do
                    modem.transmit(serverId, serverId, {
                        code = 105,
                        mid = "EventReportClient",
                        data = { clientId = CLIENT_ID },
                    })
                    os.sleep(HANDSHAKE_INTERVAL)
                end
            end,
            function() -- 监听握手响应
                while true do
                    local _, _, id1, _, data = os.pullEvent("modem_message")
                    if
                        id1 == serverId
                        and type(data) == "table"
                        and data.code == 106
                        and data.tag == "CLIENT"
                        and type(data.data) == "table"
                        and type(data.data.mid) == "string"
                        and data.data.clientId == CLIENT_ID
                    then
                        sessionMid = data.data.mid
                        -- 回执确认, 之后主机开始推送数据
                        modem.transmit(serverId, serverId, {
                            code = 103,
                            mid = data.mid,
                        })
                        return
                    end
                end
            end,
            function() -- 超时
                os.sleep(HANDSHAKE_TIMEOUT)
            end
        )

        if sessionMid then
            print("Connected to server, session: " .. sessionMid)
            return sessionMid
        end

        print(("Connect attempt %d failed, retrying in %ds"):format(attempt, RECONNECT_DELAY))
        os.sleep(RECONNECT_DELAY)
    end
end

--- 会话主循环
--- @param sessionMid string 会话 mid
--- @return string reason 结束原因 ("terminate" 或 "reconnect")
local function session(sessionMid)
    local reason
    parallel.waitForAny(
        function() -- 心跳
            while true do
                os.sleep(PING_INTERVAL)
                modem.transmit(serverId, serverId, { code = 193, mid = sessionMid })
            end
        end,
        function() -- 退出信号
            while true do
                local event = { os.pullEventRaw() }
                if event[1] == "terminate" then
                    reason = "terminate"
                    return
                end
            end
        end,
        function() -- 事件处理
            while true do
                local event = { os.pullEventRaw() }
                local eventName = event[1]

                if eventName == "modem_message" and event[4] == serverId and type(event[5]) == "table" then
                    local payload = event[5]
                    if payload.code == 100 then -- 主机上线, 重新握手
                        view.online = false
                        draw()
                        reason = "reconnect"
                        return
                    elseif payload.code == 101 then -- 主机离线
                        view.online = false
                        draw()
                        reason = "reconnect"
                        return
                    elseif
                        payload.code == 106
                        and payload.tag == "CLIENT"
                    then
                        view.online = true
                    elseif
                        payload.code == 204
                        and payload.tag == "CLIENT"
                        and type(payload.data) == "table"
                        and payload.data.type == "unit_status_change"
                    then
                        view.online = true
                        updateData(payload.data.data)
                        draw()
                    end
                elseif eventName == "monitor_touch" and event[2] == monitorName and event[4] == view.h then
                    -- 翻页事件
                    local x = event[3]
                    if x <= #PAGE_PREV then
                        if turnPage(false) then draw() end
                    elseif x >= (view.w - #PAGE_NEXT + 1) then
                        if turnPage(true) then draw() end
                    end
                elseif eventName == "monitor_resize" and event[2] == monitorName then
                    if not refreshSize() then
                        graph.setBackgroundColor(colors.black)
                        graph.setTextColor(colors.red)
                        graph.setCursorPos(1, 1)
                        graph.clear()
                        graph.write("X The screen is too small")
                        graph.setTextColor(colors.white)
                        reason = "terminate"
                        return
                    end
                    draw()
                end
            end
        end
    )
    return reason or "reconnect"
end

-- 主循环: 断线自动重连
modem.open(serverId)
local lastMid = "EventReportClient"
while true do
    local mid = connect()
    lastMid = mid
    if session(mid) == "terminate" then break end
end

-- 退出清理
graph.setBackgroundColor(colors.black)
graph.setTextColor(colors.white)
graph.setCursorPos(1, 1)
graph.clear()
print("Send client exit signal")
modem.transmit(serverId, serverId, { code = 107, mid = lastMid })
os.sleep(0.2)
modem.close(serverId)
print("The client has exited.")
