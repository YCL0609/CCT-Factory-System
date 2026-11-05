import { getUrlParams, isMobile, loadExternalResource } from 'https://tool.ycl.cool/public-library/function.esm.min.js'; // Github: YCL0609/YCL-Public-library
import { serverCtrl } from './lib/sendControl.js';
import { showNote } from './lib/showNote.js';
import { config } from './config.js';
import { initLang, setLang, languageList, currentLang, t } from './lib/i18n.js';

/** html元素集合 */
const els = {
    initUrl: document.getElementById('init-url'),
    initPwd: document.getElementById('init-pwd'),
    initBtn: document.getElementById('init-btn'),
    backBtn: document.getElementById('back-btn'),
    reportTime: document.getElementById('report-time'),
    langSelect: document.getElementById('lang-select'),
    showType: document.getElementById('show-type'),
    showList: document.getElementById('show-list'),
    panes: [1, 2, 3, 4].map((i) => document.getElementById(`pane-${i}`)),
    cards: [
        document.getElementById('card-loading'),
        document.getElementById('card-init'),
        document.getElementById('card-list'),
        document.getElementById('card-show')
    ],
};

/** 运行状态 */
const state = {
    stage: 0,
    showType: 1,
    modules: new Map(), // name -> { name, desc, instance, selected, order }
    activeList: [],
    /** @type {serverCtrl} */
    ctrl: null,
    timer: null,
    refreshing: false,
    reportTime: null,
    selectedCount: 0,
    selectSeq: 0,
};

/** 提供给模块的上下文 */
const ctx = {
    sendData: (data) => {
        if (!data || !state.ctrl) return Promise.resolve(false);
        return state.ctrl.sendCtrl(data);
    },
    showNote,
    config: config.modules,
    getReportTime: () => state.reportTime,
    /** 是否只读模式 (未提供操作密钥) */
    get readonly() {
        return state.ctrl?.readonly === true;
    },
};

/**
 * 切换当前显示的卡片
 * @param {number} index 卡片序号 (0-3)
 */
function switchCard(index) {
    if (index < 0 || index > 3) return;
    state.stage = index;
    els.cards.forEach((card, i) => card.classList.toggle('active', i === index));
    els.backBtn.hidden = index < 2;
}

/** 停止轮询 */
function stopRefresh() {
    if (state.timer !== null) {
        clearInterval(state.timer);
        state.timer = null;
    }
}

/** 启动轮询 */
function startRefresh() {
    stopRefresh();
    if (document.hidden) return;
    state.timer = setInterval(refresh, config.main.refresh_interval);
}

/**
 * 更新报告时间显示
 * @param {number|null} stamp 报告时间戳 (毫秒)
 */
function updateReportTime(stamp) {
    if (!stamp || Number.isNaN(Number(stamp))) {
        els.reportTime.textContent = t('app.na');
        els.reportTime.dataset.stale = '1';
        state.reportTime = null;
        return;
    }
    const date = new Date(Number(stamp));
    const text = [date.getHours(), date.getMinutes(), date.getSeconds()]
        .map((n) => String(n).padStart(2, '0'))
        .join(':');
    els.reportTime.textContent = text;
    els.reportTime.dataset.stale = Date.now() - Number(stamp) > config.main.stale_after ? '1' : '0';
    state.reportTime = Number(stamp);
}

/** 拉取一次数据并驱动所有模块 */
async function refresh() {
    if (!state.ctrl || state.refreshing) return;
    state.refreshing = true;
    try {
        // 获取数据
        const { ok, data, error, errorCode } = await state.ctrl.getData();
        if (!ok) {
            if (![0, 404].includes(errorCode)) {
                showNote('warn', t('note.noData', { error }));
            }
            updateReportTime(null);
            return;
        }
        if (!data) {
            // 服务器尚未收到任何上报
            updateReportTime(null);
            return;
        }
        updateReportTime(Number(data.report_time));

        // 生成数据处理函数集合
        const tasks = [];
        for (const [name, cell] of state.modules) {
            if (typeof cell.instance?.dataUpdate !== 'function') continue;
            tasks.push(
                Promise.resolve()
                    .then(() => cell.instance.dataUpdate(data.data, ctx))
                    .catch((e) => {
                        console.error(e);
                        showNote('warn', t('note.moduleDataFailed', { name, error: e?.message || e }));
                    }),
            );
        }

        // 运行处理函数
        await Promise.allSettled(tasks);

        if (state.stage === 3) {
            // 显示到页面
            await renderPanes(false);
        }
    } finally {
        state.refreshing = false;
    }
}

