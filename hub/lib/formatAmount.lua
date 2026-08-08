-- 数值后缀映射表
local UNITS_MAP = {
    { 1e12, "T" },
    { 1e9,  "B" },
    { 1e6,  "M" },
    { 1e3,  "K" },
}

--- 数值格式化（支持自动选择后缀）
--- @param num number 要格式化的原始数值
--- @return string
local function formatAmount(num)
    local absNum = math.abs(num)
    local sign = num < 0 and "-" or ""

    -- 处理小数值
    if absNum < 1000 then
        return sign .. tostring(absNum)
    end

    -- 匹配合适的单位
    for i = 1, #UNITS_MAP do
        local unit = UNITS_MAP[i]
        local threshold = unit[1]
        local suffix = unit[2]
        if absNum >= threshold then
            local scaled = absNum / threshold
            return string.format("%s%.2f%s", sign, scaled, suffix)
        end
    end

    return sign .. tostring(absNum)
end

return formatAmount