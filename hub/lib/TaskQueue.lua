--- 任务队列
--- @class TaskQueue
--- @field _first number 第一个有效数据索引
--- @field _last number 最后一个有效数据索引
--- @field _queue table<number,any> 队列数据存放表
local TaskQueue = {}
TaskQueue.__index = TaskQueue

-- 创建新队列
function TaskQueue:new()
    return setmetatable({
        _first = 1,
        _last = 0,
        _queue = {}
    }, self)
end

--- 推入队列
--- @param task any 该任务的详细信息
function TaskQueue:push(task)
    if task == nil then return end
    local last = self._last + 1
    self._last = last
    self._queue[last] = task
end

--- 查看队首任务
function TaskQueue:peek()
    local first = self._first
    if first > self._last then
        return nil -- 队列为空
    end

    return self._queue[first]
end

--- 取出任务
function TaskQueue:pop()
    local first = self._first
    if first > self._last then
        return nil -- 队列为空
    end

    local task = self._queue[first]
    self._queue[first] = nil -- 释放内存，防止内存泄漏
    self._first = first + 1
    return task
end

--- 获取队列当前长度
--- @return number
function TaskQueue:size() return self._last - self._first + 1 end

--- 检查队列是否为空
--- @return boolean
function TaskQueue:isEmpty() return self._first > self._last end

return TaskQueue
