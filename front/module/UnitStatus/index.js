import { t } from '../../lib/i18n.js';

export default class UnitStatus {
    /** 最新的单元列表 */
    #units = [];
    /** 已发出但未确认的控制请求: tag -> true */
    #pending = new Set();
    /** 当前渲染视图 (同一模块只会出现一次, 因此可挂在实例上) */
    #view = null;
    /** 单个指令发送超时时间 (0 表示禁用超时) */
    #sendTimeout = -1;
    /** 单节点渲染状态 (以 DOM 节点为键, 节点被替换后自动回收) */
    static #nodeState = new WeakMap();
    /** 可切换运行的单元状态范围 */
    static Switchable = {
        /** 最小值 */
        MIN: 2,
        /** 最大值 */
        MAX: 6,
    };
    /** 单元状态映射 (与主机端 hub/bin/UnitStatus.lua 保持一致; 文案取自语言包) */
    static StatusMap = {
        0: { key: 'unknown', cls: 'unknown' },
        1: { key: 'unknown', cls: 'unknown' },
        2: { key: 'disabled', cls: 'disabled' },
        3: { key: 'stopped', cls: 'stopped' },
        4: { key: 'running', cls: 'running' },
        5: { key: 'standby', cls: 'standby' },
    };

    /**
     * 初始化
     * @param {{config: object}} ctx 
     */
    init(ctx) {
        const num = Number(ctx.config?.UnitStatus?.send_timeout ?? 16000);
        // 0 表示禁用超时; 非法值回退默认 16000ms
        this.#sendTimeout = Number.isFinite(num) ? Math.max(0, Math.floor(num)) : 16000;
    }

    /**
     * 数据更新
     * @param {object} data 主机上报的数据体
     */
    dataUpdate(data) {
        const list = data?.unit_status_change;
        if (!Array.isArray(list)) return;

        const units = [];
        for (const unit of list) {
            if (!unit || typeof unit !== 'object') continue;
            if (typeof unit.tag !== 'string' || unit.tag === '') continue;
            if (typeof unit.status !== 'number') continue;
            units.push({
                tag: unit.tag,
                name: typeof unit.name === 'string' && unit.name !== '' ? unit.name : unit.tag,
                status: unit.status,
                inProcess: unit.inProcess === true,
            });
        }

        this.#units = units;
        // 收到新状态后清除已确认的请求
        for (const unit of units) {
            if (!unit.inProcess) this.#pending.delete(unit.tag);
        }
    }

    /**
     * 渲染到指定节点
     * @param {HTMLElement} node
     * @param {boolean} isFirst
     * @param {{sendData: Function, showNote: Function, readonly: boolean}} ctx
     */
    divUpdate(node, isFirst, ctx) {
        let view = UnitStatus.#nodeState.get(node);
        if (isFirst || !view || !view.tbody.isConnected) {
            node.replaceChildren();
            view = this.#buildView(node);
            UnitStatus.#nodeState.set(node, view);
        }
        this.#view = view;
        this.#renderRows(view, ctx);
    }

    /**
     * 构建表格骨架
     * @param {HTMLElement} node
     */
    #buildView(node) {
        const table = document.createElement('table');
        table.className = 'data-table data-table--units';

        // 表头
        const thead = document.createElement('thead');
        const headRow = document.createElement('tr');
        for (const [text, cls] of [[t('modules.UnitStatus.headerName'), ''], [t('modules.UnitStatus.headerStatus'), 'status'], [t('modules.UnitStatus.headerAction'), 'action']]) {
            const th = document.createElement('th');
            th.textContent = text;
            if (cls) th.className = cls;
            headRow.appendChild(th);
        }
        thead.appendChild(headRow);

        // 数据区骨架
        const tbody = document.createElement('tbody');
        table.append(thead, tbody);
        node.appendChild(table);

