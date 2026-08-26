export default class {
    // 数据存放变量
    #data = {
        items: {},
        fluids: {},
    };
    // 已处理的配置
    #config = {
        items: new Set(),
        fluids: new Set(),
        reverse: new Set(),
    };
    // 配置文件路径
    #configURL = new URL("./config.json", import.meta.url);

    /**
     * 初始化函数
     */
    async init() {
        // 获取配置
        const response = await fetch(this.#configURL.href);
        if (!response.ok) throw new Error(`无法获取模块配置文件: HTTP ${response.status} ${response.statusText}`);
        const config = await response.json();

        // 配置处理
        const mcIdRegex = /^[a-z0-9_.-]+:[a-z0-9_.-]+$/;
        ['items', 'fluids', 'reverses'].forEach((key, index) => {
            if (!Array.isArray(config[key])) throw new Error(`配置文件不合规: ${key} 不是数组`);
            // 过滤设置
            const cleanCfg = config[key].filter(item => typeof item === 'string' && mcIdRegex.test(item));
            this.#config[key] = new Set(cleanCfg);

            if (index === 2) return;

            // 初始化数据字段
            cleanCfg.forEach((item) => {
                this.#data[key][item] = {
                    count: 0,
                    trend: 0, // -1: 下降 0: 不变 1: 上升
                }
            })
        })
    }

    /**
     * 数据更新函数
     * @param {object} data 新数据
     */
    dataUpdate(data) {
        if (!data?.ae2_cache_update || typeof data?.ae2_cache_update !== 'object') return;

        // 数据更新
        ['items', 'fluids'].forEach(type => {
            if (this.#config[type].size !== 0 && data.ae2_cache_update[type] !== null && typeof data.ae2_cache_update[type] === 'object') {
                for (const [key, value] of Object.entries(data.ae2_cache_update[type])) {
                    if (!this.#config[type].has(key)) continue;
                    const obj = this.#data[type][key] ??= { count: 0, trend: 0 };
                    if (key == "minecraft:egg") console.log(value?.amount);
                    ;
                    const num = Number(value?.amount);
                    if (isNaN(num)) {
                        obj.trend = 9;
                        obj.count = 0;
                    } else {
                        // 计算差异并更新数值
                        const diff = num - obj.count;
                        obj.count = num;

                        // 映射差异
                        const ext = this.#config.reverse.has(key) ? -1 : 1;
                        let trend;
                        if (diff > 0) {
                            trend = 1
                        } else if (diff < 0) {
                            trend = -1
                        } else {
                            trend = 0
                        }
                        obj.trend = trend * ext;
                    }
                }
            }
        })
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