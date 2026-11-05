local sha2 = require("lib.sha2")

--- 上报与控制类
--- * 周期性把主机侧缓存 POST 到服务端, 服务端返回"需要切换的单元 tag 列表"
--- * 通过红石继电器 (可选) 控制模块启停
--- @class HttpReport
--- @field _libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @field _enabledMap table 禁用事件映射
--- @field _dataCache table 数据缓存
--- @field _pollCount number poll计数
--- @field _errCount number 网络错误计数
--- @field _httpCfg {key:string,url:string,timeoutMs:number,nowebCtrl:boolean} http配置
--- @field _isWaiting boolean 是否正在等待上一次请求返回
--- @field _enabled boolean 是否启用模块
--- @field _relayObj table 红石控制对象
--- @field _relaySide string 红石侧面名称
local HttpReport = {}
HttpReport.__index = HttpReport

--- 允许的时间偏差 (毫秒)
HttpReport.DEFAULT_TIME_TOLERANCE = 30000
--- 连续失败多少次后自动停用模块
HttpReport.ERROR_LIMIT = 10
--- 每多少次 poll 上报一次
HttpReport.REPORT_INTERVAL = 3
--- 合法的红石侧面
HttpReport.SIDES = { "bottom", "top", "back", "front", "right", "left" }

--- 初始化上报类
--- @param cfg table 配置参数
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @return HttpReport
function HttpReport:new(cfg, libs)
    if not http then error("HTTP API is disabled", 2) end

    -- 基础配置处理
    cfg = type(cfg) == "table" and cfg or {}
    local key = type(cfg.key) == "string" and cfg.key or ""
    local url = type(cfg.url) == "string" and cfg.url or ""
    local ok, err = http.checkURL(url)
    if not ok then error(err or "Invalid report URL", 2) end
    if #key < 16 then error("Key is too short (< 16)", 2) end

    -- 红石对象处理
    local relayObj = redstone
    if type(cfg.relayName) == "string" and peripheral.isPresent(cfg.relayName) then
        relayObj = peripheral.wrap(cfg.relayName)
    end

    -- 侧面处理
    local relaySide
    for _, side in ipairs(self.SIDES) do
        if side == cfg.relaySide then
            relaySide = side
            break
        end
    end
    if not relaySide then error("Redstone side name is invalid", 2) end

    -- 读取初始启用状态 (读取失败时默认启用, 避免误停用)
    local enabled = true
    local okRead, value = pcall(relayObj.getInput, relaySide)
    if okRead then enabled = not not value end

    libs.log:info("[HttpReport] Report URL:", url)
    return setmetatable({
        _libs = libs,
        _enabledMap = {
            ae2_cache_update = not cfg.noAE2Update,
            unit_status_change = not cfg.noUnitChange,
        },
        _dataCache = {},
        _pollCount = 0,
        _errCount = 0,
        _httpCfg = {
            key = key,
            url = url,
            nowebCtrl = not not cfg.ignoreWebControl,
            timeoutMs = tonumber(cfg.timeTolerance) or self.DEFAULT_TIME_TOLERANCE,
        },
        _isWaiting = false,
        _relayObj = relayObj,
        _relaySide = relaySide,
        _enabled = enabled
    }, self)
end

--- 恒定时间比较函数 (防止时序侧信道攻击)
--- @param a string 要比较的第一个字符串
--- @param b string 要比较的第二个字符串
--- @return boolean isEqual 是否相等
function HttpReport.ConstantTimeCompare(a, b)
    if #a ~= #b then return false end

    local diff = 0
    for i = 1, #a do
        diff = diff + math.abs((string.byte(a, i) or 0) - (string.byte(b, i) or 0))
    end

    return diff == 0
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
    if type(response.close) == "function" then pcall(response.close) end

    -- 状态码校验
    if code < 0 then return false, code, "Failed to get response data" end

    -- 标头校验
    local lower = {}
    for k, v in pairs(headers) do
        if type(k) == "string" then lower[k:lower()] = v end
    end
    local ssha512 = lower.ssha512
    local stime = tonumber(lower.stime)
    if type(ssha512) ~= "string" or not stime then
        return false, code, "The 'ssha512' or 'stime' header is missing"
    end

    -- 时间偏移校验
    local time = os.epoch("utc")
    if math.abs(time - stime) > self._httpCfg.timeoutMs then -- 允许正负30s
        return false, code, "Time offset check failed"
    end

    -- 哈希校验
    local expectSign = sha2.hmac(sha2.sha512, self._httpCfg.key, bodyRaw .. lower.stime)
    --- @diagnostic disable-next-line: param-type-mismatch
    if HttpReport.ConstantTimeCompare(expectSign, ssha512:lower()) then
        return false, code, "Hash check failed"
    end

    -- 解析body
    local body
    if #bodyRaw > 0 then
        local ok, parsed = pcall(textutils.unserialiseJSON, bodyRaw)
        if not ok then
            return false, code, "JSON parsing error: " .. tostring(parsed)
        end
        body = parsed
    else
        body = {}
    end

    if type(body) ~= "table" then
        return false, code, "The response body is not a JSON object/array"
    end
    return true, code, body
end

