--- 加载并解析 JSON 文件 (静默失败版)
--- @param path string - JSON 文件路径
--- @return table - 解析后的数据
local function loadJson(path)
    if not fs.exists(path) or fs.isDir(path) then return {} end

    local fd = fs.open(path, "r")
    if not fd then return {} end

    local content = fd.readAll()
    fd.close()

    local success, data = pcall(textutils.unserialiseJSON, content)
    if not success then return {} end

    return data
end

return loadJson