local pretty           = require("cc.pretty")

--- 日志输出类
--- @class Log
--- @field minLevel number 最低日志级别
--- @field _file table|nil 日志文件状态 (nil 表示不输出到文件)
local Log              = {}
Log.__index            = Log

--- 日志级别
Log.LEVELS             = {
    DEBUG = 0,
    INFO  = 1,
    WARN  = 2,
    ERROR = 3,
    FATAL = 4,
    NONE  = 9,
}

--- 级别名称与颜色映射
Log.levelConfig        = {
    [Log.LEVELS.DEBUG] = { name = "DEBUG", color = colors.lightGray },
    [Log.LEVELS.INFO]  = { name = "INFO ", color = colors.lightBlue },
    [Log.LEVELS.WARN]  = { name = "WARN ", color = colors.yellow },
    [Log.LEVELS.ERROR] = { name = "ERROR", color = colors.red },
    [Log.LEVELS.FATAL] = { name = "FATAL", color = colors.magenta },
}

--- 日志文件默认配置
Log.DEFAULT_FILE_SIZE  = 100 * 1024 -- 单个日志文件的最大字节数 (100 KiB)
Log.DEFAULT_FILE_COUNT = 3          -- 日志文件总数上限 (含 .log 本身)
Log.FILENAME           = "hub.log"  -- 日志文件名
Log.HEADER_DASHES      = 6          -- 启动分隔行两侧的 "-" 数量

--- 将任意值转为单行可读文本
--- @param value any
--- @return string
function Log.toPlainText(value)
    local valueType = type(value)
    if valueType == "string" then return value end
    if valueType == "number" or valueType == "boolean" or valueType == "nil" then
        return tostring(value)
    end
    local ok, text = pcall(textutils.serialise, value, { compact = true })
    if ok and type(text) == "string" then return text end
    return "<" .. valueType .. ">"
end

--- 取本地时间戳
--- @param pattern string os.date 格式
--- @return string|osdate
local function timestamp(pattern)
    return os.date(pattern, math.floor(os.epoch("local") / 1000))
end

--- 复制文件 (不依赖 fs.move 的覆盖语义)
--- @param src string 源路径
--- @param dst string 目标路径
--- @return boolean
local function copyFile(src, dst)
    local input = fs.open(src, "r")
    if not input then return false end
    local data = input.readAll()
    input.close()

    local output = fs.open(dst, "w")
    if not output then return false end
    output.write(data or "")
    output.close()
    return true
end

--- 移动文件 (复制后删除源文件)
--- @param src string 源路径
--- @param dst string 目标路径
--- @return boolean
local function moveFile(src, dst)
    if not copyFile(src, dst) then return false end
    fs.delete(src)
    return true
end

--- 创建一个新的 Logger 实例
--- @param minLevel? number 最低日志级别 (默认 INFO)
--- @param fileCfg? table 文件输出配置 { dir: string, maxSize: number, maxCount: number }
---   maxSize: 单个文件最大字节数, <=0 表示不限制
---   maxCount: 日志文件总数 (含 .log), 0 表示禁用文件输出, <0 表示归档数量不限制
--- @return Log
function Log:new(minLevel, fileCfg)
    minLevel = tonumber(minLevel)
    if not minLevel or (minLevel ~= self.LEVELS.NONE and (minLevel < 0 or minLevel > self.LEVELS.FATAL)) then
        minLevel = self.LEVELS.INFO
    end

    local obj = setmetatable({ minLevel = minLevel, _file = nil, _fileError = nil }, self)
    obj:_initFile(fileCfg)
    return obj
end

--- 初始化日志文件 (创建目录并写入启动分隔行)
--- @param cfg? table 文件输出配置
function Log:_initFile(cfg)
    if type(cfg) ~= "table" then return end

    local maxCount = tonumber(cfg.maxCount) or Log.DEFAULT_FILE_COUNT
    if maxCount == 0 then return end -- 0 表示禁用文件输出
    maxCount = maxCount < 0 and -1 or math.max(1, math.floor(maxCount))

    local maxSize = tonumber(cfg.maxSize) or Log.DEFAULT_FILE_SIZE
    maxSize = maxSize <= 0 and -1 or math.floor(maxSize)

    local dir = tostring(cfg.dir or "")
    if dir == "" then return end

    -- 目录准备
    if fs.exists(dir) then
        if not fs.isDir(dir) then
            self._fileError = "'" .. dir .. "' exists but is not a directory"
            return
        end
    else
        local ok, err = pcall(fs.makeDir, dir)
        if not ok then
            self._fileError = tostring(err)
            return
        end
    end

    -- 防文件夹检查
    if fs.isDir(dir .. "/" .. Log.FILENAME) then
        local ok, err = pcall(fs.delete, dir .. "/" .. Log.FILENAME)
        if not ok then
            self._fileError = "'" ..
                dir .. "/" .. Log.FILENAME .. "' exists but is not a file and can not delete: " .. err
            return
        end
    end

    self._file = {
        dir = dir,
        path = dir .. "/" .. Log.FILENAME,
        maxSize = maxSize,
        maxCount = maxCount,
        size = fs.exists(dir .. "/" .. Log.FILENAME) and fs.getSize(dir .. "/" .. Log.FILENAME) or 0,
    }

    -- 每次启动写入一条分隔行
    local dashes = string.rep("-", Log.HEADER_DASHES)
    self:_appendLine(dashes .. " [" .. timestamp("%Y-%m-%d %H:%M:%S") .. "] " .. dashes)