/**
 * 把已选模块渲染到各自的 cell 中
 * @param {boolean} isFirst 是否为切换后的首次渲染
 */
async function renderPanes(isFirst) {
    // 生成渲染函数集合
    const tasks = state.activeList.map(async (name, index) => {
        const pane = els.panes[index];
        const instance = state.modules.get(name)?.instance;
        if (!pane || typeof instance?.divUpdate !== 'function') return Promise.resolve();

        let timer;
        const timeout = new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(t('note.renderTimeout'))), config.main.render_timeout);
        });
        try {
            try {
                return await Promise.race([
                    Promise.resolve().then(() => instance.divUpdate(pane, isFirst, ctx)),
                    timeout,
                ]);
            } finally {
                return clearTimeout(timer);
            }
        } catch (e) {
            console.error(e);
            showNote('warn', t('note.moduleRenderFailed', { name, error: e?.message || e }));
        }
    });

    // 运行所有渲染函数
    await Promise.allSettled(tasks);
}

/**
 * 选中/取消选中一个模块
 * @param {string} name 模块标识
 * @param {boolean} selected
 */
function setModuleSelected(name, selected) {
    const cell = state.modules.get(name);
    if (!cell || cell.selected === selected) return;

    if (selected) {
        if (state.selectedCount >= state.showType) {
            showNote('warn', t('note.selectLimit', { max: state.showType }));
            return;
        }
        cell.selected = true;
        cell.order = ++state.selectSeq;
        state.selectedCount += 1;
    } else {
        cell.selected = false;
        cell.order = 0;
        state.selectedCount = Math.max(0, state.selectedCount - 1);
    }

    const card = els.showList.querySelector(`[data-name="${CSS.escape(name)}"]`);
    if (card) card.classList.toggle('selected', cell.selected);
}

/**
 * 切换显示模式 (1-4 分屏)
 * @param {number} value
 */
function setShowType(value) {
    const type = Math.min(4, Math.max(1, Number(value) || 1));
    state.showType = type;
    for (const btn of els.showType.querySelectorAll('.show-type-btn')) {
        const active = Number(btn.dataset.type) === type;
        btn.classList.toggle('active', active);
    }
    // 超出新上限的模块自动取消选择
    for (const [name, cell] of state.modules) {
        if (cell.selected && state.selectedCount > type) setModuleSelected(name, false);
    }
}

/**
 * 进入数据显示卡片
 */
async function showCards() {
    const selected = [...state.modules.values()]
        .filter(cell => cell.selected)
        .sort((a, b) => a.order - b.order)
        .map(cell => cell.name);

    if (selected.length !== state.showType) {
        showNote('warn', t('note.selectMismatch', { selected: selected.length, expected: state.showType }));
        return;
    }

    state.activeList = selected;
    els.cards[3].dataset.type = String(state.showType);

    // 清空 pane, 使模块以 isFirst=true 重建视图
    for (const pane of els.panes) pane.replaceChildren();

    switchCard(3);
    await renderPanes(true);
}

/**
 * 加载并展示模块列表
 */
