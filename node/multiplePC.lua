--- 静态配置
--- @type { tag:string, input:number, serverId:number, childInId:number, childOutId:number }
local staticCfg = {}

--- 外部事件映射表
--- @type table<string,function>
local eventMap = {}

--- 执行告警控制事件 (由 user.lua 提供)
--- @type fun(runData:table, tag:string, status:boolean)
local doTrigger = function() end

--- 侧面映射表
local SIDES = { "bottom", "top", "back", "front", "right", "left" }

--- 子机无响应多少次后视为离线
local CHILD_OFFLINE_LIMIT = 6

-- 运行时数据
local runData = settings.get("unit.rundata") or {}
-- 硬禁用状态
local hardDisabled = false
-- 子机未应答计数
local pcNAKCount = 0

--- 获取无线调制解调器
local function findWirelessModem()
    for _, v in ipairs({ peripheral.find("modem") }) do
        if v.isWireless() then return v end
    end
    error("Unable to get the wireless modem instance", 2)
end

local modem = findWirelessModem()
local graph = peripheral.find("monitor")

-- 与子机通讯的有线调制解调器 (必须使用有线调制解调器才能定向发送)
local localModem = peripheral.wrap("top")
if type(localModem) ~= "table" or type(localModem.isWireless) ~= "function" then
    error("The modem used to talk to the child computer must be placed on 'top'", 2)
end
if localModem.isWireless() then
    error("The modem on 'top' must be a wired modem, not a wireless one", 2)
end

local pc = peripheral.find("computer")
if type(pc) ~= "table" then error("No child computer detected", 2) end

--- 保存配置到磁盘
local function saveConfig()
    settings.set("unit.rundata", runData)
    settings.save()
end

--- 读取硬禁用输入
local function readHardDisabled()
    local side = SIDES[staticCfg.input]
    if not side then return false end
    return redstone.getInput(side) == true
end

--- 向子机下发当前状态
local function pushChildState()
    localModem.transmit(staticCfg.childInId, staticCfg.childInId, {
        running = runData.status,
        disabled = runData.disabled or hardDisabled,
    })
end

--- 发送ACK包
--- @param isPing? boolean 是否为ping包
--- @param mid? string 目标消息ID
local function sendACK(isPing, mid)
    if not modem then return end
    local statusId = runData.status and 4 or 3
    local disabled = runData.disabled or hardDisabled
    modem.transmit(staticCfg.serverId, staticCfg.serverId, {
        code = isPing and 193 or 103,
        mid = isPing and runData.mid or mid,
        data = { status = disabled and 2 or statusId }
    })
end

--- 显示当前状态与子机输出
local function showStatus()
    -- 保存数据
    saveConfig()
    -- 执行切换
    pushChildState()
    -- 渲染到显示屏
    if not graph then return end
    local color = runData.status and colors.green or colors.yellow
    graph.setBackgroundColor(runData.disabled and colors.lightGray or color)
    graph.clear()
end

--- 触发用户自定义事件钩子
local function fireHook(eventName, event)
    local hook = eventMap[eventName]
    if type(hook) == "function" then
        hook(runData, event)
    end
end

--- 处理子机侧消息
--- @param message any 消息体
local function handleChildMessage(message)
    if type(message) == "table" then
        if message.ACK then
            pcNAKCount = 0
        else
            pcNAKCount = pcNAKCount + 1
        end
    elseif message == "init" then
        -- 子机刚启动, 立即同步一次状态
        pushChildState()
    end
end

--- 处理主机侧网络指令
--- @param payload table 消息体
--- @param event table 原始事件
local function handleServerMessage(payload, event)
    local needSave = false
    local code = payload.code

    if code == 100 then -- 主机上线
        runData.serverOnline = true
        needSave = true
    elseif code == 101 then -- 主机离线
        runData.serverOnline = false
        needSave = true
    elseif code == 102 then -- 主机同步mid表
        local idMap = type(payload.data) == "table" and payload.data or {}
        local newId = idMap[staticCfg.tag]
        if newId then
            runData.serverOnline = true
            runData.mid = newId
            needSave = true
        end
    elseif code == 200 then -- 主机切换状态信号
        if payload.tag == staticCfg.tag or payload.tag == "ALL" then
            runData.status = not runData.status
            showStatus()
            sendACK(false, payload.mid)
        end
    elseif code == 201 then -- 主机指定状态信号
        if payload.tag == staticCfg.tag then
            if type(payload.data) ~= "table" then
                modem.transmit(staticCfg.serverId, staticCfg.serverId, { code = 104, mid = payload.mid })
                return
            end
            local newStatus = not not payload.data.status
            if newStatus ~= runData.status then
                runData.status = newStatus
                showStatus()
            end
            sendACK(false, payload.mid)
        end
    elseif code == 202 then -- 主机禁用状态请求
        if payload.tag == staticCfg.tag or payload.tag == "ALL" then
            if hardDisabled then
                -- 硬禁用激活: 拦截所有软控制指令返回 NCK 104
                modem.transmit(staticCfg.serverId, staticCfg.serverId, { code = 104, mid = payload.mid })
            else
                local target = type(payload.data) == "table" and not not payload.data.status or false
                if runData.disabled ~= target then
                    runData.disabled = target
                    pushChildState()
                end
                -- 发送 ACK 确认
                sendACK(false, payload.mid)
            end
        end
    elseif code == 203 then -- 主机单元告警状态触发
        if payload.tag == staticCfg.tag and type(payload.data) == "table" then
            doTrigger(runData, payload.data.tag, payload.data.status)
        end
    else
        fireHook("modem_message", event)
    end

    if needSave then saveConfig() end
