--- 自动更新类
--- @class AutoUpdate
--- @field _liblog Log 日志输出实例
local AutoUpdate = {}
AutoUpdate.__index = AutoUpdate

--- 初始化自动更新类
--- @param libs table 依赖库集合
--- @return AutoUpdate
function AutoUpdate:new(_, libs) return setmetatable({ _liblog = libs.log }, self) end

-- 获取需要注册的事件配置
function AutoUpdate:getEventList()
    return {
        poll = false,
        monitor = false,
        other = { "disk" }
    }
end

--- 事件触发函数
--- @param args table 事件对象
function AutoUpdate:epoll(args)
    if type(args) ~= "table" or args[1] ~= "disk" then
        return
    end

    -- 获取挂载点
    local diskPath = disk.getMountPath(args[2])
    if not diskPath then
        return self._liblog:error("[AutoUpdate] Can't get the disk mount point")
    end

    -- 获取文件列表
    local files = fs.list(diskPath)
    local count = 0

    for _, fileName in ipairs(files) do
        -- 仅匹配以 .json 结尾的文件(忽略已重命名的 .synced 文件)
        if fileName:lower():sub(-5) == ".json" then
            local sourceFile = fs.combine(diskPath, fileName)
            local destination = fs.combine("/etc", fileName)
            local markedFile = sourceFile .. ".synced"
            local oldFile = destination .. ".old"
            self._liblog:debug("[AutoUpdate] Syncing", fileName, "file ...")

            -- 同步到电脑本地
            if fs.exists(oldFile) then
                fs.delete(oldFile)
            end
            if fs.exists(destination) then
                fs.move(destination, oldFile)
            end
            fs.copy(sourceFile, destination)

            -- 重命名磁盘中的原文件以标识已同步
            if fs.exists(markedFile) then
                fs.delete(markedFile)
            end
            fs.move(sourceFile, markedFile)
            count = count + 1
        end
    end

    if count > 0 then
        self._liblog:info("[AutoUpdate] Synced", count, "files, ready to restart")
        os.queueEvent("reboot")
    else
        self._liblog:warn("[AutoUpdate] No files need to be synced on the disk")
    end
end

return AutoUpdate
