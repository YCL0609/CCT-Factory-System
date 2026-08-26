local runData = settings.get("unit.rundata") or {}
local monitors = { peripheral.find("monitor") }

--- 静态配置
--- @type {
---  tag: string,
---  input: number,
---  output: number,
---  serverId: number,
--- }
local staticCfg = {}

--- 外部事件映射表
--- @type table<string,function>
local eventMap = {}

--- 执行状态切换函数
--- @type fun(runData:table, side: string, hardDisabled:boolean)
local doControl = function() end

--- 执行恢复逻辑函数
--- @type fun(runData:table, side: string)
local doRecovery = function() end

--- 执行告警控制事件
--- @type fun(runData:table, tag: string, status: boolean)
local doTrigger = function() end

-- 硬禁用
local hardDisabled = false

-- 初始化无线调制解调器
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

-- 主机侧面映射
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
    local statusId = runData.status and 4 or 3
    local disabled = runData.disabled or hardDisabled
    modem.transmit(staticCfg.serverId, staticCfg.serverId, {
        code = isPing and 193 or 103,
        mid = isPing and runData.mid or mid,
        data = { status = disabled and 2 or statusId }
    })
end

--- 显示当前状态与红石输出
local function showStatus()
    -- 保存数据
    saveConfig()
    -- 执行切换
    doControl(runData, sideMap[staticCfg.output], hardDisabled)
    -- 渲染到显示屏
    if #monitors == 0 then return end
    local disabled = runData.disabled or hardDisabled
    local basicColor = runData.status and colors.green or colors.yellow
    local finalColor = disabled and colors.lightGray or basicColor
    for _, m in ipairs(monitors) do
        m.setBackgroundColor(finalColor)
        m.clear()
    end
end

--- 事件处理循环
local function eventJob()
    while true do
        local event = { os.pullEvent() }
        local eventName = event[1]

        if eventName == "monitor_touch" then
            runData.status = not runData.status
            showStatus()
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
                if payload.tag == staticCfg.tag then
                    runData.status = not runData.status
                    showStatus()
                    sendACK(false, payload.mid)
                end
            elseif payload.code == 201 then -- 主机指定状态信号
                if payload.tag == staticCfg.tag then
                    local newStatus = not not payload.data.status
                    if newStatus ~= runData.status then
                        runData.status = newStatus
                        showStatus()
                    end
                    sendACK(false, payload.mid)
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
            -- 仅当红石输入实际发生改变时才触发更新
            if runData.disabled ~= hardDisabled then
                runData.disabled = hardDisabled
                showStatus()
            end
        elseif type(eventMap["modem_message"]) == "function" then -- 自定义函数调用
            eventMap["modem_message"](runData, event)
        end
    end
end

--- 定时器循环
local function timerJob()
    while true do
        os.sleep(5)
        if runData.serverOnline then
            sendACK(true)
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
    runData.disabled = sideMap[staticCfg.input] and redstone.getInput(sideMap[staticCfg.input]) or false
    runData.serverOnline = not not runData.serverOnline
    runData.status = not not runData.status
    if type(staticCfg.output) ~= "number" or staticCfg.output < 1 or staticCfg.output > 6 then
        error("Output side configuration error", 2)
    end

    -- 硬件禁用逻辑
    hardDisabled = sideMap[staticCfg.input] and redstone.getInput(sideMap[staticCfg.input]) or false

    -- 配置输出
    print("Cell tag: " .. staticCfg.tag)
    print("Server ID: " .. staticCfg.serverId)
    print("Input side: " .. sideMap[staticCfg.input])
    print("Output side: " .. sideMap[staticCfg.output])
    term.setTextColor(colors.lightBlue)
    print("Computer ID: " .. os.getComputerID())
    term.setTextColor(colors.white)
end

-- 预启动
configGen()
modem.open(staticCfg.serverId)
doRecovery(runData, sideMap[staticCfg.output])
showStatus()

-- 启动并发
parallel.waitForAny(eventJob, timerJob)
