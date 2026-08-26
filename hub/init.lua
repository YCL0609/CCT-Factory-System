local TaskQueue = require("./lib.TaskQueue")
local miniNet   = require("./lib.MiniNet")
local loadJson  = require("./lib.loadJson")
local log       = require("./lib.log")

--- @class initSettings
--- @field noNet boolean 是否禁用网络
--- @field noLog boolean 是否禁用日志输出
--- @field noTimer boolean 是否禁用轮询事件
--- @field noReboot boolean 是否阻止系统重启
--- @field debugMode number 调试模式二进制码
--- @field timerInterval number 每次轮询的间隔时间 (默认: 5s)
--- @field disabledUnits table<string,boolean> 已禁用的单元列表

--- 主初始化类
--- @class init
--- @field _module table 各模块实例存放表
--- @field _event table 事件映射表
--- @field _settings initSettings 实例配置表
--- @field _libnet MiniNet 网络库实例
--- @field _liblog Log 日志库实例
local init      = {}
init.__index    = init

--- 初始化模块
--- @param initCfg? table 可选设置选项
--- @return init
function init:new(initCfg)
    local startTime = os.epoch("utc")
    initCfg = type(initCfg) == "table" and initCfg or {}

    -- 清理屏幕
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, 1)
    term.clear()

    -- 调试模式初始化
    local LogObj = {}
    local debugMode = 0
    local rawMode = tonumber(initCfg.debugMode) or 0
    if bit32.btest(rawMode, self.DEBUGMASK[0]) then
        -- 调试模式忽略noLog信号
        debugMode = bit32.band(rawMode, 0xFF)
        LogObj = log:new(0)

        -- 格式化为二进制输出
        local bits = {}
        for i = 7, 0, -1 do
            table.insert(bits, bit32.extract(debugMode, i, 1))
        end
        LogObj:debug("Debug Mode", table.concat(bits))
    else
        debugMode = 0
        LogObj = log:new(noLog and 9 or 1)
    end

    -- 配置解析
    local settings = { debugMode = debugMode }
    settings.noTerminate = not not initCfg.noTerminate -- 忽略终止事件
    settings.noReboot = not not initCfg.noReboot       -- 阻止系统重启
    settings.noTimer = not not initCfg.noTimer         -- 计时器禁用配置
    settings.noLog = not not initCfg.noLog             -- 日志禁用设置
    -- 轮询间隔配置
    if type(initCfg.timerInterval) == "number" and initCfg.timerInterval > 0 then
        settings.timerInterval = math.floor(initCfg.timerInterval)
        if settings.timerInterval < 2 then
            LogObj:fatal(
                "Polling intervals that are too short may cause performance issues, the system refuses to start.")
        elseif settings.timerInterval < 4 then
            LogObj:warn("Polling events too frequently might cause performance issues.")
        elseif settings.timerInterval > 600 then
            LogObj:warn("Polling intervals that are too long could cause some delays.")
        end
    else
        settings.timerInterval = 5
    end
    -- 禁用功能映射
    settings.disabledUnits = {}
    if type(initCfg.disabledUnits) == "table" and #initCfg.disabledUnits ~= 0 then
        for _, v in ipairs(initCfg.disabledUnits) do
            settings.disabledUnits[tostring(v) .. ".lua"] = true
        end
    end

    -- 目录检查
    for _, dir in ipairs({ "./bin", "./etc" }) do
        if fs.exists(dir) then
            -- 不是目录
            if not fs.isDir(dir) then
                LogObj:fatal("'" .. dir .. "' exists but is not a directory!")
            end
        else
            -- 尝试创建
            local ok, err = pcall(fs.makeDir, dir)
            if not ok then
                LogObj:fatal("Failed to create " .. dir .. " directory: ", err)
            end
        end
    end

    -- 创建对象
    local obj = setmetatable({
        _module = {},
        _liblog = LogObj,
        _libnet = miniNet:new(initCfg.netName),
        _settings = settings,
        _event = {
            modem_message = true,
            monitor_touch = {},
            poll = {},
        },
    }, self)

    -- 遍历处理lua文件
    local loadStartTime = os.epoch("utc")
    local files = fs.list("./bin")
    for _, nameRaw in ipairs(files) do
        if nameRaw:lower():sub(-4) == ".lua" and not obj._settings.disabledUnits[nameRaw] then
            obj:_loadModules(nameRaw:sub(0, -5))
        end
    end
    local loadTime = os.epoch("utc") - loadStartTime

    -- 后处理配置
    if #obj._event.poll == 0 then obj._settings.noTimer = true end -- poll事件列表为空时禁用轮询计时器
    if bit32.btest(settings.debugMode, obj.DEBUGMASK[4]) then
        -- 网络事件列表为空或调试位被设置时禁用网络
        obj._settings.noNet = true
    elseif type(initCfg.netChannel) == "number" and initCfg.netChannel >= 0 and initCfg.netChannel <= 65535 then
        -- 列表不为空时尝试读取并设置传入的网络信道
        obj._settings.noNet = false
        obj._libnet:open(initCfg.netChannel)
    else
        -- 默认使用计算机自身的网络信道
        obj._settings.noNet = false
        obj._libnet:open(os.getComputerID())
    end
    -- 调试shell开启时将自身挂载到全局
    if bit32.btest(settings.debugMode, obj.DEBUGMASK[1]) then
        _G.HubObj = obj
    end

    -- 输出日志
    LogObj:info("System initialization complete: total used time",
        os.epoch("utc") - startTime,
        "ms, module loading time",
        loadTime, "ms"
    )

    return obj
