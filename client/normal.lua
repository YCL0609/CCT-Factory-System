-- 初始化外设
local modem
for _, v in ipairs({ peripheral.find("modem") }) do
    if v.isWireless() then
        modem = v
        break
    end
end
if not modem then error("modem peripheral not found", 2) end
local serverId = settings.get("factoryhub.serverId")
local monitorName = settings.get("factoryhub.monitorName")
if type(serverId) ~= "number" or serverId < 0 or serverId > 65535 then
    printError("ServerId settings is wrong or not set.")
    print("Use 'set factoryhub.serverId <id>' in shell to set it.")
    error()
end
if type(monitorName) ~= "string" or not peripheral.isPresent(monitorName) then
    printError("monitorName settings is wrong or not set.")
    print("Use 'set factoryhub.monitorName <id>' in shell to set it.")
    error()
end
local graph = peripheral.wrap(monitorName)
local w, h = graph.getSize()
local statusStart = w - 8
if statusStart < 15 or h < 4 then error("The screen is too small", 2) end

local startIndex = { 1, 1 }
local dataCache = {}
local stopIndex = {}
local mid = ""
local statusColor = {
    [1] = { "Unknown", colors.red },
    [2] = { "Disabled", colors.lightGray },
    [3] = { "Stopped", colors.yellow },
    [4] = { "Running", colors.green },
    [5] = { "Standby", colors.lightBlue },
}
local pageBar = {
    prevText = "< Prev",
    nextText = "Next >",
}

-- 发送网络消息
local function transmit(payload)
    modem.transmit(serverId, serverId, payload)
end

-- 计算当前位置的下一个索引位置
local function indexIncrement(idx)
    local page = dataCache[idx[1]]
    if not page then return { idx[1], idx[2] } end
    if idx[2] < #page then
        return { idx[1], idx[2] + 1 }
    elseif idx[1] < #dataCache then
        return { idx[1] + 1, 1 }
    end
    return { idx[1], idx[2] }
end