--- 提取需要切换的单元 tag 集合
--- @param data table 服务端返回的控制表
--- @return table<string,boolean> switchSet
function HttpReport._extractSwitchSet(data)
    local switchSet = {}
    if type(data) ~= "table" then return switchSet end

    for key, value in pairs(data) do
        if type(key) == "string" and value then
            -- 对象形式: { tag = true } / { tag = 1 }
            switchSet[key] = true
        elseif type(key) == "number" and type(value) == "string" then
            -- 数组形式: [ "tag" ]
            switchSet[value] = true
        end
    end

    return switchSet
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
    if not self._enabled or self._errCount > self.ERROR_LIMIT then return end

    self._pollCount = self._pollCount + 1

    -- 每 REPORT_INTERVAL 次 poll 发起一次 POST 请求
    if (self._pollCount % self.REPORT_INTERVAL) ~= 0 or self._isWaiting then return end

    -- 没有任何数据时不上报
    local hasData = false
    for name, enabled in pairs(self._enabledMap) do
        if enabled and self._dataCache[name] ~= nil then
            hasData = true
            break
        end
    end
    if not hasData then return end

    local time = math.floor(os.epoch("utc"))
    local timeText = string.format("%d", time)

    local ok, text = pcall(textutils.serializeJSON, self._dataCache,
        { allow_repetitions = true, unicode_strings = true })
    if not ok then
        self._libs.log:error("[HttpReport] Failed to serialise the report body:", text)
        self._errCount = self._errCount + 1
        return
    end

    local sha512 = sha2.hmac(sha2.sha512, self._httpCfg.key, text .. timeText)
    self._isWaiting = true

    -- 发送异步 POST 请求
    local started, startErr = http.request({
        url = self._httpCfg.url,
        body = text,
        headers = {
            ["content-type"] = "application/json; charset=utf-8",
            ctime = timeText,
            csha512 = sha512
        }
    })
    if started == false or started == nil then
        self._isWaiting = false
        self._errCount = self._errCount + 1
        self._libs.log:error("[HttpReport] Cannot start HTTP request:", startErr)
    else
        self._libs.log:debug("[HttpReport] Report sent, size", #text, "bytes, errCount", self._errCount)
    end
end

--- 处理服务端返回的控制表
--- @param data table 控制表
function HttpReport:_applyControl(data)
    if self._httpCfg.nowebCtrl then
        self._libs.log:debug("[HttpReport] Web control requests have been disabled, skipping.")
        return
    end

    local switchSet = self._extractSwitchSet(data)
    if next(switchSet) == nil then return end

    local cells = self._dataCache.unit_status_change
    if type(cells) ~= "table" then return end

    -- 单个单元处理函数
    local function process(cell)
        if switchSet[cell.tag] and cell.status > 2 and cell.status < 6 then
            self._libs.net:send(
                cell.tag,
                200,
                nil,
                2,
                function(_, nCode, isTimeout)
                    if isTimeout or nCode == 104 then
                        self._libs.log:error("[HttpReport] Failed to send control signal to", cell.tag)
                    else
                        self._libs.log:info("[HttpReport] Control signal accepted by", cell.tag)
                    end
                    return false
                end
            )
        end
    end

    -- 单元状态表按页组织, 需要展开一层
    for _, entry in ipairs(cells) do
        if type(entry) == "table" then
            if type(entry.tag) == "string" then
                process(entry)
            else
                -- 分页结构
                for _, cell in ipairs(entry) do
                    if type(cell) == "table" and type(cell.tag) == "string" then process(cell) end
                end
            end
        end
    end
end

--- 事件触发函数
--- @param event table 事件对象
function HttpReport:epoll(event)
    if type(event) ~= "table" then return end

    -- 第一级禁用判断
    if self._errCount > self.ERROR_LIMIT then return end

    local name = event[1]

    -- 红石信号处理
    if name == "redstone" then
        local ok, value = pcall(self._relayObj.getInput, self._relaySide)
        if ok then
            local newEnabled = not not value
            if newEnabled ~= self._enabled then
                self._libs.log:info("[HttpReport] Module enabled status changed:", newEnabled)
            end
            self._enabled = newEnabled
        end
        return
    end

    -- 数据更新
    if self._enabledMap[name] then
        if type(event[2]) == "table" then
            self._dataCache[name] = event[2]
        end
        return
    end

    -- 第二级禁用判断
    if not self._enabled then return end

    if name == "http_success" then
        local url, response = event[2], event[3]
        if url ~= self._httpCfg.url then
            self._libs.log:warn("[HttpReport] Ignoring http_success for an unexpected url:", tostring(url))
            return
        end
        self._isWaiting = false

        local isOK, code, data = self:_parseResponse(response)
        if not isOK or type(data) ~= "table" then
            self._errCount = self._errCount + 1
            self._libs.log:error("[HttpReport] HTTP response failed", " - code:", code, "err:", data)
            if self._errCount > self.ERROR_LIMIT then
                self._libs.log:fatalNoExit("[HttpReport] Network error counter triggered (>10), module terminated")
            end
            return
        end

        -- 请求成功: 重置错误计数
        self._errCount = 0
        self:_applyControl(data)
    elseif name == "http_failure" then
        local url, message, response = event[2], event[3], event[4]
        if url ~= self._httpCfg.url then
            self._libs.log:warn("[HttpReport] Ignoring http_failure for an unexpected url:", tostring(url))
            return
        end
        self._isWaiting = false
        self._errCount = self._errCount + 1

        -- 服务器已响应但状态码非 2xx 时, 尝试读取其错误信息
        local errText = message
        if type(response) == "table" then
            local ok, _, data = self:_parseResponse(response)
            if ok and type(data) == "table" and type(data.error) == "string" and #data.error > 0 then
                errText = data.error
            end
        end

        self._libs.log:error("[HttpReport] Async HTTP failed", " -", tostring(errText))
        if self._errCount > self.ERROR_LIMIT then
            self._libs.log:fatalNoExit("[HttpReport] Network error counter triggered (>10), module terminated")
        end
    end
end

return HttpReport
