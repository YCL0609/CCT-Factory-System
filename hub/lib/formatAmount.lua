-- 数值后缀映射表 (从大到小)
local UNITS_MAP = {
    { 1e12, "T" },
    { 1e9,  "B" },
    { 1e6,  "M" },
    { 1e3,  "K" },
}

--- 数值格式化 (自动选择后缀)
--- @param rawNum number|string 要格式化的原始数值
--- @param digits? number 后缀单位保留的小数位 (默认 2)
--- @return string
local function formatAmount(rawNum, digits)
    local num = tonumber(rawNum)
    if not num or num ~= num then return "N/A" end
    if num == math.huge then return "inf" end
    if num == -math.huge then return "-inf" end

    digits = tonumber(digits) or 2
    if digits < 0 then digits = 0 end

    local absNum = math.abs(num)
    local sign = num < 0 and "-" or ""

    -- 处理小数值
    if absNum < 1000 then
        if absNum % 1 == 0 then
            return sign .. string.format("%d", absNum)
        end
        return sign .. tostring(absNum)
    end

    -- 匹配合适的单位
    for i = 1, #UNITS_MAP do
        local threshold, suffix = UNITS_MAP[i][1], UNITS_MAP[i][2]
        if absNum >= threshold then
            local scaled = absNum / threshold
            -- 进位保护: 999.999K 之类的情况向上抬一级
            local fmt = "%." .. digits .. "f%s"
            local text = string.format(fmt, scaled, suffix)
            return sign .. text
        end
    end

    return sign .. tostring(absNum)
end

return formatAmount
