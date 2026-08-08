local sha2 = require("../lib.sha2")

--- 自动更新/网络控制类
--- @class HttpReport
--- @field _libs {log:Log, net:MiniNet} 依赖库集合
--- @field _enabledMap table 禁用事件映射
--- @field _dataCache table 数据缓存
--- @field _pollCount number poll计数
--- @field _errCount number 网络错误计数
--- @field _httpCfg {key:string,url:string} http配置
--- @field _isWaiting boolean 是否正在等待上一次请求返回
--- @field _enabled boolean 是否启用模块
--- @field _relayObj table 红石控制对象
--- @field _relaySide string 红石侧面名称
local HttpReport = {}
HttpReport.__index = HttpReport

--- 初始化自动更新类
--- @param cfg table 配置参数
--- @param libs {log:Log, net:MiniNet} 依赖库集合
--- @return HttpReport
function HttpReport:new(cfg, libs)
    if not http then error("HTTP API is disabled", 2) end

    -- 基础配置处理
    cfg = type(cfg) == "table" and cfg or {}
    local key = type(cfg.key) == "string" and cfg.key or ""
    local url = type(cfg.url) == "string" and cfg.url or ""
    local ok, err = http.checkURL(url)
    if not ok then error(err, 2) end
    if #key < 16 then error("Key is too short (< 16)", 2) end

    -- 红石对象处理
    local relayObj = redstone
    if type(cfg.relayName) == "string" and peripheral.isPresent(cfg.relayName) then
        relayObj = peripheral.wrap(cfg.relayName)
    end

    -- 侧面处理
    local relaySide
    local sideOK = false
    for _, s in ipairs({ "bottom", "top", "back", "front", "right", "left" }) do
        if s == cfg.relaySide then
            relaySide = s
            sideOK = true
            break
        end
    end
    if not sideOK then error("Redstone side name is invalid", 2) end

    libs.log:info("[HttpReport] Report URL:", cfg.url)
    local obj = setmetatable({
        _libs = libs,
        _enabledMap = {
            ae2_cache_update = not cfg.noAE2Update,
            unit_status_change = not cfg.noUnitChange,
        },
        _dataCache = {},
        _pollCount = 0,
        _errCount = 0,
        _httpCfg = { key = key, url = url },
        _isWaiting = false,
        _relayObj = relayObj,
        _relaySide = relaySide,
        _enabled = relayObj.getInput(relaySide)
    }, self)

    return obj
end

--- 解析http响应
--- @param response table 响应体
--- @return boolean isOK 是否处理成功
--- @return number code 响应状态码
--- @return table|string data 若成功则为处理后的数据, 若不成功则为错误信息
function HttpReport:_parseResponse(response)
    if type(response) ~= "table" then
        return false, -1, "Response body type error"
    end

    -- 响应数据获取
    local headers = response.getResponseHeaders() or {}
    local code = response.getResponseCode() or -1
    local bodyRaw = response.readAll() or ""
    response.close()

    -- 状态码校验
    if code < 0 then return false, code, "Failed to get response data" end

    -- 标头校验
    local ssha512 = headers.ssha512
    local stime = headers.stime
    if not ssha512 or not stime then
        return false, code, "The 'ssha512' or 'stime' header is missing"
    end

    -- 时间偏移校验
    local time = os.epoch("utc")
    if math.abs(time - stime) > 30000 then -- 允许正负30s
        return false, code, "Time offset check failed"
    end

    -- 哈希校验
    local sha512 = sha2.hmac(sha2.sha512, self._httpCfg.key, bodyRaw .. stime)
    if sha512 ~= ssha512 then
        return false, code, "Hash check failed"
    end

    -- 解析body
    local body, jsonErr
    if #bodyRaw > 0 then
        body, jsonErr = textutils.unserialiseJSON(bodyRaw)
    else
        body = {}
    end

    -- 返回数值
    if body == nil then
        return false, code, jsonErr or "JSON parsing error"
    else
        return true, code, body
    end
end

