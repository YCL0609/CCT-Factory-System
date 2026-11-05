--- 自动更新类
--- * 插入软盘(或磁盘驱动器)后, 自动把盘内 *.json 同步到主机的 /etc 目录
--- * 同步前会校验 JSON 合法性, 失败的配置不会被写入
--- @class AutoUpdate
--- @field _liblog Log 日志输出实例
--- @field _libs {log:Log, net:MiniNet, root:string} 依赖库集合
local AutoUpdate = {}
AutoUpdate.__index = AutoUpdate

--- 初始化自动更新类
--- @param libs {log:Log, net:MiniNet, root:string} 依赖库集合
--- @return AutoUpdate
function AutoUpdate:new(_, libs)
    return setmetatable({ _liblog = libs.log, _libs = libs }, self)
end

-- 获取需要注册的事件配置
function AutoUpdate:getEventList()
    return {
        poll = false,
        monitor = false,
        other = { "disk" }
    }
end

--- 校验文件是否为合法的 JSON 对象/数组
--- @param path string 文件路径
--- @return boolean isOK
--- @return string|nil err
function AutoUpdate._validateJson(path)
    local fd = fs.open(path, "r")
    if not fd then return false, "cannot open file" end
    local content = fd.readAll()
    fd.close()

    if type(content) ~= "string" or content == "" then
        return false, "empty file"
    end
    local ok, data = pcall(textutils.unserialiseJSON, content)
    if not ok then return false, "invalid JSON: " .. tostring(data) end
    if type(data) ~= "table" then return false, "root value is not a table/array" end
    return true
end

--- 事件触发函数
--- @param args table 事件对象
function AutoUpdate:epoll(args)
    if type(args) ~= "table" or args[1] ~= "disk" then
        return
    end

    -- 获取挂载点
    --- @diagnostic disable-next-line: redundant-parameter
    local diskPath = disk.getMountPath(args[2])
    if not diskPath then
        return self._liblog:error("[AutoUpdate] Can't get the disk mount point")
    end

    -- 获取文件列表
    local files = fs.list(diskPath)
    local count = 0
    local failed = 0
    local etcRoot = (self._libs.root or "") .. "/etc"

    for _, fileName in ipairs(files) do
        -- 仅匹配以 .json 结尾的文件(忽略已重命名的 .synced 文件)
        if type(fileName) == "string" and fileName:lower():sub(-5) == ".json" then
            local sourceFile = fs.combine(diskPath, fileName)

            if fs.isDir(sourceFile) then
                self._liblog:warn("[AutoUpdate] Skipping directory", fileName)
            else
                local valid, reason = self._validateJson(sourceFile)
                if not valid then
                    failed = failed + 1
                    self._liblog:error("[AutoUpdate] Invalid config", fileName .. ":", reason, "- skipped")
                else
                    local dest = fs.combine(etcRoot, fileName)
                    local markedName = sourceFile .. ".synced"
                    local oldFile = dest .. ".old"
                    self._liblog:debug("[AutoUpdate] Syncing", fileName, "file ...")

                    -- 同步到电脑本地
                    if fs.exists(oldFile) then
                        pcall(fs.delete, oldFile)
                    end
                    if fs.exists(dest) then
                        pcall(fs.move, dest, oldFile)
                    end
                    
                    local copied = pcall(fs.copy, sourceFile, dest)
                    if not copied then
                        -- 回滚旧配置, 避免配置丢失
                        if fs.exists(oldFile) then pcall(fs.move, oldFile, dest) end
                        failed = failed + 1
                        self._liblog:error("[AutoUpdate] Failed to copy", fileName, "- configuration rolled back")
                    else
                        -- 重命名磁盘中的原文件以标识已同步
                        if fs.exists(markedName) then
                            pcall(fs.delete, markedName)
                        end
                        pcall(fs.move, sourceFile, markedName)
                        count = count + 1
                    end
                end
            end
        end
    end

    if count > 0 then
        self._liblog:info("[AutoUpdate] Synced", count, "files, ready to restart")
        if failed > 0 then
            self._liblog:warn("[AutoUpdate]", failed, "files were skipped due to errors")
        end
        os.queueEvent("reboot")
    elseif failed > 0 then
        self._liblog:error("[AutoUpdate]", failed, "files failed to sync, no restart")
    else
        self._liblog:warn("[AutoUpdate] No files need to be synced on the disk")
    end
end

return AutoUpdate