async function loadModules(preselect) {
    // 加载启动的模块列表
    let list;
    try {
        const response = await fetch('./module/activated.json');
        if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
        list = await response.json();
        if (!Array.isArray(list)) throw new Error(t('note.listFormat'));
    } catch (e) {
        showNote('error', t('note.loadListFailed', { error: e?.message || e }), true);
        return 0;
    }

    // 遍历加载模块
    let loaded = 0;
    const fragment = document.createDocumentFragment();
    for (const entry of list) {
        if (!entry || typeof entry !== 'object') {
            showNote('warn', t('note.moduleConfigInvalid'));
            continue;
        }

        const name = String(entry.name ?? '').replace(/[^A-Za-z0-9_.-]/g, '');
        if (!name || !config.main.module_name_regx.test(name)) {
            showNote('warn', t('note.moduleNameInvalid'));
            continue;
        }
        if (state.modules.has(name)) {
            showNote('warn', t('note.moduleDuplicated', { name }));
            continue;
        }

        try {
            // 加载模块本体
            const module = await import(`./module/${name}/index.js`);
            const instance = new module.default();
            if (typeof instance.init === 'function') await instance.init(ctx);

            // 引入可能的css样式
            if (entry.css) await loadExternalResource(`./module/${name}/index.css`, 'css');

            // 加入模块Map
            state.modules.set(name, {
                name,
                descFallback: String(entry.desc ?? ''),
                desc: t(`modules.${name}.desc`, null, String(entry.desc ?? '')),
                instance,
                selected: false,
                order: 0,
            });

            // 创建卡片容器
            const card = document.createElement('button');
            const title = document.createElement('span');
            const desc = document.createElement('span');
            card.type = 'button';
            card.className = 'module-card';
            card.dataset.name = name;
            title.className = 'module-name';
            title.textContent = name;
            desc.className = 'module-desc';
            desc.textContent = t(`modules.${name}.desc`, null, String(entry.desc ?? ''));
            card.addEventListener('click', () => {
                const cell = state.modules.get(name);
                setModuleSelected(name, !cell.selected);
            });

            // 添加到页面分片
            card.append(title, desc);
            fragment.appendChild(card);
            loaded++;
        } catch (e) {
            console.error(e);
            showNote('warn', t('note.moduleLoadFailed', { name, error: e?.message || e }));
        }
    }

    if (loaded > 0) {
        els.showList.replaceChildren(fragment);
        // 超出模块数量的显示模式按钮隐藏
        for (const btn of els.showType.querySelectorAll('.show-type-btn')) {
            btn.hidden = Number(btn.dataset.type) > loaded;
        }
        if (!isMobile()) setShowType(1);
    }

    // 预选 (来自 URL 参数)
    if (preselect?.length) {
        const target = Math.min(4, preselect.length);
        setShowType(target);
        for (const name of preselect) {
            if (state.modules.has(name)) setModuleSelected(name, true);
        }
    }

    return loaded;
}

/**
 * 刷新模块卡片上的描述文案 (语言切换后调用)
 */
function renderModuleDesc() {
    for (const [name, cell] of state.modules) {
        const card = els.showList.querySelector(`[data-name="${CSS.escape(name)}"]`);
        const descEl = card?.querySelector('.module-desc');
        if (!descEl) continue;
        cell.desc = t(`modules.${name}.desc`, null, cell.descFallback);
        descEl.textContent = cell.desc;
    }
}

/**
 * 初始化语言选择器
 */
async function initLangPicker() {
    const picker = els.langSelect;
    if (!picker) return;

    const list = await languageList();
    // 只有一种语言时不显示选择器
    if (list.length < 2) {
        picker.hidden = true;
        return;
    }

    picker.replaceChildren(...list.map(({ id, name }) => {
        const option = document.createElement('option');
        option.value = id;
        option.textContent = name;
        return option;
    }));
    picker.value = currentLang();
    picker.hidden = false;
    picker.addEventListener('change', () => {
        setLang(picker.value).catch((e) => {
            console.error(e);
            showNote('error', e?.message || String(e));
        });
    });
}

/**
 * 语言切换后的重绘
 * @param {CustomEvent} event
 */
async function onLangChanged(event) {
    const lang = event.detail?.info?.name ?? event.detail?.lang ?? currentLang();
    renderModuleDesc();
    if (state.stage === 3) {
        for (const pane of els.panes) pane.replaceChildren();
        await renderPanes(true);
    }
    showNote('info', t('note.langChanged', { lang }));
}

