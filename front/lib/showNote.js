/**
 * 提示信息显示
 * @param {'info'|'warn'|'error'} level 信息等级
 * @param {string} text 要显示的内容
 * @param {boolean} [noTimeout=false] 禁用定时关闭
 */
export function showNote(level, text, noTimeout) {
    if (level !== 'info' && level !== 'warn' && level !== 'error') return;

    // 构建容器
    const container = document.querySelector('.note-container');
    const note = document.createElement('div');
    const span = document.createElement('span');
    const btn = document.createElement('button');

    // 信息填入
    note.className = `note note-${level}`;
    span.className = 'note-text';
    btn.className = 'note-close';
    btn.innerText = '\u00d7';
    span.innerText = text;

    // 添加到页面
    note.appendChild(span);
    note.appendChild(btn);
    container.appendChild(note);

    // 点击关闭事件
    btn.onclick = () => {
        note.classList.add('removing');
        note.addEventListener('animationend', () => note.remove(), { once: true });
    };

    // 8秒后自动关闭
    if (!noTimeout) setTimeout(() => {
        if (note.parentNode) {
            note.classList.add('removing');
            note.addEventListener('animationend', () => note.remove(), { once: true });
        }
    }, 8000);

    // 控制台输出
    const levelLabel = level.toUpperCase();
    const colorMap = {
        info: '#2ec1cc',
        warn: '#f39c12',
        error: '#e74c3c'
    };
    console.log(`%c[${levelLabel}] ${text}`, `color:${colorMap[level]}; font-weight:bold;`);
}