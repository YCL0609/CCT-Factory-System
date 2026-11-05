local TaskQueue    = require("lib.TaskQueue")
local MiniNet      = require("lib.MiniNet")
local loadJson     = require("lib.loadJson")
local Log          = require("lib.log")

--- @class initSettings
--- @field noNet boolean 是否禁用网络
--- @field noLog boolean 是否禁用日志输出
--- @field noTimer boolean 是否禁用轮询事件
--- @field noReboot boolean 是否阻止系统重启
--- @field debugMode number 调试模式二进制码
--- @field noTerminate boolean 是否忽略终止事件
--- @field timerInterval number 每次轮询的间隔时间 (默认: 5s)
--- @field disabledUnits table<string,boolean> 已禁用的单元列表
--- @field logFileSize number 单个日志文件最大字节数 (-1 不限制, 默认 100 KiB)
--- @field logFileCount number 日志文件总数, 含 .log (0 禁用文件输出, -1 不限制归档数量, 默认 3)

--- 主初始化类
--- @class init
--- @field _rootDir string 程序根目录
--- @field _module table 各模块实例存放表
--- @field _event table 事件映射表
--- @field _settings initSettings 实例配置表
--- @field _libnet MiniNet 网络库实例
--- @field _liblog Log 日志库实例
local init         = {}
init.__index       = init

