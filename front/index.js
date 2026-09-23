import { getUrlParams, isMobile } from "https://tool.ycl.cool/public-library/function.esm.min.js";
import { serverCtrl } from "./lib/sendControl.js";
import { showNote } from "./lib/showNote.js";

const reportTimeE = document.getElementById("report-time");
const cellLoading = document.querySelector(".loading");
const showBtnE = document.getElementById("show-btn");
const backBtn = document.getElementById("back-btn");
const cellInit = document.querySelector(".init");
const cellList = document.querySelector(".list");
const cellShow = document.querySelector(".show");
let cellSelected = 0;
let moduleList = {};
let activeList = [];
let showType = 1;
let stage = 0;
let dataLoop;
let ctrlObj;

// 切换卡片函数
function switchCard(cardId) {
    if (cardId < 0 || cardId > 3) return;

    stage = cardId;
    [cellLoading, cellInit, cellList, cellShow].forEach((card, index) => {
        card.classList.toggle("active", index === cardId);
    });

    backBtn.style.display = cardId > 1 ? "block" : "none"
}

// 密钥输入函数
async function getBasicInfo() {
    if (stage !== 1) return;
    const urlE = document.getElementById("init-url");
    const pwdE = document.getElementById("init-pwd");
    const btnE = document.getElementById("init-btn");
    const url = urlE.value.trim();
    const pwd = pwdE.value.trim();
    if (btnE.disabled) return;
    btnE.disabled = true;

    try {
        ctrlObj = new serverCtrl(url, pwd)
        switchCard(2);

        // 启动数据获取循环 (每15s获取一次)
        await getData();
        dataLoop = setInterval(getData, 15000);

        return true;
    } catch (e) {
        showNote('error', e.message);
        return false;
    } finally {
        btnE.disabled = false;
    }
}

// 显示到屏幕函数
async function dataToScreen(isFirst = false) {
    if (stage != 3) return;
    const cardE = document.querySelector('.show');

    // 获取DOM节点副本
    const mainPoint = cardE.cloneNode(true);
    const divList = [
        mainPoint.querySelector('#showNode1'),
        mainPoint.querySelector('#showNode2'),
        mainPoint.querySelector('#showNode3'),
        mainPoint.querySelector('#showNode4'),
    ];

    // 构建任务列表
    const tasks = activeList.map((v, i) => {
        // 预防边界情况
        const target = divList[i];
        if (!target) return Promise.resolve();

        // 确保处理函数存在
        if (typeof moduleList[v]?.divUpdate !== 'function') return Promise.resolve();

        return Promise.race([
            Promise.resolve().then(() => moduleList[v].divUpdate(target, isFirst)),
            new Promise((_, reject) => setTimeout(() => reject(new Error('函数执行超时')), 5000)),
        ]);
    });

    // 运行并处理结果
    const results = await Promise.allSettled(tasks);
    results.forEach((result, i) => {
        if (result.status === 'rejected') {
            const v = activeList[i];
            console.error(result.reason);
            showNote('warn', `实例 [${v}] 执行 divUpdate 失败: ${result.reason?.message || result.reason}`);
        }
    });

    // 一次性插入所有修改
    cardE.replaceChildren(...mainPoint.children);
}

// 获取并处理数据
async function getData() {
    if (!ctrlObj) return;

    // 获取数据
    const data = await ctrlObj.getData();
    if (!data) return;

    // 处理时间字段
    let reportTime = "N/A"
    if (data.report_time) {
        const time = new Date(Number(data.report_time));
        if (!isNaN(time)) {
            const hh = String(time.getHours()).padStart(2, '0');
            const mm = String(time.getMinutes()).padStart(2, '0');
            const ss = String(time.getSeconds()).padStart(2, '0');
            reportTime = `${hh}:${mm}:${ss}`;
        }
    }
    reportTimeE.innerText = reportTime;

    // 调用所有数据更新函数
    const promises = Object.entries(moduleList).map(async ([key, instance]) => {
        try {
            await instance?.dataUpdate?.(data.data);
        } catch (e) {
            console.error(e);
            showNote('warn', `实例 [${key}] 执行 dataUpdate 失败: ${e?.message || e}`);
        }
    });
    await Promise.all(promises);

    // 进行数据更新
    await dataToScreen();
}

// 显示选择的模块
async function showCards() {
    const list = document.querySelectorAll('[data-cell_select="1"]');
    if (list.length !== showType) return showNote('warn', `已选择模块总数不合规 (${list.length} !== ${showType})`);
    document.querySelector(".show").dataset.type = showType;
    // 信息提取
    const nameList = {};
    let fallbackTime = Date.now();
    for (const div of list) {
        const time = Number(div.dataset.select_time ?? "");
        const name = div.dataset.name;
        if (!name || !moduleList[name]) continue;
        if (isNaN(time)) {
            nameList[fallbackTime] = name;
            fallbackTime++;
        } else {
            let t = time;
            while (nameList[t]) t++;
            nameList[time] = name;
        }
    }
    // 自动排序
    activeList = Object.entries(nameList)
        .sort(([keyA], [keyB]) => Number(keyA) - Number(keyB)) // 按数字大小升序排列 Key
        .map(([, value]) => value); // 只保留 Value

    // 进行数据更新
    switchCard(3);
    await dataToScreen(true);
}

