local pretty = require("cc.pretty")

--- 日志输出类
--- @class Log
--- @field minLevel number 最低日志级别
local Log = {}
Log.__index = Log

--- 日志级别
Log.LEVELS = {
    DEBUG = 0,
    INFO  = 1,
    WARN  = 2,
    ERROR = 3,
    FATAL = 4,
    NONE  = 9,
}

--- 级别名称与颜色映射
Log.levelConfig = {
    [Log.LEVELS.DEBUG] = { name = "DEBUG", color = colors.lightGray },
    [Log.LEVELS.INFO]  = { name = "INFO ", color = colors.lightBlue },
    [Log.LEVELS.WARN]  = { name = "WARN ", color = colors.yellow },
    [Log.LEVELS.ERROR] = { name = "ERROR", color = colors.red },
    [Log.LEVELS.FATAL] = { name = "FATAL", color = colors.magenta },
}

--- 创建一个新的 Logger 实例
--- @param minLevel? number 最低日志级别 (默认为 INFO)
--- @return Log
function Log:new(minLevel)
    minLevel = tonumber(minLevel) or self.LEVELS.INFO
    if minLevel ~= 9 and (minLevel < 0 or minLevel > 4) then
        minLevel = self.LEVELS.INFO
    end
    return setmetatable({ minLevel = minLevel }, self)
end

--- 核心日志方法
--- @param level number 日志级别
--- @param ... any  要打印的内容
function Log:log(level, ...)
    if level < self.minLevel then return end

    local config = self.levelConfig[level]
    if not config then return end

    local parts = {}

    -- 时间戳
    table.insert(parts, pretty.text("[" .. os.date("%H:%M:%S", os.epoch("local") / 1000) .. "] ", colors.gray))

    -- 级别标签
    table.insert(parts, pretty.text("[" .. config.name .. "] ", config.color))

    -- 内容部分
    for i, arg in ipairs({ ... }) do
        if i > 1 then
            table.insert(parts, pretty.text(" "))
        end

        if type(arg) == "string" then
            table.insert(parts, pretty.text(arg, config.color))
        else
            -- 非字符串使用 pretty 美化打印
            table.insert(parts, pretty.pretty(arg))
        end
    end

    -- 拼接所有文档并输出
    local doc = pretty.concat(table.unpack(parts))
    pretty.print(doc)
end

--- 打印Debug等级日志
--- @param ... any 要打印的数据
function Log:debug(...) self:log(Log.LEVELS.DEBUG, ...) end

--- 打印Info等级日志
--- @param ... any 要打印的数据
function Log:info(...) self:log(Log.LEVELS.INFO, ...) end

--- 打印Warn等级日志
--- @param ... any 要打印的数据
function Log:warn(...) self:log(Log.LEVELS.WARN, ...) end

--- 打印Error等级日志
--- @param ... any 要打印的数据
function Log:error(...) self:log(Log.LEVELS.ERROR, ...) end

--- 打印Fatal致命错误日志并终止程序
--- @param ... any 要打印的数据
function Log:fatal(...)
    self:log(Log.LEVELS.FATAL, ...)
    error()
end

--- 打印Fatal致命错误日志但不终止程序
--- @param ... any 要打印的数据
function Log:fatalNoExit(...) self:log(Log.LEVELS.FATAL, ...) end

return Log
