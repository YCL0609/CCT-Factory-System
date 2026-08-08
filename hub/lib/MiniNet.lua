--- 任务结构
---@class QueueItem
---@field rawCount number 原始计数
---@field count number 当前计数
---@field onChange? boolean 防并发锁
---@field callback fun(taskId: string, code: number|nil, isTimeout: boolean, returnedData?: any): isKeep:boolean 信息回调函数 (code:网络状态码 taskId: 任务ID, isTimeout: 是否超时, returnedData?: 对方返回的数据) [返回的boolean决定是否继续监听此任务]

--- 小型网络库
--- @class MiniNet
--- @field _cId number 当前计算机ID
--- @field _net table 网络实例
--- @field _emptyFunc fun() 空函数，用于防止队列的callback不是函数
--- @field _taskList {count:number,queue:table<string,QueueItem>} 任务队列
local MiniNet = {}
MiniNet.__index = MiniNet

--- 构造器函数
--- @param netName? string 无线调制解调器外设名称 (不提供则使用遍历到的第一个无线调制解调器)
function MiniNet:new(netName)
    -- 获取实例
    local obj
    if peripheral.isPresent(tostring(netName)) then
        obj = peripheral.wrap(netName)
        if not obj.isWireless() then
            error("MiniNet error: Not a wireless peripheral!", 2)
        end
    else
        for _, v in ipairs({ peripheral.find("modem") }) do
            if v.isWireless() then
                obj = v
                break
            end
        end
    end
    if not obj then
        error("MiniNet error: Unable to get the peripheral instance!", 2)
    end

    return setmetatable({
        _cId = os.getComputerID(),
        _taskList = {
            count = 0,
            queue = {},
        },
        _emptyFunc = function() end,
        _net = obj
    }, self)
end

-- 网络状态码:
--   1xx (19x 为保留段, 用于姊妹状态码) --------
--      100 - 主机上线信号
--      101 - 主机离线信号
--      102 - 主机同步 mid 表
--              * 整个 data 字段就是 mid 表
--              * mid 表示例: { ["<tag_name>"] = "<mid>" }
--      103 - ACK 包
--      104 - NCK 包
--      193 - ACK Ping 包
--      194 - NCK Ping 包
--      105 - 客户端连接建立请求
--      106 - 客户端连接确认请求
--              * payload.tag 字段固定为 "CLIENT"
--              * 后续通信用的 mid 在 data.mid 中
--      107 -- 客户端断开连接请求
--   2xx -------------------------------------
--      200 - 单元状态切换请求
--              * 指定单元为 paylad 字段的 tag , 若 paylad.tag 为"ALL"则代表所有单元
--      201 - 指定单元状态请求
--              * 指定单元为 paylad 字段的 tag , 此状态码禁止使用 "ALL" 作为 paylad.tag
--              * 仅可用于使用 "Stopped" 和 "Running" 的单元
--              * 指定的单元状态为 data 字段的 data.status <boolean>
--      202 - 切换指定单元的禁用状态
--              * 指定单元为 payload 字段的 tag , 若 paylad.tag 为 "ALL" 则代表所有单元
--              * 指定的单元禁用状态为 data 字段的 data.status <boolean>
--              * 此状态可被物理层面的信号覆盖
--              * 返回 ACK 表明已成功禁用, 返回 NCK 表明与物理层面信号冲突
--      203 - 指定单元告警状态触发
--              * 指定单元为 paylad 字段的 tag , 此状态码禁止使用 "ALL" 作为 paylad.tag
--              * 告警事件 tag 为 data 字段的 data.tag
--              * 告警还是恢复存储在 data 字段的 data.status <boolean>
--      204 - 主机运行数据广播
--              * payload.tag 字段固定为 "CLIENT"
--              * 数据类型为 data 字段的 data.type 指定, 内容为触发的事件名称
--              * 数据本身为 data 字段的 data.data 字段

--- 定时器触发函数: 处理超时
function MiniNet:poll()
    if self._taskList.count == 0 then return end

    -- 处理超时
    for id, task in pairs(self._taskList.queue) do
        task.onChange = true -- 加锁

        if task.count <= 0 then
            if not task.callback(id, nil, true) then
                -- 删除任务
                self._taskList.queue[id] = nil
                self._taskList.count = self._taskList.count - 1
            else
                -- 恢复计数
                task.count = task.rawCount
                task.onChange = false
            end
        else
            -- 计数减一
            task.count = task.count - 1
            task.onChange = false
        end
    end
end

--- 事件触发函数: 处理返回值
--- @param data table 事件对象
function MiniNet:epoll(data)
    if self._taskList.count == 0 or type(data[5]) ~= "table" then return end

    -- 处理事件
    local id = data[5].mid or " "
    local task = self._taskList.queue[id]
    if task and type(data[5].code) == "number" then
        local rawCode = data[5].code or 0

        -- 控制位检测 (仅响应 1xx 系列)
        if math.floor(rawCode / 100) ~= 1 then return end

        task.onChange = true -- 加锁
        if not task.callback(id, rawCode, false, data[5].data) then
            -- 删除任务
            self._taskList.queue[id] = nil
            self._taskList.count = self._taskList.count - 1
        else
            -- 恢复计数
            task.count = task.rawCount
            task.onChange = false
        end
    end