-- 获取需要注册的事件配置
function HttpReport:getEventList()
    local others = { "http_success", "http_failure", "redstone" }
    -- 注册自定义事件
    for key, value in pairs(self._enabledMap) do
        if value then others[#others + 1] = key end
    end

    return {
        poll = true,
        monitor = false,
        other = others
    }
end

--- 定时器触发函数
function HttpReport:poll()
    if not self._enabled or self._errCount > 10 then return end

    self._pollCount = self._pollCount + 1

    -- 每 3 次 poll 发起一次 POST 请求
    if self._pollCount % 3 == 0 and not self._isWaiting then
        local time = os.epoch("utc")
        local text = textutils.serializeJSON(self._dataCache, { allow_repetitions = true, unicode_strings = true })
        local sha512 = sha2.hmac(sha2.sha512, self._httpCfg.key, text .. time)

        self._libs.log:debug("[HttpReport] Request preprocessing took", os.epoch("utc") - time, "ms")
        self._isWaiting = true

        -- 发送异步 POST 请求
        http.request({
            url = self._httpCfg.url,
            body = text,
            headers = {
                ["content-type"] = "application/json; charset=utf-8",
                ctime = tostring(time),
                csha512 = sha512
            }
        })
    end
end

--- 事件触发函数
--- @param event table 事件对象
function HttpReport:epoll(event)
    -- 第一级禁用判断
    if self._errCount > 10 then return end

    -- 红石信号处理
    if event[1] == "redstone" then
        self._enabled = self._relayObj.getInput(self._relaySide)
        self._libs.log:info("[HttpReport] Module newly enabled status:", self._enabled)
    end

    -- 数据更新
    if self._enabledMap[event[1]] then
        if self._errCount <= 10 and type(event[2]) == "table" then
            self._dataCache[event[1]] = event[2]
        end
        return
    end

    -- 第二级禁用判断
    if not self._enabled then return end

    -- HTTP 请求结果
    if event[1] == "http_success" then -- 请求成功
        local url, response = event[2], event[3]
        if url == self._httpCfg.url then
            self._isWaiting = false

            -- 数据获取
            local isOK, code, data = self:_parseResponse(response)
            if not isOK or type(data) ~= "table" then
                self._errCount = self._errCount + 1
                -- 日志输出
                self._libs.log:error("[HttpReport] HTTP response failed", " - code:", code, "err:", data)
                if self._errCount > 10 then
                    self._libs.log:fatalNoExit("[HttpReport] Network error counter triggered (>10), module terminated")
                end
                return
            end

            -- 只在有数据时处理
            if type(self._dataCache.unit_status_change) ~= "table" then
                return
            end

            -- 将要操作的单元转为Set组
            local switchSet = {}
            for _, v in ipairs(data) do
                if type(v) == "string" then
                    switchSet[v] = true
                end
            end

            -- 处理单元
            for _, cell in ipairs(self._dataCache.unit_status_change) do
                if switchSet[cell.tag] and cell.status > 2 and cell.status < 6 then
                    self._libs.net:send(
                        cell.tag,
                        200,
                        nil,
                        2,
                        function(_, nCode, isTimeout)
                            if isTimeout or nCode == 104 then
                                self._libs.log:error("[HttpReport] Failed to send control signal to", cell.tag)
                            end
                            return false
                        end
                    )
                end
            end
        end
    elseif event[1] == "http_failure" then -- 请求失败
        local url, errStatus, errResponse = event[2], event[3], event[4]
        if url == self._httpCfg.url then
            self._isWaiting = false
            self._errCount = self._errCount + 1

            -- 读取错误响应数据
            local _, code, data = self:_parseResponse(errResponse)
            local errText
            if type(data) == "table" and type(data.error) == "string" and #data.error > 0 then
                errText = data.error
            elseif type(data) == "string" and #data > 0 then
                errText = data
            else
                errText = errStatus or "Unknown Error"
            end

            -- 日志输出
            self._libs.log:error("[HttpReport] Async HTTP failed", " - code:", code, "err:", errText)
            if self._errCount > 10 then
                self._libs.log:fatalNoExit("[HttpReport] Network error counter triggered (>10), module terminated")
            end
        end
    end
end

return HttpReport