/**
 * 读取表单并建立连接
 * @returns {Promise<boolean>}
 */
async function connect() {
    if (state.stage !== 1) return false;

    // 获取用户输入
    const url = els.initUrl.value.trim();
    const key = els.initPwd.value.trim();
    if (!url) {
        showNote('warn', t('note.needUrl'));
        els.initUrl.focus();
        return false;
    }

    els.initBtn.disabled = true;
    try {
        // 初始化服务器连接
        const ctrl = new serverCtrl(url, key);
        const probe = await ctrl.getData();
        if (!probe.ok) {
            showNote('error', t('note.connectFailed', { error: probe.error ?? t('app.unknownError') }));
            return false;
        }
        state.ctrl = ctrl;

        // 提提示信息
        if (ctrl.readonly) {
            showNote('info', t('note.readonlyMode'));
        } else if (!(await ctrl.ping())) {
            showNote('warn', t('note.pingFailed'));
        }

        // 切换卡片并开启数据循环
        switchCard(2);
        await refresh();
        startRefresh();

        return true;
    } catch (e) {
        showNote('error', e?.message || String(e));
        return false;
    } finally {
        els.initBtn.disabled = false;
    }
}

/** 页面初始化 */
async function initPage() {
    const started = performance.now();

    // 初始化多语言 (必须在渲染任何静态/动态文案之前)
    await initLang();
    await initLangPicker();

    const params = getUrlParams();

    // URL指定服务器地址
    if (params.server) {
        els.initUrl.value = decodeURIComponent(params.server);
    }

    // URL预选模块
    const preselect = [];
    if (params.select) {
        for (const raw of String(params.select).split(',')) {
            const name = raw.replace(/[/\\,]/g, '').trim();
            if (name && config.main.module_name_regx.test(name) && !preselect.includes(name)) {
                preselect.push(name);
            }
        }
    }

    // 加载模块
    const loaded = await loadModules(preselect);
    const cost = (performance.now() - started).toFixed(0);
    if (loaded > 0) {
        showNote('info', t('note.loaded', { count: loaded, cost }));
    }
    switchCard(1);

    // 自动模式
    if (!!params.auto) {
        // 连接服务器
        if (!(await connect())) return;
        // 应用显示模式
        const mode = Number(params.mode);
        if (Number.isFinite(mode) && mode >= 1 && mode <= 4) setShowType(mode);
        // 进入模块展示界面
        const pending = [...state.modules.values()].filter(c => c.selected).length;
        if (pending === state.showType && pending > 0) {
            await showCards();
        } else {
            showNote('warn', t('note.autoNotEnough', { selected: pending, expected: state.showType }));
        }
    }
}

// 连接服务器按钮
document.getElementById('init-form').addEventListener('submit', (e) => {
    e.preventDefault();
    connect();
});

// 开始显示数据卡片
document.getElementById('show-btn').addEventListener('click', showCards);

// 返回按钮
els.backBtn.addEventListener('click', () => {
    if (state.stage == 3) {
        // 返回模块列表
        switchCard(2);
    } else if (state.stage === 2) {
        // 返回服务器信息输入界面
        stopRefresh();
        state.ctrl = null;
        switchCard(1);
    }
});

// 显示模式选项
els.showType.addEventListener('click', (e) => {
    const btn = e.target.closest('.show-type-btn');
    if (!btn || btn.hidden) return;
    setShowType(Number(btn.dataset.type));
});

// 页面可视性事件
document.addEventListener('visibilitychange', () => {
    if (!state.ctrl) return;
    if (document.hidden) {
        // 不可视时停止数据获取
        stopRefresh();
    } else {
        // 重新启动循环
        refresh();
        startRefresh();
    }
});

// 语言切换事件
document.addEventListener('langchange', (e) => {
    onLangChanged(e).catch((err) => console.error(err));
});

// 初始化事件
document.addEventListener('DOMContentLoaded', () => {
    initPage().catch(e => showNote('error', t('note.initFailed', { error: e?.message || e }), true));
});
