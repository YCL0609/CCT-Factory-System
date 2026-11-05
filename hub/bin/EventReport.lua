--- @class RCeventMap 禁用事件映射
--- @field ae2_cache_update boolean 是否启用 'ae2_cache_update' 事件
--- @field unit_status_change boolean 是否启用 'unit_status_change' 事件

--- 客户端事件推送类
--- * 维护客户端连接, 并将主机侧事件缓存/推送给所有客户端
--- @class EventReport
--- @field _client number 客户端计数
--- @field _libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @field _enabledMap RCeventMap 禁用事件映射
--- @field _dataCache table 数据缓存
local EventReport = {}
EventReport.__index = EventReport

--- 初始化事件推送类
--- @param config table 配置参数
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @return EventReport
function EventReport:new(config, libs)
    -- 配置处理
    config = type(config) == "table" and config or {}

    local obj = setmetatable({
        _client = 0,
        _libs = libs,
        _enabledMap = {
            ae2_cache_update = not config.noAE2Update,
            unit_status_change = not config.noUnitChange,
        },
        _dataCache = {
            ae2_cache_update = {},
            unit_status_change = {}
        }
    }, self)

    obj:_initCellNetServer()

    return obj
end

function EventReport:_initCellNetServer()
    self._libs.net:startTasks({ {
        mid = "EventReportClient",
        rawCount = math.huge, -- 永不超时
        callback = function(_, code1, isTimeout1, data)
            if isTimeout1 or code1 ~= 105 or type(data) ~= "table" or not data.clientId then
                return true
            end

            local clientId = tostring(data.clientId)
            self._libs.log:debug("[EventReport] New client connection request:", clientId)

            local mid = self._libs.net:genMessageID(1)[1]
            -- 进行握手
            self._libs.net:send(
                "CLIENT",
                106,
                {
                    mid = mid,
                    clientId = clientId
                },
                3,
                function(_, code2, isTimeout2)
                    if code2 == 103 then
                        self._client = self._client + 1
                        -- 加入事件列表
                        self._libs.net:startTasks({ {
                            mid = mid,
                            rawCount = 6, -- 默认配置时为 30s 超时时间
                            callback = function(_, code3, isTimeout3)
                                if code3 == 193 then
                                    os.queueEvent("client_ping", mid)
                                    return true
                                elseif code3 == 107 then
                                    self._client = math.max(0, self._client - 1)
                                    os.queueEvent("client_disconnect", mid, false)
                                    self._libs.log:info("[EventReport] Client", clientId, "has disconnected it self")
                                    return false
                                elseif isTimeout3 then
                                    self._client = math.max(0, self._client - 1)
                                    os.queueEvent("client_disconnect", mid, true)
                                    self._libs.log:warn("[EventReport] Client", clientId,
                                        "has disconnected because net timeout")
                                    return false
                                else
                                    return true
                                end
                            end
                        } })
                        os.queueEvent("client_connect", mid)
                        self:_sendData("ALL")
                        self._libs.log:info("[EventReport] New client", clientId, "has connected")
                    elseif isTimeout2 then
                        self._libs.log:error("[EventReport] Client", clientId, "handshake timed out")
                    else
                        self._libs.log:error("[EventReport] Client", clientId, "handshake failed")
                    end
                    return false
                end
            )
            return true
        end
    } })
end

--- 重新发送指定类型的缓存数据
--- @param dataType string 要发送的数据类型 ("ALL"表示遍历所有启用的类型)
function EventReport:_sendData(dataType)
    if dataType == "ALL" then
        for name, data in pairs(self._dataCache) do
            if self._enabledMap[name] then
                self._libs.net:broadcast("CLIENT", 204, {
                    type = name,
                    data = data
                })
            end
        end
        return
    end

    if not self._enabledMap[dataType] then return end
    self._libs.net:broadcast("CLIENT", 204, {
        type = dataType,
        data = self._dataCache[dataType]
    })
end

-- 获取需要注册的事件配置
function EventReport:getEventList()
    local others = {}
    for key, value in pairs(self._enabledMap) do
        if value then others[#others + 1] = key end
    end

    return {
        poll = false,
        monitor = false,
        other = others
    }
end

--- 事件触发函数
--- @param event table 事件对象
function EventReport:epoll(event)
    if type(event) ~= "table" then return end

    local name = event[1]
    if not self._enabledMap[name] or type(event[2]) ~= "table" then return end

    self._dataCache[name] = event[2]
    if self._client > 0 then
        self:_sendData(name)
    end
end

return EventReport
