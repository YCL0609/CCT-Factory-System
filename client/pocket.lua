-- 单元状态映射表 (与主机端保持一致)
local STATUS_MAP = {
    [0] = { "Unknown", colors.red },
    [1] = { "Unknown", colors.red },
    [2] = { "Disabled", colors.lightGray },
    [3] = { "Stopped", colors.yellow },
    [4] = { "Running", colors.green },
    [5] = { "Standby", colors.lightBlue },
}

local PAGE_PREV = "< Prev"
local PAGE_NEXT = "Next >"
local BUTTON_TEXT = " o "

local RECONNECT_DELAY = 5    -- 重连间隔 (秒)
local HANDSHAKE_TIMEOUT = 15 -- 单次握手超时 (秒)
local HANDSHAKE_INTERVAL = 3 -- 握手请求重发间隔 (秒)
local PING_INTERVAL = 5      -- 心跳间隔 (秒)
local CONTROL_TIMEOUT = 15   -- 控制请求的等待时间 (超时后解除按钮锁)

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

settings.define("factoryhub.serverId", { description = "Factory hub communication channel ID", type = "number" })

local modem = findWirelessModem()
local serverId = readSetting("factoryhub.serverId")
if type(serverId) ~= "number" or serverId < 0 or serverId > 65535 then
    printError("ServerId settings is wrong or not set.")
    print("Use 'set factoryhub.serverId <id>' in shell to set it.")
    error()
end

-- 运行状态
local size = { term.getSize() }
local view = {
    w = size[1],
    h = size[2],
    pageSize = 1,
    startIndex = 1,
    data = {},
    online = false,
    pending = {}, -- 已发出但未确认的控制请求: tag -> 过期时间戳
    lineMap = {}, -- 行号 -> 单元下标
}

local COLOR_BG = colors.black
local COLOR_FG = colors.white

--- 清理已过期的控制请求锁
local function cleanPending()
    local now = os.epoch("utc")
    for tag, deadline in pairs(view.pending) do
        if now >= deadline then view.pending[tag] = nil end
    end
end