end

--- 发送信息
--- @param tag string 接收方tag
--- @param code number 协议状态码
--- @param data any 要发送的数据载荷
--- @param tCount? number 允许的超时时间倍数 (基于调用 poll() 的间隔计算)
--- * 当前类本身被设计为不提供自身计时器，此处基于调用 poll() 的间隔计算
--- * 需注意: 若 poll() 的调用方调用间隔过长会导致超时时间的基础乘数过大!
--- @param callback? fun(taskId: string, code: number|nil, isTimeout: boolean, returnedData?: any): isKeep:boolean 信息回调函数 (code:网络状态码 taskId: 任务ID, isTimeout: 是否超时, returnedData?: 对方返回的数据) [返回的boolean决定是否继续监听此任务]
--- * `taskId` — 任务全局唯一 ID
--- * `code` — 网络状态码 (超时时为空)
--- * `isTimeout` — 是否超时
--- * `returnedData` — 成功时返回的数据 (可选)
--- * 函数返回值需是 boolean 用于确认是否继续保留此网络任务
--- @return string taskId 当前网络请求的任务ID
function MiniNet:send(tag, code, data, tCount, callback)
    -- 基础信息预处理
    local func = type(callback) == "function" and callback or self._emptyFunc
    local count = 0
    if type(tCount) == "number" and tCount > 0 then
        count = tCount - 1
    end

    -- 生成消息id
    local mid = self:genMessageID(1)[1]

    -- 发送信息
    self:broadcast(tag, code, data, mid)

    -- 加入队列
    self._taskList.queue[mid] = {
        onChange = false,
        rawCount = count,
        callback = func,
        count = count
    }
    self._taskList.count = self._taskList.count + 1

    return mid
end

--- 生成消息ID
--- @param count? number 要生成的ID数量(默认 1)
--- @return table<string> ids 若count等于1则返回字符串否则返回字符串表
function MiniNet:genMessageID(count)
    if type(count) ~= "number" or count < 1 then
        count = 1
    end

    local ids = {}

    for i = 1, count, 1 do
        local mId
        repeat
            local utc = tostring(os.epoch("utc"))
            local clock = tostring(math.floor(os.clock() * 1000))
            local random = tostring(math.random(1, 999))
            mId = utc .. "_" .. clock .. "_" .. random
        until not self._taskList.queue[mId]
        ids[i] = mId
    end

    return ids
end

--- 广播信息
--- @param tag string 接收方tag
--- @param code number 协议状态码
--- @param data? any 要发送的数据载荷
--- @param mid? string 消息ID (可选)
function MiniNet:broadcast(tag, code, data, mid)
    self._net.transmit(self._cId, self._cId, {
        tag = tag,
        code = code,
        mid = mid,
        data = data,
    })
end

--- 原始任务列表物品
--- @class RawTaskItem
--- @field mid string 任务唯一ID
--- @field rawCount number 允许的超时次数计数
--- @field callback? fun(taskId: string, code: number|nil, isTimeout: boolean, returnedData?: any): isKeep:boolean 信息回调函数 (code:网络状态码 taskId: 任务ID, isTimeout: 是否超时, returnedData?: 对方返回的数据) [返回的boolean决定是否继续监听此任务]

--- 开始多个网络任务
--- @param tasks table<number, RawTaskItem> 要开启的网络任务集合
function MiniNet:startTasks(tasks)
    for _, t in ipairs(tasks) do
        if
            type(t) == "table"
            and type(t.mid) == "string"
            and type(t.rawCount) == "number"
        then
            self._taskList.queue[t.mid] = {
                onChange= false,
                rawCount = t.rawCount,
                callback = t.callback or self._emptyFunc,
                count = t.rawCount + 1 -- 添加一次超时计数来进行初始化容错
            }
            self._taskList.count = self._taskList.count + 1
        end
    end
end

--- 停止指定网络任务
--- @param taskId string 任务全局唯一 ID
--- @return boolean isOK 是否成功
function MiniNet:stopTask(taskId)
    if type(taskId) == "string" and self._taskList.queue[taskId] and not self._taskList.queue[taskId].onChange then
        self._taskList.queue[taskId] = nil
        self._taskList.count = self._taskList.count - 1
        return true
    else
        return false
    end
end

--- 开启网络频道
--- @param ids number|table 要开启的网络频道/要开启的网络频道数组
function MiniNet:open(ids)
    if type(ids) == "number" and ids >= 0 and ids <= 65535 then
        self._net.open(ids)
    elseif type(ids) == "table" then
        for _, id in ipairs(ids) do
            if id >= 0 and id <= 65535 then
                self._net.open(id)
            end
        end
    end
end

--- 关闭网络实例
function MiniNet:close()
    self._net.transmit(self._cId, self._cId, {
        tag = "ALL",
        code = 101,
    })
    self._net.closeAll()
    os.sleep(0.5)
    self._taskList.count = 0
    self._taskList.queue = {}
end

return MiniNet