-- 计算当前位置的前一个索引位置
local function indexDecrement(idx)
    if idx[2] > 1 then
        return { idx[1], idx[2] - 1 }
    elseif idx[1] > 1 then
        local prevPage = dataCache[idx[1] - 1] or {}
        return { idx[1] - 1, #prevPage }
    end
    return { idx[1], idx[2] }
end

-- 是否还有下一页
local function hasNext()
    if not stopIndex[1] then return false end
    local nextIndex = indexIncrement(stopIndex)
    return nextIndex[1] ~= stopIndex[1] or nextIndex[2] ~= stopIndex[2]
end

-- 绘制分页控制栏
local function drawPageBar()
    graph.setCursorPos(1, h)
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.white)
    graph.clearLine()

    local prevColor = startIndex[1] > 1 or startIndex[2] > 1 and colors.cyan or colors.lightGray
    local nextColor = hasNext() and colors.cyan or colors.lightGray

    graph.setBackgroundColor(prevColor)
    graph.setTextColor(colors.black)
    graph.write(pageBar.prevText)

    local pageText = string.format("%d:%d - %d:%d", startIndex[1], startIndex[2], stopIndex[1] or 0, stopIndex[2] or 0)
    local pageTextX = math.max(1, math.floor((w - #pageText) / 2) + 1)
    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.lightBlue)
    graph.setCursorPos(pageTextX, h)
    graph.write(pageText)

    graph.setBackgroundColor(nextColor)
    graph.setTextColor(colors.black)
    graph.setCursorPos(w - #pageBar.nextText + 1, h)
    graph.write(pageBar.nextText)

    graph.setBackgroundColor(colors.black)
    graph.setTextColor(colors.white)
end

-- 将视图向后翻页
local function moveStartBackward()
    if startIndex[1] <= 1 and startIndex[2] <= 1 then return false end
    local newIndex = { startIndex[1], startIndex[2] }
    local lines = h - 2
    for _ = 1, lines do
        if newIndex[1] == 1 and newIndex[2] == 1 then
            break
        end
        newIndex = indexDecrement(newIndex)
    end
    startIndex = newIndex
    return true
end

-- 将视图向前翻页
local function moveStartForward()
    if not hasNext() then return false end
    startIndex = indexIncrement(stopIndex)
    return true
end

--- 渲染数据
local function readerData()
    graph.setBackgroundColor(colors.black)
    graph.clear()
    -- 渲染标题
    local title = "Unit Status"
    graph.setBackgroundColor(colors.cyan)
    graph.setTextColor(colors.black)
    graph.setCursorPos(1, 1)
    graph.clearLine()
    graph.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    graph.write(title)
    graph.setTextColor(colors.white)
    graph.setBackgroundColor(colors.black)

    -- 渲染数据
    local row = 2
    stopIndex = {}
    for pageIndex = startIndex[1], #dataCache do
        local page = dataCache[pageIndex]
        if not page then break end

        local fromItem = pageIndex == startIndex[1] and startIndex[2] or 1
        for itemIndex = fromItem, #page do
            if row >= h then break end

            local cell = page[itemIndex]
            local statusData = statusColor[cell.status or 1] or {}

            local nameText = cell.name or ""
            if #nameText > w - 12 then
                nameText = string.sub(nameText, 1, w - 15) .. "..."
            end
            graph.setCursorPos(1, row)
            graph.setTextColor(colors.white)
            graph.write(nameText)
            graph.setTextColor(statusData[2] or colors.red)
            graph.setCursorPos(statusStart, row)
            graph.write(statusData[1] or "Unknown")

            stopIndex = { pageIndex, itemIndex }
            row = row + 1
        end

        if row >= h then break end
    end

    drawPageBar()
end

--- 网络Ping
local function netPingTask()
    while true do
        os.sleep(5)
        transmit({ code = 193, mid = mid })
    end
end

--- 事件处理
local function eventTask()
    while true do
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "terminate" then -- 退出
            graph.setBackgroundColor(colors.black)
            graph.setTextColor(colors.white)
            graph.setCursorPos(1, 1)
            graph.clear()
            print("Send client exit signal")
            modem.close(serverId)
            transmit({ code = 107, mid = mid })
            print("The client has exited.")
            return
        elseif -- 网络同步事件
            eventName == "modem_message"
            and event[4] == serverId
            and type(event[5]) == "table"
            and event[5].code == 106
            and event[5].tag == "CLIENT"
            and type(event[5].data) == "table"
            and event[5].data.type == "unit_status_change"
        then
            dataCache = event[5].data.data
            readerData()
        elseif eventName == "monitor_touch" and event[4] == h then -- 翻页事件
            if (event[3] <= #pageBar.prevText and moveStartBackward()) or
                (event[3] >= (w - #pageBar.nextText + 1) and moveStartForward()) then
                readerData()
            end
        elseif eventName == "monitor_resize" and event[2] == monitorName then -- 屏幕尺寸改变事件
            w, h = graph.getSize()
            statusStart = w - 8
            if statusStart < 15 or h < 4 then
                modem.close(serverId)
                transmit({ code = 107, mid = mid })
                graph.setBackgroundColor(colors.black)
                graph.setTextColor(colors.red)
                graph.setCursorPos(1, 1)
                graph.clear()
                graph.write("X Error")
                graph.setTextColor(colors.white)
                error("The screen is too small", 2)
            else
                readerData()
            end
        end
    end
end

-- 初始化
print("Trying to connect to the server")
graph.setBackgroundColor(colors.black)
graph.setTextColor(colors.white)
graph.setTextScale(1)
graph.clear()

parallel.waitForAny(function()
    modem.open(serverId)
    transmit({
        code = 105,
        mid = "EventReportServer",
        data = { clientId = "normal_" .. os.getComputerID() },
    })

    while true do
        local _, _, id1, id2, data = os.pullEvent("modem_message")
        if
            id1 == serverId
            and id2 == serverId
            and type(data) == "table"
            and data.code == 106
            and data.tag == "CLIENT"
            and type(data.data) == "table"
            and type(data.data.mid) == "string"
            and data.data.clientId == "normal_" .. os.getComputerID()
        then
            mid = data.data.mid
            modem.transmit(serverId, serverId, {
                code = 103,
                mid = data.mid,
            })
            return
        end
    end
end, function()
    os.sleep(5)
    error("Server connection timed out!", 2)
end)
print("Waiting for server data")

parallel.waitForAny(eventTask, netPingTask)
