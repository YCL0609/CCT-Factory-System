local runData = settings.get("unit.rundata") or {}
local monitors = { peripheral.find("monitor") }

--- 静态配置
--- @type {
---  tag: string,
---  input: number,
---  waitTime: number,
---  serverId: number,
--- }
local staticCfg = {}

--- 外部事件映射表
--- @type table<string,function>
local eventMap = {}

--- 执行状态切换函数
--- @type fun(runData:table, hardDisabled:boolean)
local doControl = function() end

--- 执行恢复逻辑函数
--- @type fun(runData:table)
local doRecovery = function() end

-- 初始化默认外设
local modem
for _, v in ipairs({ peripheral.find("modem") }) do
    if v.isWireless() then
        modem = v
        break
    end
end
if not modem then
    error("Unable to get the wireless modem instance", 2)
end

--- 执行告警控制事件
--- @type fun(runData:table, tag: string, status: boolean)
local doTrigger = function() end

-- 硬禁用
local hardDisabled = false

-- 侧面映射
local sideMap = {
    [1] = "bottom",
    [2] = "top",
    [3] = "back",
    [4] = "front",
    [5] = "right",
    [6] = "left"
}

--- 保存配置到磁盘
local function saveConfig()
    settings.set("unit.rundata", runData)
    settings.save()
end

--- 发送ACK包
--- @param isPing? boolean 是否为ping包
--- @param mid? any 是否为ping包
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

--- 执行工作循环
local function doJob()
    while true do
        os.pullEvent("doJob")

        if not (runData.status or runData.disabled or hardDisabled) then
            runData.status = true
            showStatus()
            doControl(runData, hardDisabled)
            runData.status = false
            showStatus()
        end
    end
end

--- 事件处理循环
local function eventJob()
    while true do
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "monitor_touch" and not runData.status then
            os.queueEvent("doJob")
        elseif eventName == "modem_message" and event[4] == staticCfg.serverId and type(event[5]) == "table" then
            local payload = event[5]
            local needSave = false

            if payload.code == 100 then -- 主机上线
                runData.serverOnline = true
                needSave = true
            elseif payload.code == 101 then -- 主机离线
                runData.serverOnline = false
                needSave = true
            elseif payload.code == 102 then -- 主机同步mid表
                local idMap = type(payload.data) == "table" and payload.data or {}
                local newId = idMap[staticCfg.tag]
                if newId then
                    runData.serverOnline = true
                    runData.mid = newId
                    needSave = true
                end
            elseif payload.code == 200 then -- 主机切换状态信号
                if payload.tag == staticCfg.tag or payload.tag == "ALL" then
                    if not runData.status then
                        os.queueEvent("doJob")
                    end
                    sendACK(false, payload.mid)
                end
            elseif payload.code == 201 then -- 主机状态指定请求
                if payload.tag == staticCfg.tag then
                    -- 发送 NCK 包，计时器任务不允许 201 状态码
                    modem.transmit(staticCfg.serverId, staticCfg.serverId, {
                        code = 104,
                        mid = payload.mid,
                    })
                end
            elseif payload.code == 202 then -- 主机禁用状态请求
                if payload.tag == staticCfg.tag or payload.tag == "ALL" then
                    if hardDisabled then
                        -- 硬禁用激活: 拦截所有软控制指令返回 NCK 104
                        modem.transmit(staticCfg.serverId, staticCfg.serverId, {
                            code = 104,
                            mid = payload.mid,
                        })
                    else
                        if runData.disabled ~= payload.data.status then
                            runData.disabled = payload.data.status
                        end
                        -- 发送 ACK 确认
                        sendACK(false, payload.mid)
                    end
                end
            elseif payload.code == 203 then -- 主机单元告警状态触发
                if payload.tag == staticCfg.tag then
                    doTrigger(runData, payload.data.tag, payload.data.status)
                end
            elseif type(eventMap["modem_message"]) == "function" then -- 自定义函数调用
                eventMap["modem_message"](runData, event)
            end

            if needSave then saveConfig() end
        elseif eventName == "redstone" and sideMap[staticCfg.input] then
            hardDisabled = sideMap[staticCfg.input] and redstone.getInput(sideMap[staticCfg.input]) or false
            if hardDisabled ~= hardDisabled then
                hardDisabled = hardDisabled
                showStatus()
            end
        elseif type(eventMap["modem_message"]) == "function" then -- 自定义函数调用
            eventMap["modem_message"](runData, event)
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
                if not runData.status then
                    os.queueEvent("doJob")
                end
            end
        end
    end
end

--- 配置校验与初始化
local function configGen()
    -- 加载用户脚本
    local ok, userdata = pcall(require, "user")
    if not ok then error("User script load error!", 2) end
    -- 基础配置段
    if type(userdata.staticCfg) == "table" then
        staticCfg = userdata.staticCfg
    else
        error("User script format error: 'staticCfg' not a table!", 2)
    end
    -- 控制函数
    if type(userdata.doControl) == "function" then
        doControl = userdata.doControl
    else
        error("User script format error 'doControl' not a function!", 2)
    end
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

    -- 运行时配置校验
    runData.disabled = not not runData.disabled
    runData.serverOnline = not not runData.serverOnline
    runData.status = not not runData.status
    if type(runData.passedMin) ~= "number" or runData.passedMin < 0 then
        runData.passedMin = 0
    end

    -- 硬件禁用逻辑
    hardDisabled = sideMap[staticCfg.input] and redstone.getInput(sideMap[staticCfg.input]) or false

    -- 配置输出
    print("Cell tag: " .. staticCfg.tag)
    print("Server ID: " .. staticCfg.serverId)
    print("Input side: " .. sideMap[staticCfg.input])
    print("Interval: " .. staticCfg.waitTime)
    term.setTextColor(colors.lightBlue)
    print("Computer ID: " .. os.getComputerID())
    term.setTextColor(colors.white)
end

-- 预启动
configGen()
modem.open(staticCfg.serverId)
if runData.status then
    runData.status = false
    doRecovery(runData)
end
showStatus()

-- 开启多线程并行
parallel.waitForAny(eventJob, timerJob, doJob)