end

--- 获取文件初始化错误 (成功或未启用文件输出时返回 nil)
--- @return string|nil
function Log:getFileError()
    return self._fileError
end

--- 日志文件是否已启用
--- @return boolean
function Log:isFileEnabled()
    return self._file ~= nil
end

--- 按配置滚动日志文件
function Log:_rotate()
    local file = self._file
    if not file then return end
    local base = file.path
    local count = file.maxCount

    -- 只保留当前文件: 直接清空
    if count == 1 then
        if fs.exists(base) then fs.delete(base) end
        file.size = 0
        return
    end

    -- 归档数量不限制: 找到第一个空闲序号
    if count < 0 then
        local index = 1
        while fs.exists(self._file.path .. "." .. index) do index = index + 1 end
        moveFile(base, self._file.path .. "." .. index)
        file.size = 0
        return
    end

    -- 删除最旧的一份, 再把其余归档依次后移
    local oldest = self._file.path .. "." .. count - 1
    if fs.exists(oldest) then fs.delete(oldest) end
    for index = count - 2, 1, -1 do
        local from = self._file.path .. "." .. index
        if fs.exists(from) then moveFile(from, self._file.path .. "." .. index + 1) end
    end
    moveFile(base, self._file.path .. "." .. 1)
    file.size = 0
end

--- 追加一行到日志文件
--- @param line string 要写入的内容 (不含换行)
function Log:_appendLine(line)
    local file = self._file
    if not file then return end

    local text = line .. "\n"
    local bytes = #text

    -- 超出单文件大小时滚动 (maxSize <= 0 表示不限制)
    if file.maxSize > 0 and file.size > 0 and file.size + bytes > file.maxSize then
        self:_rotate()
    end

    local handle, err = fs.open(file.path, "a")
    if not handle then
        -- 写盘失败时关闭文件输出, 避免每条日志都报错
        self._fileError = tostring(err or "Cannot open log file")
        self._file = nil
        self:fatalNoExit("[LOG] " .. self._fileError .. ", now disable file append!")
        return
    end
    handle.write(text)
    handle.close()
    file.size = file.size + bytes
end

--- 动态调整最低日志级别
--- @param level number 新的最低日志级别
function Log:setLevel(level)
    local levelNum = tonumber(level)
    if levelNum and (levelNum == self.LEVELS.NONE or (levelNum >= 0 and levelNum <= self.LEVELS.FATAL)) then
        self.minLevel = levelNum
    end
end

--- 核心日志方法
--- @param level number 日志级别
--- @param ... any 要打印的内容
--- @return string|nil plain 本次输出的纯文本内容 (被级别过滤时返回 nil)
function Log:log(level, ...)
    if level < self.minLevel then return nil end

    local config = self.levelConfig[level]
    if not config then return nil end

    local args = table.pack(...)
    local docs, plains = {}, {}

    -- 时间戳与级别标签
    local stamp = timestamp("%H:%M:%S")
    docs[1] = pretty.text("[" .. stamp .. "] ", colors.gray)
    docs[2] = pretty.text("[" .. config.name .. "] ", config.color)
    plains[1] = "[" .. stamp .. "] [" .. config.name .. "]"

    -- 内容部分
    for i = 1, args.n do
        local arg = args[i]
        if i > 1 then
            docs[#docs + 1] = pretty.text(" ")
            plains[#plains + 1] = " "
        end
        if type(arg) == "string" then
            docs[#docs + 1] = pretty.text(arg, config.color)
            plains[#plains + 1] = arg
        else
            -- 非字符串使用 pretty 美化打印
            docs[#docs + 1] = pretty.pretty(arg)
            plains[#plains + 1] = Log.toPlainText(arg)
        end
    end

    -- 拼接所有文档并输出
    pretty.print(pretty.concat(table.unpack(docs)))

    -- 同步写入日志文件
    local ok, err = pcall(self._appendLine, self,
        "[" .. timestamp("%Y-%m-%d %H:%M:%S") .. "] [" .. config.name .. "] " .. table.concat(plains, "", 2))
    if not ok then
        self._fileError = tostring(err or "Write failed")
        self._file = nil
        self:fatalNoExit("[LOG] " .. self._fileError .. ", now disable file append!")
    end

    return table.concat(plains)
end

--- 打印Debug等级日志
--- @param ... any 要打印的数据
function Log:debug(...) return self:log(Log.LEVELS.DEBUG, ...) end

--- 打印Info等级日志
--- @param ... any 要打印的数据
function Log:info(...) return self:log(Log.LEVELS.INFO, ...) end

--- 打印Warn等级日志
--- @param ... any 要打印的数据
function Log:warn(...) return self:log(Log.LEVELS.WARN, ...) end

--- 打印Error等级日志
--- @param ... any 要打印的数据
function Log:error(...) return self:log(Log.LEVELS.ERROR, ...) end

--- 打印Fatal致命错误日志并终止程序
--- @param ... any 要打印的数据
function Log:fatal(...)
    local text = self:log(Log.LEVELS.FATAL, ...)
    error(text or "fatal error", 0)
end

--- 打印Fatal致命错误日志但不终止程序
--- @param ... any 要打印的数据
function Log:fatalNoExit(...) return self:log(Log.LEVELS.FATAL, ...) end

return Log