--- 调试模式各位置掩码
init.DEBUGMASK     = {
    [0]  = 0x0001, -- 低位第0位, 是否开启调试模式
    [1]  = 0x0002, -- 低位第1位, 启动调试shell
    [2]  = 0x0004, -- 低位第2位, 强制禁用事件处理
    [3]  = 0x0008, -- 低位第3位, 强制禁用屏幕点击事件
    [4]  = 0x0010, -- 低位第4位, 强制禁用网络事件
    [5]  = 0x0020, -- 低位第5位, 强制禁用自定义事件
    [6]  = 0x0040, -- 低位第6位, 强制禁用重启逻辑
    [7]  = 0x0080, -- 低位第7位, 保留用于模块自定义
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
init.ERRORTEXT     = {
    [1] = "Module '%s' failed to load: %s",
    [2] = "Module '%s' failed to initialize: %s",
    [3] = "Failed to get module '%s' event information: %s",
    [4] = "Module '%s' event configuration '%s' module error!",
    [5] = "Module '%s' does not export a valid 'new' constructor!",
}

--- 不可注册事件保留表
init.RESERVEDEVENT = {
    terminate = true,
    reboot = true,
    poll = true,
    newTask = true,
    modem_message = true,
    monitor_touch = true,
}

--- 初始化模块
--- @param initCfg? table 可选设置选项
--- @return init
function init:new(initCfg)
    local startTime = os.epoch("utc")
    initCfg = type(initCfg) == "table" and initCfg or {}

    -- 清理屏幕
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clear()

    -- 调试模式初始化
    local rawMode = math.floor(tonumber(initCfg.debugMode) or 0)
    local debugEnabled = bit32.btest(rawMode, self.DEBUGMASK[0]) or bit32.btest(rawMode, self.DEBUGMASK[1])
    local debugMode = debugEnabled and bit32.band(rawMode, 0xFFFF) or 0

    -- 计算程序根目录 (日志目录依赖此项, 需在创建 Logger 之前确定)
    local rootDir = ""
    do
        local ok, program = pcall(shell.getRunningProgram)
        if ok and type(program) == "string" then
            local dir = fs.getDir(program)
            if dir == "/" or dir == "." then dir = "" end
            rootDir = dir
        end
    end

    -- 日志文件配置解析
    -- logFileSize: 单个日志文件最大字节数, 负值表示不限制
    -- logFileCount: 日志文件总数 (含 .log), 0 表示禁用文件输出, 负值表示归档数量不限制
    local logFileSize = Log.DEFAULT_FILE_SIZE
    local logFileSizeBad = false
    if initCfg.logFileSize ~= nil then
        local size = tonumber(initCfg.logFileSize)
        if not size or size == 0 then
            logFileSizeBad = true
        elseif size < 0 then
            logFileSize = -1
        else
            logFileSize = math.floor(size)
        end
    end

    local logFileCount = Log.DEFAULT_FILE_COUNT
    local logFileCountBad = false
    if initCfg.logFileCount ~= nil then
        local count = tonumber(initCfg.logFileCount)
        if not count then
            logFileCountBad = true
        elseif count == 0 then
            logFileCount = 0
        elseif count < 0 then
            logFileCount = -1
        else
            logFileCount = math.floor(count)
        end
    end

    -- noLog 会静音全部日志, 此时不创建日志文件 (调试模式下日志仍会开启)
    local fileMaxCount = logFileCount
    if initCfg.noLog and not debugEnabled then fileMaxCount = 0 end

    local LogObj = Log:new(initCfg.noLog and Log.LEVELS.NONE or Log.LEVELS.INFO, {
        dir = rootDir .. "/log",
        maxSize = logFileSize,
        maxCount = fileMaxCount,
    })
    if logFileSizeBad then
        LogObj:warn("Invalid logFileSize (expect a positive byte count, or -1 for unlimited), using default",
            Log.DEFAULT_FILE_SIZE)
    end
    if logFileCountBad then
        LogObj:warn("Invalid logFileCount (expect >= 0, 0 to disable, or -1 for unlimited), using default",
            Log.DEFAULT_FILE_COUNT)
    end
    local logFileError = LogObj:getFileError()
    if logFileError then
        LogObj:fatalNoExit("[LOG] Log file output is disabled because: ", logFileError)
    end
    LogObj:debug("Program root:", rootDir == "" and "/" or rootDir)

    if debugEnabled then
        -- 调试模式忽略 noLog 信号
        LogObj:setLevel(Log.LEVELS.DEBUG)

        -- 格式化为二进制输出 (16 位)
        local bits = {}
        for i = 15, 0, -1 do
            bits[#bits + 1] = bit32.extract(debugMode, i, 1)
        end
        LogObj:debug("Debug Mode", table.concat(bits))
    end

    -- 配置解析
    local settings = {
        debugMode = debugMode,
        noTerminate = not not initCfg.noTerminate, -- 忽略终止事件
        noReboot = not not initCfg.noReboot,       -- 阻止系统重启
        noTimer = not not initCfg.noTimer,         -- 计时器禁用配置
        noLog = not not initCfg.noLog,             -- 日志禁用设置
        logFileSize = logFileSize,                 -- 单个日志文件最大字节数 (-1 不限制)
        logFileCount = logFileCount,               -- 日志文件总数 (含 .log, 0 禁用, -1 不限制)
    }

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
    if type(initCfg.disabledUnits) == "table" then
        for _, v in pairs(initCfg.disabledUnits) do
            local text = tostring(v)
            if text ~= "" then
                settings.disabledUnits[text] = true
                if text:lower():sub(-4) == ".lua" then
                    settings.disabledUnits[text:sub(1, -5)] = true
                else
                    settings.disabledUnits[text .. ".lua"] = true
                end
            end
        end
    end

    -- 目录检查
    local checkDirs = { "/bin", "/etc" }
    if LogObj:isFileEnabled() then checkDirs[#checkDirs + 1] = "/log" end
    for _, dir in ipairs(checkDirs) do
        local path = rootDir .. dir
        if fs.exists(path) then
            if not fs.isDir(path) then
                LogObj:fatal("'" .. path .. "' exists but is not a directory!")
            end
        else
            local ok, err = pcall(fs.makeDir, path)
            if not ok then
                LogObj:fatal("Failed to create " .. path .. " directory: ", err)
            end
        end
    end

    -- 创建对象
    local obj = setmetatable({
        _module = {},
        _liblog = LogObj,
        _libnet = MiniNet:new(initCfg.netName),
        _settings = settings,
        _rootDir = rootDir,
        _event = {
            modem_message = true,
            monitor_touch = {},
            poll = {},
        },
    }, self)

    -- 遍历处理lua文件 (排序保证加载顺序稳定)
    local loadStartTime = os.epoch("utc")
    local files = fs.list(rootDir .. "/bin")
    table.sort(files, function(a, b) return tostring(a) < tostring(b) end)
    for _, nameRaw in ipairs(files) do
        if type(nameRaw) == "string" and nameRaw:lower():sub(-4) == ".lua" then
            local moduleName = nameRaw:sub(1, -5)
            if settings.disabledUnits[moduleName] then
                obj._liblog:info("Module", moduleName, "is disabled by config, skipping")
            else
                obj:_loadModules(moduleName)
            end
        end
    end
    local loadTime = os.epoch("utc") - loadStartTime

    -- 后处理配置
    if #obj._event.poll == 0 then obj._settings.noTimer = true end -- poll事件列表为空时禁用轮询计时器
    if bit32.btest(settings.debugMode, self.DEBUGMASK[4]) then
        -- 网络事件被强制禁用
        obj._settings.noNet = true
        obj._liblog:debug("Network events are disabled by the debug mask")
    else
        obj._settings.noNet = false
        -- 传入的信道合法时使用传入信道, 否则使用计算机ID
        local channel = os.getComputerID()
        if type(initCfg.netChannel) == "number" and initCfg.netChannel >= 0 and initCfg.netChannel <= 65535 then
            channel = math.floor(initCfg.netChannel)
        end
        obj._libnet:open(channel)
        obj._liblog:debug("Network channel opened:", channel)
    end

    -- 调试shell开启时将自身挂载到全局
    if bit32.btest(settings.debugMode, self.DEBUGMASK[1]) then
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

--- 模块配置合规性校验
--- @param name string 模块名称
--- @param cfg table 模块返回的事件配置
--- @return boolean isOK
function init:_checkEventList(name, cfg)
    if type(cfg) ~= "table" then return false end
    if cfg.poll ~= nil and type(cfg.poll) ~= "boolean" then return false end
    if cfg.monitor ~= nil and type(cfg.monitor) ~= "boolean" then return false end
    if cfg.monitor and type(cfg.monitorName) ~= "string" then
        self._liblog:warn("Module", name, "requested monitor events but has no valid 'monitorName'")
        return false
    end
    if cfg.other ~= nil and type(cfg.other) ~= "table" then return false end
    return true
end

--- 加载模块
--- @param name string 要加载的模块名称 (不含 .lua)
--- @return boolean isOK
function init:_loadModules(name)
    if not name or type(name) ~= "string" then return false end
    local startTime = os.epoch("utc")

    -- 打印致命日志并放弃当前模块
    local function doError(id, ...)
        self._liblog:fatalNoExit(string.format(self.ERRORTEXT[id] or "Unknown", ...))
        return false
    end

    -- 加载模块
    local ok0, module = pcall(require, "bin." .. name)
    if not ok0 then return doError(1, name, Log.toPlainText(module)) end
    if type(module) ~= "table" or type(module.new) ~= "function" then
        return doError(5, name)
    end

    -- 初始化模块并向模构造器函数按顺序传入以下参数
    --   * config <table> 若 /etc 文件夹中存在同名json文件则传入解析后的配置表，若不存在则传入空表
    --   * libs {MiniNet, Log, root} 分别为: 已初始化的 MiniNet 网络库、已初始化的 Log 日志实例和当前程序运行的根目录
    --   * debugMode <number> 调试模式二进制码
    local config, cfgErr = loadJson(self._rootDir .. "/etc/" .. name .. ".json")
    if cfgErr and cfgErr ~= "file not found" then
        self._liblog:warn("Config", name .. ".json", "cannot be loaded:", cfgErr)
    end

    local ok1, obj = pcall(
        module.new,
        module,
        config,
        {
            net = self._libnet,
            log = self._liblog,
            root = self._rootDir,
        },
        self._settings.debugMode
    )
    if not ok1 then return doError(2, name, Log.toPlainText(obj)) end

    -- 获取模块配置
    local ok2, cfg = pcall(obj.getEventList, obj)
    if not ok2 or type(cfg) ~= "table" then
        return doError(3, name, Log.toPlainText(cfg))
    end
    if not self:_checkEventList(name, cfg) then
        return doError(4, name, "getEventList")
    end

    -- 处理轮询事件请求
    if cfg.poll then
        table.insert(self._event.poll, name)
    end

    -- 屏幕点击事件请求
    if cfg.monitor then
        self._event.monitor_touch[cfg.monitorName] = self._event.monitor_touch[cfg.monitorName] or {}
        table.insert(self._event.monitor_touch[cfg.monitorName], name)
    end

    -- 其他事件请求
    if type(cfg.other) == "table" then
        for _, v in ipairs(cfg.other) do
            if type(v) == "string" then
                if self.RESERVEDEVENT[v] then
                    self._liblog:warn("Module", name, "cannot register reserved event", v)
                elseif self._event[v] == nil or type(self._event[v]) == "table" then
                    self._event[v] = self._event[v] or {}
                    table.insert(self._event[v], name)
                else
                    self._liblog:warn("Module", name, "cannot register event", v)
                end
            end
        end
    end

    self._module[name] = obj
    self._liblog:debug("Module", name, "loaded in", os.epoch("utc") - startTime, "ms")
    return true
end

--- 清理并退出
function init:_exitClean()
    self._liblog:info("System shutting down ...")

    -- 关闭无线连接
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[11]) then
        self._liblog:debug("Network connection keep-alive has been enabled!")
    else
        self._libnet:close()
    end

    -- 清理屏幕
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[10]) then
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
--- @return number n 结束的协程序号
function init:doMainLoop()
    if self._running then
        self._liblog:warn("The main loop is already running, ignore this call")
        return 0
    end
    self._running = true

    -- 是否处于关闭流程中
    local inClose = false
    -- 初始化任务队列
    local eventQueue = TaskQueue:new()
    -- 高位第0位, 将事件队列挂载到全局
    if bit32.btest(self._settings.debugMode, self.DEBUGMASK[8]) then
        -- 启动调试shell时变为挂载到shell内环境
        if bit32.btest(self._settings.debugMode, self.DEBUGMASK[1]) then
            _ENV.HubEventQueue = eventQueue
        else
            _G.HubEventQueue = eventQueue
        end

        self._liblog:debug("The event queue has been mounted to global at 'HubeventQueue'")
    end
    -- 低位第3位，强制禁用屏幕点击事件
    local noMonitor = bit32.btest(self._settings.debugMode, self.DEBUGMASK[3])
    -- 低位第5位，强制禁用自定义事件
    local noOtherEvent = bit32.btest(self._settings.debugMode, self.DEBUGMASK[5])
    -- 低位第6位或配置项，强制禁用重启逻辑
    local noReboot = self._settings.noReboot or bit32.btest(self._settings.debugMode, self.DEBUGMASK[6])
    -- 高位第1位, 主循环正常终止时挂起
    local hangOnStop = bit32.btest(self._settings.debugMode, self.DEBUGMASK[9])

    --- 采集进程: 初步过滤并推入任务队列
    local function monitor()
        while true do
            local event = { os.pullEventRaw() }
            if inClose then break end

            if event[1] == "terminate" then
                if self._settings.noTerminate then
                    self._liblog:debug()
                end
                inClose = true
                self:_exitClean()
                if hangOnStop then break end
                return
            elseif event[1] == "reboot" and not noReboot then
                inClose = true
                self:_exitClean()
                if hangOnStop then break end
                os.reboot()
            elseif self._event[event[1]] then
                eventQueue:push(event)
                os.queueEvent("newTask")
            end
        end

        while true do os.pullEvent("Imashino Misaki") end -- 监听不存在的事件来无限等待
    end

    --- 处理进程: 消费任务队列并并行执行
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

                -- 轮询取任务并生成事件函数集合
                local tasks = {}
                while not eventQueue:isEmpty() do
                    local event = eventQueue:pop()
                    if event == nil then break end

                    if type(event) ~= "table" then
                        -- 事件格式错误
                        errEventCount = errEventCount + 1
                        self._liblog:error(
                            "Got a corrupted event from the state queue, skipping processing this broken event!")
                        if errEventCount > 10 then
                            inClose = true
                            self._liblog:fatal("Event damage threshold exceeded (", errEventCount,
                                "> 10 ), The system is unstable and has been forced to shut down ...")
                            break
                        end
                    else
                        if event[1] == "poll" and not self._settings.noTimer then
                            -- 轮询事件
                            self._libnet:poll()
                            for _, moduleName in ipairs(self._event.poll) do
                                local moduleObj = self._module[moduleName]
                                if moduleObj and type(moduleObj["poll"]) == "function" then
                                    tasks[#tasks + 1] = function()
                                        return moduleObj["poll"](moduleObj, event)
                                    end
                                end
                            end
                        elseif event[1] == "monitor_touch" and not noMonitor then
                            -- 屏幕点击事件
                            local handlers = self._event.monitor_touch[event[2]]
                            if type(handlers) == "table" then
                                for _, moduleName in ipairs(handlers) do
                                    local moduleObj = self._module[moduleName]
                                    if moduleObj and type(moduleObj["epoll"]) == "function" then
                                        tasks[#tasks + 1] = function()
                                            return moduleObj["epoll"](moduleObj, event)
                                        end
                                    end
                                end
                            end
                        elseif event[1] == "modem_message" and not self._settings.noNet then
                            -- 网络事件
                            local net = self._libnet
                            tasks[#tasks + 1] = function()
                                return net:epoll(event)
                            end
                        elseif self._event[event[1]] and not noOtherEvent then
                            -- 其他事件
                            local list = self._event[event[1]]
                            if type(list) == "table" then
                                for _, moduleName in ipairs(list) do
                                    local moduleObj = self._module[moduleName]
                                    if moduleObj and type(moduleObj["epoll"]) == "function" then
                                        tasks[#tasks + 1] = function()
                                            return moduleObj["epoll"](moduleObj, event)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- 并行运行所有处理函数
                -- * 根据官方文档若任务列表大于256会产生严重问题，此处因模块较少暂时可忽略
                if #tasks ~= 0 and not inClose then
                    local ok, err = pcall(parallel.waitForAll, table.unpack(tasks))
                    if not ok then
                        self._liblog:error("A module handler raised an error:", Log.toPlainText(err))
                    end
                end
            end
        end

        while true do os.pullEvent("Sumi Serina") end -- 监听不存在的事件来无限等待
    end

    --- 计时器进程
    local function timer()
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

    --- 调试shell函数
    local function debugShell()
        --- 浅拷贝 API 表
        --- @param source table 要拷贝的原始 API 表
        --- @return table table 浅拷贝后的 API 表
        local function cloneTable(source)
            local copy = {}
            for k, v in pairs(source) do
                copy[k] = v
            end
            return copy
        end

        if bit32.btest(self._settings.debugMode, self.DEBUGMASK[1]) then
            local disableFunc = function() printError("The main program has intercepted the operation") end
            local env = setmetatable({
                shell      = cloneTable(shell),
                multishell = cloneTable(multishell),
                require    = require,
                package    = package
            }, { __index = _ENV })

            -- 环境劫持
            env._G = env
            env.os.reboot = disableFunc
            env.os.shutdown = disableFunc
            env.multishell.launch = disableFunc

            -- 启动调试shell
            local shellPath = shell.resolveProgram("shell")
            if fs.exists(shellPath) then
                self._liblog:debug("Launching debug shell in a new tab")
                multishell.launch(env, shellPath)
            else
                self._liblog:fatalNoExit("Unable to start the debug terminal!")
            end
        end

        while true do os.pullEvent("Tendou Kei") end -- 监听不存在的事件来无限等待
    end

    return parallel.waitForAny(monitor, handler, timer, debugShell)
end

return init