        return { table, tbody, rows: new Map() };
    }

    /**
     * 渲染全部行
     * @param {{tbody: HTMLElement, rows: Map<string, object>}} view
     * @param {object} ctx
     */
    #renderRows(view, ctx) {
        const seen = new Set();

        // 遍历处理
        for (const unit of this.#units) {
            seen.add(unit.tag);
            let row = view.rows.get(unit.tag);
            if (!row) {
                row = this.#createRow(unit, ctx);
                view.rows.set(unit.tag, row);
                view.tbody.appendChild(row.tr);
            }
            this.#updateRow(row, unit, ctx);
        }

        // 移除已经不在列表中的单元
        for (const [tag, row] of view.rows) {
            if (!seen.has(tag)) {
                row.tr.remove();
                view.rows.delete(tag);
            }
        }

        if (this.#units.length === 0) {
            if (!view.emptyRow) {
                const tr = document.createElement('tr');
                const td = document.createElement('td');
                td.colSpan = 3;
                td.className = 'empty-note';
                td.textContent = t('modules.UnitStatus.empty');
                tr.appendChild(td);
                view.emptyRow = tr;
                view.tbody.appendChild(tr);
            }
        } else if (view.emptyRow) {
            view.emptyRow.remove();
            view.emptyRow = null;
        }
    }

    /**
     * 创建一行
     * @param {object} unit
     * @param {object} ctx
     */
    #createRow(unit, ctx) {
        // 物品ID
        const tr = document.createElement('tr');
        tr.dataset.tag = unit.tag;

        // 名称
        const nameCell = document.createElement('th');
        nameCell.scope = 'row';
        nameCell.className = 'unit-name';

        // 状态
        const statusCell = document.createElement('td');
        statusCell.className = 'status';

        // 切换按钮
        const actionCell = document.createElement('td');
        const button = document.createElement('button');
        actionCell.className = 'action';
        button.type = 'button';
        button.className = 'btn btn-switch';
        button.addEventListener('click', () => this.#onSwitch(unit.tag, ctx));
        actionCell.appendChild(button);

        tr.append(nameCell, statusCell, actionCell);
        return { tr, nameCell, statusCell, button };
    }

    /**
     * 更新一行
     * @param {object} row
     * @param {object} unit
     * @param {{readonly: boolean}} ctx
     */
    #updateRow(row, unit, ctx) {
        if (row.nameCell.textContent !== unit.name) row.nameCell.textContent = unit.name;
        row.nameCell.title = `${unit.name} (${unit.tag})`;

        // 单元状态
        const status = UnitStatus.StatusMap[unit.status] ?? UnitStatus.StatusMap[1];
        const statusText = t(`modules.UnitStatus.status.${status.key}`);
        if (row.statusCell.textContent !== statusText) row.statusCell.textContent = statusText;
        row.statusCell.dataset.status = status.cls;

        // 切换按钮
        const switchable = unit.status > UnitStatus.Switchable.MIN && unit.status < UnitStatus.Switchable.MAX;
        const pending = this.#pending.has(unit.tag);
        row.button.disabled = !switchable || pending || ctx.readonly || unit.inProcess;
        row.button.textContent = pending ? t('modules.UnitStatus.switching') : t('modules.UnitStatus.switch');
        row.button.title = ctx.readonly
            ? t('modules.UnitStatus.tipReadonly')
            : (switchable ? t('modules.UnitStatus.tipSwitchable') : t('modules.UnitStatus.tipUnswitchable'));
        row.tr.classList.toggle('busy', pending || unit.inProcess);
    }

    /**
     * 点击切换按钮
     * @param {string} tag
     * @param {object} ctx
     */
    async #onSwitch(tag, ctx) {
        if (this.#pending.has(tag)) return;
        this.#pending.add(tag);

        // 立即反馈一次按钮状态
        const row = this.#view?.rows.get(tag);
        if (row) {
            row.button.disabled = true;
            row.button.textContent = t('modules.UnitStatus.switching');
        }

        // 发送控制信号
        const ok = await ctx.sendData({ [tag]: true });
        if (!ok) {
            this.#pending.delete(tag);
            return;
        }

        // 等待主机推送新的状态 (收到后自动清除 pending)
        if (this.#sendTimeout <= 0) return;
        setTimeout(() => {
            if (this.#pending.delete(tag)) {
                ctx.showNote?.('warn', t('modules.UnitStatus.timeout', { tag }));
            }
        }, this.#sendTimeout);
    }
}
