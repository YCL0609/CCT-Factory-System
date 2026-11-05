const UNITS = [
    [1e12, 'T'],
    [1e9, 'B'],
    [1e6, 'M'],
    [1e3, 'K'],
];

/**
 * 大数值缩写格式化
 * @param {number|string} value 原始数值
 * @param {number} [digits=2] 保留小数位
 * @returns {string}
 */
export function formatAmount(value, digits = 2) {
    const num = Number(value);
    if (!Number.isFinite(num)) return 'N/A';

    const sign = num < 0 ? '-' : '';
    const abs = Math.abs(num);
    if (abs < 1000) {
        return sign + (Number.isInteger(abs) ? String(abs) : String(abs));
    }
    for (const [threshold, suffix] of UNITS) {
        if (abs >= threshold) {
            return `${sign}${(abs / threshold).toFixed(digits)}${suffix}`;
        }
    }
    return sign + String(abs);
}

/**
 * 整数千分位格式化
 * @param {number|string} value
 * @returns {string}
 */
export function formatCount(value) {
    const num = Number(value);
    if (!Number.isFinite(num)) return 'N/A';
    return num.toLocaleString('en-US', { maximumFractionDigits: 0 });
}
