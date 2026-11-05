--- 加载并解析 JSON 文件
--- @param path string JSON 文件路径
--- @return table data 解析后的数据 (失败时为空表)
--- @return any err 失败原因
local function loadJson(path)
    if type(path) ~= "string" or path == "" then
        return {}, "invalid path"
    end
    if not fs.exists(path) then return {}, "file not found" end
    if fs.isDir(path) then return {}, "path is a directory" end

    local fd, openErr = fs.open(path, "r")
    if not fd then return {}, openErr or "cannot open file" end

    local content = fd.readAll()
    fd.close()
    if type(content) ~= "string" or content == "" then
        return {}, "empty file"
    end

    local ok, data = pcall(textutils.unserialiseJSON, content)
    if not ok then return {}, data end
    if type(data) ~= "table" then return {}, "root value is not a table" end

    return data
end

return loadJson
