local modem = peripheral.find("modem")
assert(modem, "modem peripheral not found")
local serverId = settings.get("factoryhub.serverId")
if type(serverId) ~= "number" or serverId < 0 or serverId > 65535 then
    printError("ServerId settings is wrong or not set.")
    print("Use 'set factoryhub.serverId <id>' in shell to set it.")
    error()
end
local w, h = term.getSize()
local startIndex = 1
local clickedButtons = {}
local dataCache = {}
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

local pageSize = math.max(1, h - 1)

-- 是否还有下一页
local function hasNext()
    return startIndex + pageSize < #dataCache
end

-- 绘制分页控制栏
local function drawPageBar()
    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.black)
    term.clearLine()

    local total = #dataCache
    local stopIndex = startIndex + pageSize
    local prevColor = startIndex > 1 and colors.cyan or colors.lightGray
    local nextColor = stopIndex < total and colors.cyan or colors.lightGray

    term.setBackgroundColor(prevColor)
    term.setTextColor(colors.black)
    term.write(pageBar.prevText)

    local pageText = string.format("%d - %d", startIndex, math.min(stopIndex, total))
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
    if startIndex <= 1 then return false end
    startIndex = math.max(1, startIndex - pageSize)
    return true
end

-- 将视图向前翻页
local function moveStartForward()
    if not hasNext() then return false end
    startIndex = startIndex + pageSize
    return true
end

--- 渲染数据
local function readerData()
    local lineMapLocal = {}
    local row = 1
    local maxRow = math.min(h - 1, #dataCache)
    local endIndex = math.min(startIndex + pageSize - 1, #dataCache)

    term.clear()
    term.setCursorPos(1, 1)

    for itemIndex = startIndex, endIndex do
        local cell = dataCache[itemIndex]
        if not cell then break end
        if row > maxRow then break end

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

        lineMapLocal[row] = itemIndex
        row = row + 1
    end

    lineMap = lineMapLocal
    drawPageBar()
end

--- 网络Ping
local function netPingTask()
    while true do
        os.sleep(5)
        modem.transmit(serverId, serverId, {
            code = 193,
            mid = mid,
        })
    end
end

--- 事件处理
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
            modem.transmit(serverId, serverId, { code = 107, mid = mid })
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
        elseif eventName == "mouse_click" and event[2] == 1 then -- 单元切换事件
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
                local cell = dataCache[index]
                if cell and cell.status > 2 and cell.status < 6 and not clickedButtons[cell.tag] then
                    clickedButtons[cell.tag] = true
                    modem.transmit(serverId, serverId, {
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
    modem.transmit(serverId, serverId, {
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
