import { formatAmount, formatCount } from '../../lib/format.js';
import { t } from '../../lib/i18n.js';

export default class AEMonitor {
    /** 已过滤的配置 */
    #config = { items: [], fluids: [], reverses: new Set() };
    /** 最近一次采集到的数据 */
    #data = { items: {}, fluids: {} };
    /** 上次渲染的数值 (用于趋势判断) */
    #trend = { items: {}, fluids: {} };
    /** 单节点渲染状态 (以 DOM 节点为键, 节点被替换后自动回收) */
    static #nodeState = new WeakMap();
    /** 匹配MC ID */
    static MCID_regx = /^[a-z0-9_.-]+:[a-z0-9_.-]+$/

    /**
     * 初始化
     * @param {{showNote: Function}} ctx
     */
    async init(ctx) {
        // 获取列表
        const url = new URL('./list.json', import.meta.url);
        const response = await fetch(url.href, { cache: 'no-store' });
        if (!response.ok) {
            throw new Error(t('modules.AEMonitor.listFetchFailed', { status: response.status, statusText: response.statusText }));
        }
        const config = await response.json();

        /**
         * 清理函数
         * @param {Array} list 要清理的数据数组
         * @param {String} label 数据标签 
         * @returns {Array} 清理后的数据数组
         */
        const clean = (list, label) => {
            if (!Array.isArray(list)) throw new Error(t('modules.AEMonitor.invalidList', { label }));
            const result = [];
            for (const item of list) {
                if (typeof item === 'string' && AEMonitor.MCID_regx.test(item)) {
                    result.push(item);
                } else {
                    ctx?.showNote?.('warn', t('modules.AEMonitor.ignoreEntry', { label, value: String(item) }));
                }
            }
            return result;
        };

        // 清理列表
        this.#config.items = clean(config.items, 'items');
        this.#config.fluids = clean(config.fluids, 'fluids');
        const reverses = Array.isArray(config.reverses) ? config.reverses : [];
        this.#config.reverses = new Set(reverses.filter((v) => typeof v === 'string' && AEMonitor.MCID_regx.test(v)));

        /**
         * 初始化ID Map
         * @param {Array} ids 原始ID数组 
         * @returns {object} 映射后的表
         */
        const initMap = (ids) => {
            const map = {};
            for (const id of ids) map[id] = { count: 0, known: false };
            return map;
        };

        // 初始化映射
        this.#data.items = initMap(this.#config.items);
        this.#data.fluids = initMap(this.#config.fluids);
    }

    /**
     * 数据更新
     * @param {object} data 主机上报的数据体
     */
    dataUpdate(data) {
        const cache = data?.ae2_cache_update;
        if (!cache || typeof cache !== 'object') return;

        for (const type of ['items', 'fluids']) {
            const incoming = cache[type];
            if (!incoming || typeof incoming !== 'object') continue;
            for (const id of this.#config[type]) {
                const entry = incoming[id];
                const raw = Number(entry?.amount);
                const target = this.#data[type][id] ??= { count: 0, known: false };

                if (!Number.isFinite(raw)) {
                    target.known = false;
                    continue;
                }
                // 主机端已把流体 amount 换算为桶 (B), 这里直接使用原值
                target.count = raw;
                target.known = true;
                target.displayName = typeof entry?.displayName === 'string' ? entry.displayName : undefined;
            }
        }
    }

    /**
     * 渲染到指定节点
     * @param {HTMLElement} node
     * @param {boolean} isFirst
     */
    divUpdate(node, isFirst) {
        let view = AEMonitor.#nodeState.get(node);

        if (isFirst || !view || !view.table.isConnected) {
            // 初始化
            node.replaceChildren();
            view = this.#buildView(node);
            AEMonitor.#nodeState.set(node, view);
        }

        const now = { items: {}, fluids: {} };
        for (const type of ['items', 'fluids']) {
            for (const id of this.#config[type]) {
                const state = this.#data[type][id] ?? { count: 0, known: false };
                now[type][id] = state.count;
                this.#renderRow(view.rows.get(`${type}:${id}`), state, this.#trend[type][id], id);
            }
        }
        this.#trend = now;
    }

    /**
     * 构建表格骨架
     * @param {HTMLElement} node
     */
    #buildView(node) {
        const table = document.createElement('table');
        table.className = 'data-table data-table--ae';

        // 表头
        const thead = document.createElement('thead');
        const headRow = document.createElement('tr');
        for (const [text, cls] of [[t('modules.AEMonitor.headerResource'), ''], [t('modules.AEMonitor.headerAmount'), 'num']]) {
            const th = document.createElement('th');
            th.textContent = text;
            if (cls) th.className = cls;
            headRow.appendChild(th);
        }
        thead.appendChild(headRow);

        // 数据区
        const tbody = document.createElement('tbody');
        table.append(thead, tbody);
        node.appendChild(table);

        const rows = new Map();
        for (const type of ['items', 'fluids']) {
            for (const id of this.#config[type]) {
                const tr = document.createElement('tr');
                tr.dataset.id = id;

                const nameCell = document.createElement('th');
                nameCell.scope = 'row';
                nameCell.className = 'res-name';
                nameCell.title = id;
                nameCell.textContent = id;

                const valueCell = document.createElement('td');
                valueCell.className = 'num';

                tr.append(nameCell, valueCell);
                tbody.appendChild(tr);
                rows.set(`${type}:${id}`, { tr, nameCell, valueCell, lastText: '' });
            }
        }

        if (rows.size === 0) {
            const tr = document.createElement('tr');
            const td = document.createElement('td');
            td.colSpan = 2;
            td.className = 'empty-note';
            td.textContent = t('modules.AEMonitor.emptyConfig');
            tr.appendChild(td);
            tbody.appendChild(tr);
        }

        return { table, tbody, rows };
    }

    /**
     * 渲染单行
     * @param {{tr: HTMLElement, nameCell: HTMLElement, valueCell: HTMLElement, lastText: string}|undefined} row
     * @param {{count:number, known:boolean, displayName?:string}} state
     * @param {number|undefined} previous 上次数值
     * @param {string} id
     */
    #renderRow(row, state, previous, id) {
        if (!row) return;

        // displayName 字段因编码问题中文一定是 ?? 直接使用id来显示
        if (row.nameCell.textContent !== id) row.nameCell.textContent = id;

        // 颜色翻转判断
        const reverse = this.#config.reverses.has(id) ? -1 : 1;
        let trend = 0;
        if (previous !== undefined && state.known) {
            const diff = (state.count - previous) * reverse;
            trend = diff > 0 ? 1 : diff < 0 ? -1 : 0;
        }

        // 状态
        const text = state.known ? formatAmount(state.count) : t('app.na');
        if (row.lastText !== text) {
            row.valueCell.textContent = text;
            row.lastText = text;
        }

        row.valueCell.dataset.trend = String(trend);
        row.valueCell.title = state.known ? formatCount(state.count) : t('modules.AEMonitor.noData');
        row.tr.classList.toggle('unknown', !state.known);
    }
}
