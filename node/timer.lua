--- 静态配置
--- @type { tag:string, input:number, waitTime:number, serverId:number }
local staticCfg = {}

--- 外部事件映射表
--- @type table<string,function>
local eventMap = {}

--- 执行状态切换函数 (由 user.lua 提供)
--- @type fun(runData:table, hardDisabled:boolean)
local doControl = function() end

--- 执行恢复逻辑函数 (由 user.lua 提供)
--- @type fun(runData:table)
local doRecovery = function() end

--- 执行告警控制事件 (由 user.lua 提供)
--- @type fun(runData:table, tag:string, status:boolean)
local doTrigger = function() end

--- 侧面映射表
local SIDES = { "bottom", "top", "back", "front", "right", "left" }

-- 运行时数据
local runData = settings.get("unit.rundata") or {}
-- 硬禁用状态
local hardDisabled = false

--- 获取无线调制解调器
local function findWirelessModem()
    for _, v in ipairs({ peripheral.find("modem") }) do
        if v.isWireless() then return v end
    end
    error("Unable to get the wireless modem instance", 2)
end

local modem = findWirelessModem()
local monitors = { peripheral.find("monitor") }

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

--- 发送ACK包
--- @param isPing? boolean 是否为ping包
--- @param mid? string 目标消息ID
local function sendACK(isPing, mid)
    local statusId = runData.status and 4 or 5
    local disabled = runData.disabled or hardDisabled
    modem.transmit(staticCfg.serverId, staticCfg.serverId, {
        code = isPing and 193 or 103,
        mid = isPing and runData.mid or mid,
        data = { status = disabled and 2 or statusId }
    })
end

--- 工作状态刷新函数
local function showStatus()
    -- 保存数据
    saveConfig()
    -- 渲染到显示屏
    if #monitors == 0 then return end
    local disabled = runData.disabled or hardDisabled
    local basicColor = runData.status and colors.green or colors.lightBlue
    local finalColor = disabled and colors.lightGray or basicColor
    for _, m in ipairs(monitors) do
        m.setBackgroundColor(finalColor)
        m.clear()
    end
end

--- 触发用户自定义事件钩子
local function fireHook(eventName, event)
    local hook = eventMap[eventName]
    if type(hook) == "function" then
        hook(runData, event)
    end
end

--- 执行一次工作循环
local function runOnce()
    if runData.status or runData.disabled or hardDisabled then return end
    runData.status = true
    showStatus()
    doControl(runData, hardDisabled)
    runData.status = false
    showStatus()
end

--- 执行工作循环
local function doJob()
    while true do
        os.pullEvent("doJob")
        runOnce()
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
            os.queueEvent("doJob")
            sendACK(false, payload.mid)
        end
    elseif code == 201 then -- 主机状态指定请求 (计时器单元不支持, 返回 NCK)
        if payload.tag == staticCfg.tag then
            modem.transmit(staticCfg.serverId, staticCfg.serverId, { code = 104, mid = payload.mid })
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
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "monitor_touch" then
            if not runData.status and not hardDisabled and not runData.disabled then
                os.queueEvent("doJob")
            end
        elseif eventName == "modem_message" and event[4] == staticCfg.serverId and type(event[5]) == "table" then
            handleServerMessage(event[5], event)
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

--- 计时器函数
local function timerJob()
    local tickCount = 0

    while true do
        os.sleep(5)

        -- 心跳包
        if runData.serverOnline then
            sendACK(true)
        end

        -- 工作计时器
        tickCount = tickCount + 1
        if tickCount >= 12 then
            tickCount = 0
            runData.passedMin = (runData.passedMin or 0) + 1
            saveConfig()

            -- 时间计时器触发
            if runData.passedMin >= staticCfg.waitTime then
                runData.passedMin = 0
                saveConfig()
                os.queueEvent("doJob")
            end
        end
    end
end

--- 校验并生成运行时配置
local function configGen()
    -- 加载用户脚本
    local ok, userdata = pcall(require, "user")
    if not ok then error("User script load error: " .. tostring(userdata), 2) end

    -- 基础配置段
    if type(userdata.staticCfg) ~= "table" then
        error("User script format error: 'staticCfg' not a table!", 2)
    end
    staticCfg = userdata.staticCfg

    -- 控制函数
    if type(userdata.doControl) ~= "function" then
        error("User script format error 'doControl' not a function!", 2)
    end
    doControl = userdata.doControl

    -- 恢复函数
    if type(userdata.doRecovery) == "function" then
        doRecovery = userdata.doRecovery
    end
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
    if type(staticCfg.waitTime) ~= "number" or staticCfg.waitTime < 1 then
        error("WaitTime configuration error (must be >= 1 minute)", 2)
    end
    if staticCfg.input ~= nil and (type(staticCfg.input) ~= "number" or not SIDES[staticCfg.input]) then
        error("Input side configuration error", 2)
    end

    -- 运行时配置校验 (软禁用状态会跨重启保留)
    runData.disabled = not not runData.disabled
    runData.serverOnline = not not runData.serverOnline
    runData.status = not not runData.status
    if type(runData.passedMin) ~= "number" or runData.passedMin < 0 then
        runData.passedMin = 0
    end

    -- 硬件禁用逻辑
    hardDisabled = readHardDisabled()

    -- 配置输出
    print("Cell tag: " .. staticCfg.tag)
    print("Server ID: " .. staticCfg.serverId)
    print("Input side: " .. tostring(SIDES[staticCfg.input]))
    print("Interval: " .. staticCfg.waitTime)
    term.setTextColor(colors.lightBlue)
    print("Computer ID: " .. os.getComputerID())
    term.setTextColor(colors.white)
end

-- 预启动
configGen()
modem.open(staticCfg.serverId)
if runData.status then
    -- 上次运行被中断, 恢复现场
    runData.status = false
    doRecovery(runData)
end
showStatus()

-- 开启多线程并行
parallel.waitForAny(eventJob, timerJob, doJob)