end

-- 调试模式各位置掩码
init.DEBUGMASK = {
    [0]  = 0x01,   -- 低位第0位, 是否开启调试模式
    [1]  = 0x02,   -- 低位第1位, 启动调试shell
    [2]  = 0x04,   -- 低位第2位, 强制禁用事件处理
    [3]  = 0x08,   -- 低位第3位, 强制禁用屏幕点击事件
    [4]  = 0x10,   -- 低位第4位, 强制禁用网络事件
    [5]  = 0x20,   -- 低位第5位，强制禁用自定义事件
    [6]  = 0x40,   -- 低位第6位, 强制禁用重启逻辑
    [7]  = 0x80,   -- 低位第7位, 强制禁用退出时清理屏幕
    [8]  = 0x0100, -- 高位第0位, 将事件队列挂载到全局
    [9]  = 0x0200, -- 高位第1位, 主循环正常终止时挂起
    [10] = 0x0400, -- 高位第2位, 退出时不清理屏幕
    [11] = 0x0800, -- 高位第3位, 退出时不关闭网络连接
    [12] = 0x1000,
    [13] = 0x2000,
    [14] = 0x4000,
    [15] = 0x8000,
}
--- 错误信息id映射表
init.ERRORTEXT = {
    [1] = "Module '%s' failed to load: %s",
    [2] = "Module '%s' failed to initialize: %s",
    [3] = "Failed to get module '%s' event information: %s",
    [4] = "Module '%s' event configuration '%s' module error!",
}

--- 加载模块
--- @param name string 要加载的模块名称
function init:_loadModules(name)
    if not name or type(name) ~= "string" then return end
    local startTime = os.epoch("utc")

    -- 报错辅助函数
    local function doError(id, ...)
        local txt = string.format(self.ERRORTEXT[id] or "Unknown", ...)
        self._liblog:fatal(txt)
    end

    -- 加载模块
    local ok0, module = pcall(require, "./bin/" .. name)
    if not ok0 then doError(1, name, module) end

    -- 初始化模块并向模块new()函数传入两个参数
    --   * config <table> 若 /etc 文件夹中存在同名json文件则传入解析后的配置表，若不存在则传入空表
    --   * libs {MiniNet, Log} 已在主程序初始化的MiniNet网络库和Log日志实例
    --   * debugMode <number> 调试模式二进制码
    local ok1, obj = pcall(
        module.new,
        module,
        loadJson("./etc/" .. name .. ".json"),
        {
            net = self._libnet,
            log = self._liblog
        },
        self._settings.debugMode
    )
    if not ok1 then doError(2, name, obj) end

    -- 获取模块配置
    local ok2, cfg = pcall(obj.getEventList, obj)
    if not ok2 or type(cfg) ~= "table" then
        doError(3, name, cfg)
    end

    -- 处理轮询事件请求
    if cfg.poll then
        table.insert(self._event.poll, name)
    end

    -- 屏幕点击事件请求
    if cfg.monitor then
        if type(cfg.monitorName) ~= "string" then
            doError(4, name, "monitor")
        end
        self._event.monitor_touch[cfg.monitorName] = name
    end

    -- 其他事件请求
    if type(cfg.other) == "table" then
        for _, v in ipairs(cfg.other) do
            if type(v) == "string" then
                if not self._event[v] then
                    self._event[v] = {}
                end
                table.insert(self._event[v], name)
            end
        end
    end

    self._module[name] = obj
    self._liblog:debug("Module", name, "loaded in", os.epoch("utc") - startTime, "ms")
end

--- 清理并退出
function init:_exitClean()
    self._liblog:info("System shutting down ...")

    -- 关闭无线连接
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[11]) then
        -- 高位第2位, 退出时不清理屏幕
        self._liblog:debug("Screen cleaning has been blocked!")
    else
        self._libnet:close()
    end

    -- 清理屏幕
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[10]) then
        -- 高位第2位, 退出时不清理屏幕
        self._liblog:debug("Screen cleaning has been blocked!")
    else
        for _, monitor in ipairs({ peripheral.find("monitor") }) do
            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.white)
            monitor.clear()
        end
    end
