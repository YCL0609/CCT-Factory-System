local modem = peripheral.find("modem")
assert(modem, "modem peripheral not found")
local serverId = settings.get("factoryhub.serverId")
if type(serverId) ~= "number" or serverId < 0 or serverId > 65535 then
    printError("ServerId settings is wrong or not set.")
    print("Use 'set factoryhub.serverId <id>' in shell to set it.")
    error()
end
local w, h = term.getSize()
local startIndex = { 1, 1 }
local clickedButtons = {}
local dataCache = {}
local stopIndex = {}
local lineMap = {}
local mid = ""
local statusColor = {
    [1] = colors.red,       -- Unknown
    [2] = colors.lightGray, -- Disabled
    [3] = colors.yellow,    -- Stopped
    [4] = colors.green,     -- Running
    [5] = colors.lightBlue, -- Standby
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
    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clearLine()

    local prevColor = startIndex[1] > 1 or startIndex[2] > 1 and colors.cyan or colors.lightGray
    local nextColor = hasNext() and colors.cyan or colors.lightGray

    term.setBackgroundColor(prevColor)
    term.setTextColor(colors.black)
    term.write(pageBar.prevText)

    local pageText = string.format("%d:%d - %d:%d", startIndex[1], startIndex[2], stopIndex[1] or 0, stopIndex[2] or 0)
    local pageTextX = math.max(1, math.floor((w - #pageText) / 2) + 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightBlue)
    term.setCursorPos(pageTextX, h)
    term.write(pageText)

    term.setBackgroundColor(nextColor)
    term.setTextColor(colors.black)
    term.setCursorPos(w - #pageBar.nextText + 1, h)
    term.write(pageBar.nextText)

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
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
-- 根据当前页面索引渲染列表并构建点击映射
local function readerData()
    local lineMapLocal = {}
    local row = 1
    stopIndex = {}

    term.clear()
    term.setCursorPos(1, 1)

    for pageIndex = startIndex[1], #dataCache do
        local page = dataCache[pageIndex]
        if not page then break end

        local fromItem = pageIndex == startIndex[1] and startIndex[2] or 1
        for itemIndex = fromItem, #page do
            if row >= h then break end

            local cell = page[itemIndex]
            term.setCursorPos(1, row)
            term.setTextColor(statusColor[cell.status] or colors.red)

            local maxNameLen = w - 4
            if #cell.name > maxNameLen then
                term.write(string.sub(cell.name, 1, maxNameLen - 3) .. "...")
            else
                term.write(cell.name)
            end

            local buttonColor = clickedButtons[cell.tag]
                and colors.lightBlue
                or (cell.status > 2 and colors.blue or colors.gray)
            term.setTextColor(colors.white)
            term.setBackgroundColor(buttonColor)
            term.setCursorPos(w - 2, row)
            term.write(" o ")
            term.setBackgroundColor(colors.black)


            lineMapLocal[row] = { pageIndex, itemIndex }
            stopIndex = { pageIndex, itemIndex }
            row = row + 1
        end

        if row >= h then break end
    end

    lineMap = lineMapLocal
    drawPageBar()
end

--- 网络Ping
-- 定期向服务器发送心跳包保持在线
local function netPingTask()
    while true do
        os.sleep(5)
        transmit({
            code = 193,
            mid = mid,
        })
    end
end

--- 事件处理
-- 监听终端、网络和鼠标事件并做出响应
local function eventTask()
    while true do
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "terminate" then -- 退出
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.setCursorPos(1, 1)
            term.clear()
            print("[1/2] Send client exit signal")
            modem.close(serverId)
            transmit({ code = 107, mid = mid })
            print("[1/2] The client has exited.")
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
            clickedButtons = {}
            dataCache = event[5].data.data
            readerData()
        elseif eventName == "mouse_click" and event[2] == 1 and event[4] ~= h then -- 单元切换事件
            local clickX = event[3]
            local clickY = event[4]
            local prevEndX = #pageBar.prevText
            local nextStartX = w - #pageBar.nextText + 1

            if clickY == h and clickX <= prevEndX and moveStartBackward() then
                readerData()
            elseif clickY == h and clickX >= nextStartX and moveStartForward() then
                readerData()
            elseif clickY < h and lineMap[clickY] then
                local index = lineMap[clickY]
                local cell = dataCache[index[1]][index[2]]
                if cell.status > 2 and cell.status < 6 and not clickedButtons[cell.tag] then
                    clickedButtons[cell.tag] = true
                    transmit({
                        tag = cell.tag,
                        code = 200,
                        mid = cell.tag .. os.epoch("utc")
                    })
                    readerData()
                end
            end
        end
    end
end

-- 初始化
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.setCursorPos(1, 1)
term.clear()
print("[1/2] Trying to connect to the server")

parallel.waitForAny(function()
    modem.open(serverId)
    transmit({
        code = 105,
        mid = "EventReportServer",
        data = { clientId = "pocket_" .. os.getComputerID() },
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
            and data.data.clientId == "pocket_" .. os.getComputerID()
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
print("[2/2] Waiting for server data")

parallel.waitForAny(eventTask, netPingTask)