--- 绘制分页控制栏
local function drawPageBar()
    local w, h = view.w, view.h
    term.setCursorPos(1, h)
    term.setBackgroundColor(COLOR_BG)
    term.setTextColor(COLOR_FG)
    term.clearLine()

    local total = #view.data
    local stopIndex = math.min(view.startIndex + view.pageSize - 1, total)
    local prevColor = view.startIndex > 1 and colors.cyan or colors.lightGray
    local nextColor = stopIndex < total and colors.cyan or colors.lightGray

    term.setBackgroundColor(prevColor)
    term.setTextColor(colors.black)
    term.write(PAGE_PREV)

    local pageText = total == 0 and "0 / 0" or string.format("%d - %d / %d", view.startIndex, stopIndex, total)
    local pageTextX = math.max(1, math.floor((w - #pageText) / 2) + 1)
    term.setBackgroundColor(COLOR_BG)
    term.setTextColor(colors.lightBlue)
    term.setCursorPos(pageTextX, h)
    term.write(pageText)

    term.setBackgroundColor(nextColor)
    term.setTextColor(colors.black)
    term.setCursorPos(math.max(1, w - #PAGE_NEXT + 1), h)
    term.write(PAGE_NEXT)

    term.setBackgroundColor(COLOR_BG)
    term.setTextColor(COLOR_FG)
end

--- 渲染整个视图
local function draw()
    local w = view.w
    local lineMap = {}
    cleanPending()

    term.setBackgroundColor(COLOR_BG)
    term.setTextColor(COLOR_FG)
    term.clear()

    local total = #view.data
    if total == 0 then
        term.setCursorPos(1, 1)
        term.setTextColor(colors.lightGray)
        term.write(view.online and "Waiting for data..." or "Connecting...")
        term.setTextColor(COLOR_FG)
    else
        local endIndex = math.min(view.startIndex + view.pageSize - 1, total)
        local row = 1
        for itemIndex = view.startIndex, endIndex do
            local cell = view.data[itemIndex]
            if not cell or row >= view.h then break end

            local statusData = STATUS_MAP[cell.status] or STATUS_MAP[1]
            local nameText = tostring(cell.name or cell.tag or "?")
            local maxNameLen = w - #BUTTON_TEXT - 1
            if #nameText > maxNameLen then
                nameText = nameText:sub(1, math.max(1, maxNameLen - 3)) .. "..."
            end

            -- 名称使用状态颜色, 便于一眼分辨
            term.setCursorPos(1, row)
            term.setTextColor(statusData[2])
            term.setBackgroundColor(COLOR_BG)
            term.clearLine()
            term.write(nameText)

            -- 行末按钮
            local buttonColor
            if view.pending[cell.tag] then
                buttonColor = colors.lightBlue
            elseif cell.status and cell.status > 2 and cell.status < 6 then
                buttonColor = colors.blue
            else
                buttonColor = colors.gray
            end
            term.setTextColor(colors.white)
            term.setBackgroundColor(buttonColor)
            term.setCursorPos(math.max(1, w - #BUTTON_TEXT + 1), row)
            term.write(BUTTON_TEXT)

            lineMap[row] = itemIndex
            row = row + 1
        end
        term.setBackgroundColor(COLOR_BG)
        term.setTextColor(COLOR_FG)
    end

    view.lineMap = lineMap
    drawPageBar()
end

--- 翻页
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
local function updateData(data)
    if type(data) ~= "table" then return end
    view.data = data
    local total = #view.data
    if total == 0 then
        view.startIndex = 1
    elseif view.startIndex > total then
        view.startIndex = math.max(1, total - view.pageSize + 1)
    end
end

term.setBackgroundColor(COLOR_BG)
term.setTextColor(COLOR_FG)
term.clear()
term.setCursorPos(1, 1)
print("Trying to connect to the server")
draw()

--- 客户端标识
local CLIENT_ID = "pocket_" .. os.getComputerID()

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
                        mid = "EventReportServer",
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
            print("Connected, session: " .. sessionMid)
            return sessionMid
        end

        print(("Attempt %d failed, retry in %ds"):format(attempt, RECONNECT_DELAY))
        os.sleep(RECONNECT_DELAY)
    end
end

--- 发送控制请求
--- @param cell table 目标单元
local function requestSwitch(cell)
    if not cell or not cell.tag then return end
    local status = cell.status
    if not status or status <= 2 or status >= 6 then return end

    view.pending[cell.tag] = os.epoch("utc") + CONTROL_TIMEOUT * 1000
    modem.transmit(serverId, serverId, {
        tag = cell.tag,
        code = 205,
        mid = "ctrl_" .. os.getComputerID() .. "_" .. tostring(os.epoch("utc")),
    })
    draw()
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
                    elseif payload.code == 106 and payload.tag == "CLIENT" then
                        view.online = true
                    elseif payload.code == 204 and payload.tag == "CLIENT"
                        and type(payload.data) == "table"
                        and payload.data.type == "unit_status_change" then
                        view.online = true
                        view.pending = {}
                        updateData(payload.data.data)
                        draw()
                    elseif (payload.code == 103 or payload.code == 104) and type(payload.data) == "table" then
                        -- 主机的控制回执: 解除按钮锁
                        local tag = payload.data.tag
                        if type(tag) == "string" then
                            view.pending[tag] = nil
                            draw()
                        end
                    end
                elseif eventName == "mouse_click" and event[2] == 1 then
                    local clickX, clickY = event[3], event[4]

                    if clickY == view.h then
                        -- 分页
                        if clickX <= #PAGE_PREV then
                            if turnPage(false) then draw() end
                        elseif clickX >= (view.w - #PAGE_NEXT + 1) then
                            if turnPage(true) then draw() end
                        end
                    elseif clickY < view.h and clickX > view.w - #BUTTON_TEXT then
                        -- 行末按钮
                        local index = view.lineMap[clickY]
                        local cell = index and view.data[index]
                        if cell and not view.pending[cell.tag] then
                            requestSwitch(cell)
                        end
                    end
                end
            end
        end
    )
    return reason or "reconnect"
end

-- 主循环
modem.open(serverId)
local lastMid = "EventReportClient"
while true do
    local sessionMid = connect()
    lastMid = sessionMid
    local reason = session(sessionMid)
    if reason == "terminate" then break end
end

-- 退出清理
term.setBackgroundColor(COLOR_BG)
term.setTextColor(COLOR_FG)
term.setCursorPos(1, 1)
term.clear()
print("Send client exit signal")
modem.transmit(serverId, serverId, { code = 107, mid = lastMid })
os.sleep(0.2)
modem.close(serverId)
print("The client has exited.")
