export default class {
    // 数据存放变量
    #data = [];

    /**
     * 数据更新函数
     * @param {object} data 新数据
     */
    dataUpdate(data) {
        if (!data?.unit_status_change || !Array.isArray(data.unit_status_change?.[0])) return;

        // 数据清洗并更新
        const cleanData = data.unit_status_change[0].filter(unit =>
            typeof unit.status === 'number'
            && typeof unit.inProcess === 'boolean'
            && typeof unit.name === 'string'
            && typeof unit.tag === 'string'
        )
    }

    /**
     * 显示更新函数
     * @param {Node} node 当前模块被分配到的节点实例
     * @param {boolean} isFirst 是否为节点初始化调用
     */
    divUpdate(node, isFirst) {
        // 获取或创建表身体
        let tbody;
        if (isFirst) {
            node.innerHTML = "";
            const table = document.createElement('table');
            const thead = document.createElement('thead');
            tbody = document.createElement('tbody');
            thead.innerHTML = "<tr><th>物品ID</th><th>数量</th></tr>";
            table.className = "AEM-item";
            table.appendChild(thead);
            table.appendChild(tbody);
            node.appendChild(table);
        } else {
            tbody = node.querySelector('tbody');
        }

        // 循环处理所有数据键
        for (const [, type] of Object.entries(this.#data)) {
            for (const [key, data] of Object.entries(type)) {
                // 获取对应数据行
                let th;
                if (isFirst) {
                    const tr = document.createElement('tr');
                    const th0 = document.createElement('th');
                    th = document.createElement('th');
                    th0.innerText = key;
                    tr.dataset.id = key;
                    tr.appendChild(th0);
                    tr.appendChild(th);
                    tbody.appendChild(tr);
                } else {
                    const tr = node.querySelector(`[data-id="${key}"]`);
                    th = tr.querySelector('[data-type]')
                    if (!th) continue;
                }

                // 设置内容
                switch (data.trend) {
                    case 1:
                        th.dataset.type = "1"
                        th.innerText = "+ " + String(data.count);
                        break;
                    case 0:
                        th.dataset.type = "0"
                        th.innerText = String(data.count);
                        break;
                    case -1:
                        th.dataset.type = "-1"
                        th.innerText = "- " + String(data.count);
                        break;
                    default:
                        th.dataset.type = "9"
                        th.innerText = "X " + String(data.count);
                        break;
                }
            }
        }
    }
}