end

--- 事件处理循环
local function eventJob()
    while true do
        local event = { os.pullEvent() }
        local eventName = event[1]

        if eventName == "monitor_touch" then
            runData.status = not runData.status
            showStatus()
        elseif eventName == "modem_message" then
            if event[4] == staticCfg.childOutId then -- 子机信息
                handleChildMessage(event[5])
            elseif event[4] == staticCfg.serverId then -- 主机信息
                if type(event[5]) == "table" then
                    handleServerMessage(event[5], event)
                end
            end
        elseif eventName == "redstone" and SIDES[staticCfg.input] then
            local newHard = readHardDisabled()
            if newHard ~= hardDisabled then
                hardDisabled = newHard
                showStatus()
            end
        else
            fireHook(eventName, event)
        end
    end
end

--- 定时器循环
local function timerJob()
    while true do
        os.sleep(5)
        pcNAKCount = pcNAKCount + 1
        localModem.transmit(staticCfg.childInId, staticCfg.childInId, "ping")
        if runData.serverOnline then
            sendACK(true)
        end
        if pcNAKCount > CHILD_OFFLINE_LIMIT then
            -- 子机长时间无应答, 仅提示一次
            if pcNAKCount == CHILD_OFFLINE_LIMIT + 1 then
                printError("Child computer is not responding!")
            end
        end
    end
end

--- 校验并生成运行时配置
local function configCheck()
    -- 加载用户脚本
    local ok, userdata = pcall(require, "user")
    if not ok then error("User script load error: " .. tostring(userdata), 2) end

    -- 基础配置段
    if type(userdata.staticCfg) ~= "table" then
        error("User script format error: 'staticCfg' not a table!", 2)
    end
    staticCfg = userdata.staticCfg

    -- 告警处理函数
    if type(userdata.doTrigger) == "function" then
        doTrigger = userdata.doTrigger
    end
    -- 额外事件配置
    if type(userdata.eventMap) == "table" then
        eventMap = userdata.eventMap
    end

    -- 静态配置校验
    if type(staticCfg.tag) ~= "string" or staticCfg.tag == "" then
        error("Tag configuration error", 2)
    end
    if type(staticCfg.serverId) ~= "number" or staticCfg.serverId < 0 or staticCfg.serverId > 65535 then
        error("ServerId configuration error", 2)
    end
    for _, key in ipairs({ "childInId", "childOutId" }) do
        local value = staticCfg[key]
        if type(value) ~= "number" or value < 0 or value > 65535 then
            error(key .. " configuration error", 2)
        end
    end
    if staticCfg.input ~= nil and (type(staticCfg.input) ~= "number" or not SIDES[staticCfg.input]) then
        error("Input side configuration error", 2)
    end

    -- 运行时配置校验
    runData.disabled = not not runData.disabled
    runData.serverOnline = not not runData.serverOnline
    runData.status = not not runData.status

    -- 硬件禁用逻辑
    hardDisabled = readHardDisabled()

    -- 配置输出
    print("Cell tag: " .. staticCfg.tag)
    print("Server ID: " .. staticCfg.serverId)
    print("Input side: " .. tostring(SIDES[staticCfg.input]))
    print("Child in: " .. staticCfg.childInId)
    print("Child out: " .. staticCfg.childOutId)
    term.setTextColor(colors.lightBlue)
    print("Computer ID: " .. os.getComputerID())
    term.setTextColor(colors.white)
end

-- 预启动
configCheck()
modem.open(staticCfg.serverId)
localModem.open(staticCfg.childOutId)
if not pc.isOn() then
    pc.turnOn()
    os.sleep(1)
end
showStatus()

-- 启动并发
parallel.waitForAny(eventJob, timerJob)