end

--- 启动主循环
function init:doMainLoop()
    -- 是否处于关闭流程中
    local inClose = false
    -- 初始化任务队列
    local eventQueue = TaskQueue:new()

    -- 高位第0位, 将事件队列挂载到全局
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[8]) then
        _G.HubeventQueue = eventQueue
        self._liblog:debug("The event queue has been mounted to global at _G.HubeventQueue")
    end
    -- 低位第3位，强制禁用屏幕点击事件
    local noMonitor = bit32.btest(self._settings.debugMode, self.DEBUGMASK[3])
    -- 低位第5位，强制禁用自定义事件
    local noOtherEvent = bit32.btest(self._settings.debugMode, self.DEBUGMASK[5])

    -- 将任务推入队列
    local function monitor()
        while true do
            local event = { os.pullEventRaw() }
            if inClose then
                break
            elseif self._event[event[1]] then
                eventQueue:push(event)
                os.queueEvent("newTask")
            elseif event[1] == "terminate" and not self._settings.noTerminate then
                inClose = true
                self:_exitClean()
                -- 高位第1位, 主循环正常终止时挂起
                if bit32.btest(self._settings.debugMode, self.DEBUGMASK[9]) then
                    break
                end
                return
            elseif event[1] == "reboot" then
                inClose = true
                self:_exitClean()
                if
                    self._settings.noReboot
                    or bit32.btest(self._settings.debugMode, self.DEBUGMASK[9]) -- 高位第1位, 主循环正常终止时挂起
                then
                    break
                end
                os.reboot()
            end
        end

        while true do os.pullEvent("Imashino Misaki") end -- 监听不存在的事件来无限等待
    end

    -- 任务处理函数
    local function handler()
        -- 低位第2位, 强制禁用事件处理
        if bit32.btest(self._settings.debugMode, self.DEBUGMASK[2]) then
            self._liblog:debug("The main event handling loop has been disabled")
        else
            -- 错误事件计数
            local errEventCount = 0

            while true do
                os.pullEvent("newTask")
                if inClose then break end

                -- 损坏事件检测
                if errEventCount > 10 then
                    inClose = true
                    self._liblog:fatal("Event damage threshold exceeded (", errEventCount,
                        "> 10 ), The system is unstable and has been forced to shut down ...")
                end

                -- 轮询取任务并生成事件函数集合
                local tasks = {}
                while not eventQueue:isEmpty() do
                    local event = eventQueue:pop() or {}
                    if type(event) == "table" then
                        if event[1] == "poll" and not self._settings.noTimer then -- 轮询事件
                            self._libnet:poll()
                            for _, module in ipairs(self._event.poll) do
                                tasks[#tasks + 1] = function()
                                    return self._module[module]:poll()
                                end
                            end
                        elseif event[1] == "monitor_touch" and not noMonitor then -- 屏幕点击事件
                            local handlerName = self._event.monitor_touch[event[2]]
                            if handlerName then
                                tasks[#tasks + 1] = function()
                                    return self._module[handlerName]:epoll(event)
                                end
                            end
                        elseif event[1] == "modem_message" and not self._settings.noNet then -- 网络事件
                            tasks[#tasks + 1] = function()
                                return self._libnet:epoll(event)
                            end
                        elseif self._event[event[1]] and not noOtherEvent then -- 其他事件
                            for _, name in ipairs(self._event[event[1]]) do
                                tasks[#tasks + 1] = function()
                                    return self._module[name]:epoll(event)
                                end
                            end
                        end
                    else
                        -- 事件格式错误
                        errEventCount = errEventCount + 1
                        self._liblog:error(
                            "Got a corrupted event from the state queue, skipping processing this broken event!")
                    end
                end

                -- 并行运行所有处理函数
                if #tasks ~= 0 then parallel.waitForAll(table.unpack(tasks)) end
            end
        end

        while true do os.pullEvent("Sumi Serina") end -- 监听不存在的事件来无限等待
    end

    -- 计时器函数
    local function timmer()
        if self._settings.noTimer then
            self._liblog:info("The polling timer is disabled")
        else
            while true do
                os.sleep(self._settings.timerInterval)
                if inClose then break end
                os.queueEvent("poll")
            end
        end

        while true do os.pullEvent("Tendou Arisu") end -- 监听不存在的事件来无限等待
    end

    -- 调试shell函数
    local function debugShell()
        -- 若为调试模式则启动shell
        if bit32.btest(self._settings.debugMode, self.DEBUGMASK[1]) then
            self._liblog:debug("Launching debug shell in a new tab")
            shell.run("bg")
            self._liblog:debug("Debug shell terminated")
        end

        while true do os.pullEvent("Tendou Kei") end -- 监听不存在的事件来无限等待
    end

    return parallel.waitForAny(monitor, handler, timmer, debugShell)
end

return init
