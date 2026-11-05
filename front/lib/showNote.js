import { config } from "../config.js";

/** @type {HTMLElement|null} */
let container = null;

function getContainer() {
    if (!container || !container.isConnected) {
        container = document.getElementById('note-container') || document.querySelector('.note-container');
    }
    return container;
}

/**
 * 关闭一条通知
 * @param {HTMLElement} note
 */
function closeNote(note) {
    if (!note || note.classList.contains('removing')) return;
    note.classList.add('removing');
    note.addEventListener('animationend', () => note.remove(), { once: true });
    // 兜底:动画事件在部分环境下可能不触发
    setTimeout(() => note.remove(), 800);
}

/**
 * 显示一条通知
 * @param {'info'|'warn'|'error'} level 信息等级
 * @param {string} text 显示内容
 * @param {boolean} [noTimeout=false] 是否禁用自动关闭
 * @returns {HTMLElement|null} 创建的通知节点
 */
export function showNote(level, text, noTimeout = false) {
    if (level !== 'info' && level !== 'warn' && level !== 'error') return null;
    if (text === undefined || text === null) return null;

    // 获取通知容器
    const parent = getContainer();
    if (!parent) {
        console.warn(`[${level.toUpperCase()}] ${text}`);
        return null;
    }

    // 同内容通知去重, 避免轮询失败时刷屏
    const message = String(text);
    for (const existing of parent.querySelectorAll('.note')) {
        if (existing.dataset.text === message && existing.dataset.level === level) {
            return existing;
        }
    }

    // 数量上限
    while (parent.children.length >= config.showNote.max_notes) {
        parent.firstElementChild?.remove();
    }

    // 构建div并添加到页面
    const note = document.createElement('div');
    const span = document.createElement('span');
    const btn = document.createElement('button');
    note.className = `note note-${level}`;
    note.dataset.text = message;
    note.dataset.level = level;
    note.setAttribute('role', level === 'error' ? 'alert' : 'status');
    span.className = 'note-text';
    span.textContent = message;
    btn.className = 'note-close';
    btn.type = 'button';
    btn.textContent = '\u00d7';
    btn.addEventListener('click', () => closeNote(note));
    note.append(span, btn);
    parent.appendChild(note);

    // 定时关闭逻辑
    if (!noTimeout) setTimeout(() => closeNote(note), config.showNote.auto_close_timeout);

    // 控制台输出
    const colorMap = { info: '#2ec1cc', warn: '#f39c12', error: '#e74c3c' };
    console.log(`%c[${level.toUpperCase()}] ${message}`, `color:${colorMap[level]}; font-weight:bold;`);
    return note;
}
