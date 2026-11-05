--- 任务队列 (FIFO)
--- * 使用首尾双索引, pop 后即时释放槽位, 避免 table.remove 的 O(n) 搬移
--- @class TaskQueue
--- @field _first number 第一个有效数据索引
--- @field _last number 最后一个有效数据索引
--- @field _queue table<number,any> 队列数据存放表
local TaskQueue = {}
TaskQueue.__index = TaskQueue

--- 创建新队列
--- @return TaskQueue
function TaskQueue:new()
    return setmetatable({
        _first = 1,
        _last = 0,
        _queue = {}
    }, self)
end

--- 推入队列
--- @param task any 该任务的详细信息
--- @return number index 该任务在队列中的槽位
function TaskQueue:push(task)
    if task == nil then return -1 end
    local last = self._last + 1
    self._last = last
    self._queue[last] = task
    return last
end

--- 查看队首任务 (不弹出)
--- @return any
function TaskQueue:peek()
    if self._first > self._last then return nil end
    return self._queue[self._first]
end

--- 取出任务
--- @return any
function TaskQueue:pop()
    local first = self._first
    if first > self._last then return nil end

    local task = self._queue[first]
    self._queue[first] = nil -- 释放内存，防止内存泄漏
    self._first = first + 1

    -- 队列排空后复位索引, 避免索引无意义增长
    if self._first > self._last then
        self._first, self._last = 1, 0
    end

    return task
end

--- 清空队列
function TaskQueue:clear()
    for i = self._first, self._last do
        self._queue[i] = nil
    end
    self._first, self._last = 1, 0
end

--- 获取队列当前长度
--- @return number
function TaskQueue:size() return self._last - self._first + 1 end

--- 检查队列是否为空
--- @return boolean
function TaskQueue:isEmpty() return self._first > self._last end

return TaskQueue
