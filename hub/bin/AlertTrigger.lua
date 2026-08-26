--- @class ATThresholds 单个触发事件信息
--- @field type "less"|"more" 触发类型
--- @field alertType 0|1|2 触发类型: 0 - 特别事件 1 - 阈值触发事件 2 - 带恢复阈值触发事件
--- @field tag string 事件tag标签, 非特别事件时会忽略 (默认: "default")
--- @field reverse boolean 是否反转发送状态
--- @field value number 触发阈值
--- @field isAlerting boolean 是否正在告警 (用于恢复事件)
--- @field NCKCount number 超时计数
--- @field isSending boolean 防重复发送锁

--- @class ATEventList 事件映射表
--- @field objId string 要监听的对象注册ID
--- @field objType "item"|"fluid" 要监听对象的物理属性
--- @field cellType 1|2 接收方的单元类型 (1型为可接受 201 状态码的单元, 2型使用通用 202 状态码)
--- @field cellTag string 接受方的网络tag
--- @field thresholds table<number, ATThresholds> 触发事件列表

--- 主初始化类
--- @class AlertTrigger
--- @field _lists table<number, ATEventList> 事件映射表
--- @field _libs {log:Log, net:MiniNet} 依赖库集合
local AlertTrigger = {}
AlertTrigger.__index = AlertTrigger

--- 初始化实例
--- @param config table 实例配置
--- @param libs {log:Log, net:MiniNet} 依赖库集合
--- @return AlertTrigger
function AlertTrigger:new(config, libs)
    if type(config) ~= "table" then
        error("The 'config' parameter is not valid!", 2)
    end

    local lists = {}
    -- 处理配置文件
    for i, item in ipairs(config) do
        if
            type(item) == "table"
            and type(item.objectId) == "string"
            and (item.objectType == "item" or item.objectType == "fluid")
            and (item.cellType == 0 or item.cellType == 1 or item.cellType == 2)
            and type(item.cellTag) ~= "nil"
            and type(item.thresholds) == "table"
        then
            local cfg = {
                objId = item.objectId,
                objType = item.objectType,
                cellTag = item.cellTag,
                cellType = item.cellType,
                thresholds = {}
            }

            -- 验证触发逻辑
            for j, val in ipairs(item.thresholds) do
                if
                    type(val) == "table"
                    and (val.type == "less" or val.type == "more")
                    and (val.alertType > -1 and val.alertType < 3)
                    and type(val.value) == "number"
                then
                    -- tag 处理
                    if not val.tag then
                        val.tag = "default"
                    elseif type(val.tag) ~= "string" then
                        local ok, stag = pcall(tostring, val.tag)
                        if ok then
                            val.tag = stag
                        else
                            val.tag = "default"
                            libs.log:warn("[AlertTrigger] The trigger configuration index", j, "for unit", i,
                                "has bad thresholds tag, use default tag instead!")
                        end
                    end
                    --- 初始化状态
                    val.isAlerting = false
                    val.NCKCount = 0
                    val.isSending = false
                    val.reverse = not not val.reverse
                    cfg.thresholds[#cfg.thresholds + 1] = val
                else
                    libs.log:warn("[AlertTrigger] The trigger configuration index", j,
                        "for unit", i, "is not compliant, skipping!")
                end
            end

            if #cfg.thresholds > 0 then
                lists[#lists + 1] = cfg
            else
                libs.log:warn("[AlertTrigger] Unit configuration index", i,
                    "doesn't contain any valid trigger settings, skipping!")
            end
        else
            libs.log:warn("[AlertTrigger] Unit configuration index", i,
                "basic information is non-compliant, skipping")
        end
    end

    return setmetatable({
        _libs = libs,
        _lists = lists
    }, self)
end

--- 告警状态码映射表
AlertTrigger.ALERTCODEMAP = {
    [0] = 203,
    [1] = 201,
    [2] = 202,
}

-- 获取需要注册的事件配置
function AlertTrigger:getEventList()
    return {
        poll = false,
        monitor = false,
        other = #self._lists ~= 0 and { "ae2_cache_update" } or {}
    }
end

--- 事件触发函数: AE2 缓存更新处理
--- @param data table 事件对象
function AlertTrigger:epoll(data)
    -- 基础格式验证
    if type(data) ~= "table" or type(data[2]) ~= "table" then
        return
    end

    for _, item in ipairs(self._lists) do
        -- 获取当前物品的状态数据
        local cache = data[2][item.objType .. "s"]
        local amount = 0
        if type(cache) == "table" and type(cache[item.objId]) == "table" then
            amount = cache[item.objId].amount or 0
        end

        for _, t in ipairs(item.thresholds) do
            -- 判断当前是否触发条件
            local isTriggered = false
            if t.type == "less" then
                if t.isAlerting then
                    isTriggered = amount >= t.value -- 已报警，当前恢复了，触发解除
                else
                    isTriggered = amount < t.value  -- 未报警，当前过低了，触发报警
                end
            elseif t.type == "more" then
                if t.isAlerting then
                    isTriggered = amount <= t.value -- 已报警，当前恢复了，触发解除
                else
                    isTriggered = amount > t.value  -- 未报警，当前过高了，触发报警
                end
            end

            if not isTriggered then     -- 数值恢复时清空重试计数
                t.NCKCount = 0
            elseif not t.isSending then -- 发送数据包
                local shouldSend = false

                if
                    t.NCKCount < 3           -- 前 3 次失败内直接发包
                    or (t.NCKCount % 6) == 0 -- 超过 3 次失败后每触发6次尝试一次发包
                then
                    shouldSend = true
                end

                -- 阈值事件处理
                if t.alertType == 1 and t.isAlerting then
                    shouldSend = false
                end

                -- 发送数据包
                t.NCKCount = t.NCKCount + 1
                if shouldSend then
                    self._libs.log:info("[AlertTrigger] Sending", t.isAlerting, "signal for", item.cellTag, "trigger",
                        t.tag, "amount", amount, "threshold", t.value)

                    -- 映射要发送的数据
                    local status
                    if t.reverse then
                        status = t.isAlerting
                    else
                        status = not t.isAlerting
                    end

                    t.isSending = true -- 加锁
                    self._libs.net:send(
                        item.cellTag,
                        self.ALERTCODEMAP[(t.alertType == 0) and 0 or item.cellType],
                        { tag = t.tag, status = status },
                        2,
                        function(_, code, isTimeout)
                            t.isSending = false -- 解锁
                            if isTimeout then
                                self._libs.log:error("[AlertTrigger] Failed to send judgment signal for",
                                    item.cellTag, "trigger", t.tag)
                            elseif code == 103 then -- ACK
                                t.NCKCount = 0
                                t.isAlerting = not t.isAlerting
                            elseif code == 104 and item.cellType == 2 then -- NCK
                                t.NCKCount = 0
                                t.isAlerting = not t.isAlerting
                                self._libs.log:warn("[AlertTrigger]", item.cellTag,
                                    "report conflicts with hardware disable logic, skipping.")
                            end

                            return false
                        end
                    )
                end
            end
        end
    end
end

return AlertTrigger