// 页面初始化函数
async function init() {
    const startTime = performance.now();

    // url参数解析
    const params = getUrlParams();
    if (params.server) {
        document.getElementById("init-url").value = decodeURIComponent(params.server);
    }
    let cleanArr = [];
    if (params.select) {
        // 拆分并清洗
        for (const item of params.select.split(',')) {
            const cleanTxt = item.replace(/[/\\,]/g, '').toLowerCase();
            if (!cleanTxt) continue;
            cleanArr.push(cleanTxt);
        }
    }
    const perSelect = new Set(cleanArr);

    // 加载模块列表
    let list = [];
    try {
        const response = await fetch('./module/activated.json');
        if (!response.ok) showNote('error', `无法加载模块列表: HTTP ${response.status} ${response.statusText}`, true);
        list = await response.json();
        if (!Array.isArray(list)) {
            showNote('error', '模块列表文件格式错误', true);
            return;
        }
    } catch (e) {
        showNote('error', '无法加载模块列表: ' + e.message, true);
        return;
    }

    // 循环加载所有模块
    let loadCount = 0;
    const fragment = document.createDocumentFragment();
    for (const cell of list) {
        if (typeof cell !== 'object') {
            showNote('warn', '有模块配置不合规(已跳过)');
            continue;
        }

        // 获取模块名称
        const cellName = cell.name?.replace(/[/\\,]/g, '');
        if (!cellName) {
            showNote('warn', '有模块名称为空(已跳过)')
            continue;
        }
        const minCellName = cellName.toLowerCase()
        if (moduleList[minCellName]) {
            showNote('warn', '检测到重复的模块(已跳过)');
            continue;
        }

        try {
            // 加载模块
            const module = await import(`./module/${cell.name}/index.js`);
            const mClass = new module.default();
            if (typeof mClass.init === 'function') await mClass.init();
            moduleList[minCellName] = mClass;

            // 加载额外css
            if (cell.css) {
                const link = document.createElement('link');
                link.rel = 'stylesheet';
                link.href = `./module/${cell.name}/index.css`;
                document.head.appendChild(link);
            }

            // 添加到页面
            const div = document.createElement('div');
            const h4 = document.createElement('h4');
            const a = document.createElement('a');
            a.innerText = cell.desc ?? "";
            h4.innerText = cellName;
            div.dataset.name = minCellName;
            if (perSelect.has(minCellName)) {
                div.dataset.cell_select = "1";
                div.dataset.select_time = Date.now();
                cellSelected++;
            } else {
                div.dataset.cell_select = "0";
            }
            div.onclick = () => {
                if (div.dataset.cell_select === "1") {
                    div.dataset.cell_select = "0";
                    div.dataset.select_time = "";
                    cellSelected--;
                } else {
                    if (cellSelected >= showType) return;
                    div.dataset.cell_select = "1";
                    div.dataset.select_time = Date.now();
                    cellSelected++;
                }
                showBtnE.disabled = cellSelected !== showType;
            }
            div.appendChild(h4);
            div.appendChild(a);
            fragment.appendChild(div);

            loadCount++;
        } catch (e) {
            console.error(e);
            showNote('warn', cellName + '模块加载错误(已跳过): ' + e.message);
        }
    }

    if (loadCount > 0) {
        // 添加到页面
        const showList = document.querySelector('.show-list');
        showList.replaceChildren(fragment);

        // 隐藏不需要的模式选择按钮
        const overflow = 4 - loadCount;
        if (overflow > 0) {
            for (let i = loadCount; i < 4; i++) {
                document.getElementById("showTypeBtn" + (i + 1)).style.display = "none";
            }
        }
    }

    // 提示信息处理
    const totalTime = (performance.now() - startTime).toFixed(2);
    showNote('info', `初始化成功: 已加载 ${loadCount} 个模块, 用时 ${totalTime} ms.`);

    // 切换卡片
    switchCard(1);

    // 自动切换逻辑
    if (params.auto) {
        if (!(await getBasicInfo())) return;
        if (perSelect.size > 0 && perSelect.size < 5) {
            const targetSvg = document.getElementById("showTypeBtn" + perSelect.size);
            if (!targetSvg) return;
            targetSvg.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
            showCards();
        }
    }
}

/**
 * 向服务器发送控制信号
 * @param {data} data 要发送的数据
 */
function sendData(data) {
    if (!data || !ctrlObj) return;
    data = String(data);
    ctrlObj.sendCtrl(data);
}

// 统一导出
export { sendData, showNote }

// 返回按钮
document.getElementById("back-btn").addEventListener('click', () => switchCard(--stage));

// 初始页面确认按钮
document.getElementById("init-btn").addEventListener('click', getBasicInfo);

// 模块选择确认按钮
showBtnE.addEventListener('click', showCards)

// 多模块显示模块切换按钮
if (!isMobile()) {
    for (let i = 1; i <= 4; i++) {
        document.getElementById("showTypeBtn" + i)
            .addEventListener('click', () => {
                showType = i;
                showBtnE.disabled = cellSelected !== showType;
                document.getElementById("showTypeBtn" + i).classList.add('active');
                document.getElementById("showTypeBtn" + showType).classList.remove('active');
            });
    }
}

//  页面加载事件
document.addEventListener('DOMContentLoaded', () => init().catch(e => showNote('error', '初始化失败: ' + e?.message || e, true)));