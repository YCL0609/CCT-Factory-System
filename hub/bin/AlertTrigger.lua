--- @class ATThresholds 单个触发事件信息
--- @field type "less"|"more" 触发类型
--- @field alertType 0|1|2 触发类型: 0 - 特别事件 1 - 仅告警触发事件 2 - 带恢复阈值触发事件
--- @field tag string 事件tag标签, 非特别事件时会忽略 (默认: "default")
--- @field reverse boolean 是否反转发送状态
--- @field value number 触发阈值
--- @field isAlerting boolean 是否正在告警 (用于恢复事件)
--- @field NCKCount number 超时计数
--- @field isSending boolean 防重复发送锁

--- @class ATEventList 事件映射表
--- @field objId string 要监听的对象注册ID
--- @field objType "item"|"fluid" 要监听对象的物理属性
--- @field cellType 0|1|2 接收方的单元类型 (1型为可接受 201 状态码的单元, 2型使用通用 202 状态码)
--- @field cellTag string 接受方的网络tag
--- @field thresholds table<number, ATThresholds> 触发事件列表

--- AE 阈值告警触发类
--- * 监听 AEMonitor 产生的 ae2_cache_update 事件, 按配置阈值向工厂单元下发信号
--- @class AlertTrigger
--- @field _lists table<number, ATEventList> 事件映射表
--- @field _libs {log:Log, net:MiniNet, root:string} 依赖库集合
local AlertTrigger = {}
AlertTrigger.__index = AlertTrigger

--- 重试策略: 前 N 次失败内每次重试
AlertTrigger.RETRY_FAST = 3
--- 重试策略: 超过后每 M 次失败尝试一次
AlertTrigger.RETRY_SLOW = 6

--- 告警状态码映射表
AlertTrigger.ALERTCODEMAP = {
    [0] = 203,
    [1] = 201,
    [2] = 202,
}

--- 初始化实例
--- @param config table 实例配置
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @return AlertTrigger
function AlertTrigger:new(config, libs)
    if type(config) ~= "table" then
        error("The 'config' parameter is not valid!", 2)
    end

    local lists = {}
    -- 处理配置文件
    for i, item in ipairs(config) do
        local basicOK = type(item) == "table"
            and type(item.objectId) == "string"
            and (item.objectType == "item" or item.objectType == "fluid")
            and (item.cellType == 0 or item.cellType == 1 or item.cellType == 2)
            and type(item.cellTag) == "string"
            and item.cellTag ~= ""
            and type(item.thresholds) == "table"

        if basicOK then
            local thresholds = {}

            -- 验证触发逻辑
            for j, val in ipairs(item.thresholds) do
                if
                    type(val) == "table"
                    and (val.type == "less" or val.type == "more")
                    and type(val.alertType) == "number"
                    and val.alertType > -1 and val.alertType < 3
                    and type(val.value) == "number"
                then
                    -- tag 处理
                    local tag = val.tag
                    if tag == nil then
                        tag = "default"
                    elseif type(tag) ~= "string" then
                        libs.log:warn("[AlertTrigger] The trigger configuration index", j, "for unit", i,
                            "has bad thresholds tag, use default tag instead!")
                        tag = "default"
                    end

                    --- 初始化状态
                    thresholds[#thresholds + 1] = {
                        type = val.type,
                        alertType = val.alertType,
                        value = val.value,
                        tag = tag,
                        reverse = not not val.reverse,
                        isAlerting = false,
                        NCKCount = 0,
                        isSending = false,
                    }
                else
                    libs.log:warn("[AlertTrigger] The trigger configuration index", j,
                        "for unit", i, "is not compliant, skipping!")
                end
            end

            if #thresholds > 0 then
                lists[#lists + 1] = {
                    objId = item.objectId,
                    objType = item.objectType,
                    cellTag = item.cellTag,
                    cellType = item.cellType,
                    thresholds = thresholds
                }
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

-- 获取需要注册的事件配置
function AlertTrigger:getEventList()
    return {
        poll = false,
        monitor = false,
        other = #self._lists ~= 0 and { "ae2_cache_update" } or {}
    }
end

--- 判断当前是否处于"需要发送"的状态迁移点
--- @param t ATThresholds 触发配置
--- @param amount number 当前数值
--- @return boolean pending 是否存在待确认的状态迁移
function AlertTrigger._isPending(t, amount)
    if t.type == "less" then
        if t.isAlerting then
            return amount >= t.value -- 已报警, 当前恢复了 -> 待解除
        end
        return amount < t.value -- 未报警, 当前过低了 -> 待报警
    end
    -- more
    if t.isAlerting then
        return amount <= t.value -- 已报警, 当前恢复了 -> 待解除
    end
    return amount > t.value -- 未报警, 当前过高了 -> 待报警
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
            amount = tonumber(cache[item.objId].amount) or 0
        end

        for _, t in ipairs(item.thresholds) do
            local pending = self._isPending(t, amount)

            if not pending then
                -- 数值保持在稳定状态时清空重试计数
                t.NCKCount = 0
            elseif not t.isSending then
                -- alertType 1 只在进入告警时下发一次, 恢复时仅重新武装状态机
                if t.alertType == 1 and t.isAlerting then
                    t.isAlerting = false
                    t.NCKCount = 0
                    self._libs.log:debug("[AlertTrigger]", item.cellTag, "trigger", t.tag,
                        "recovered (no signal required by alertType 1)")
                else
                    -- NCKCount 为"待确认轮次"计数: 前 RETRY_FAST 轮每轮重试,
                    -- 之后每 RETRY_SLOW 轮重试一次, 避免网络异常时刷屏发包
                    local shouldSend = t.NCKCount < self.RETRY_FAST
                        or (t.NCKCount % self.RETRY_SLOW) == 0
                    t.NCKCount = t.NCKCount + 1

                    if shouldSend then
                        self._libs.log:info("[AlertTrigger] Sending", t.isAlerting, "signal for", item.cellTag,
                            "trigger", t.tag, "amount", amount, "threshold", t.value)

                        t.isSending = true -- 加锁
                        self._libs.net:send(
                            item.cellTag,
                            self.ALERTCODEMAP[(t.alertType == 0) and 0 or item.cellType],
                            { tag = t.tag, status = t.reverse and t.isAlerting or not t.isAlerting },
                            2,
                            function(_, code, isTimeout)
                                t.isSending = false -- 解锁
                                if isTimeout then
                                    self._libs.log:error("[AlertTrigger] Failed to send judgment signal for",
                                        item.cellTag, "trigger", t.tag)
                                elseif code == 103 then -- ACK
                                    t.NCKCount = 0
                                    t.isAlerting = not t.isAlerting
                                elseif code == 104 then -- NCK
                                    if item.cellType == 2 then
                                        -- 与硬件禁用逻辑冲突: 视为已生效, 避免无限重试
                                        t.NCKCount = 0
                                        t.isAlerting = not t.isAlerting
                                        self._libs.log:warn("[AlertTrigger]", item.cellTag,
                                            "report conflicts with hardware disable logic, skipping.")
                                    end
                                end

                                return false
                            end
                        )
                    end
                end
            end
        end
    end
end

return AlertTrigger
