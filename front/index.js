import { getUrlParams, isMobile } from "https://tool.ycl.cool/public-library/function.esm.min.js";
import { serverCtrl } from "./lib/sendControl.js";
import { showNote } from "./lib/showNote.js";

const reportTimeE = document.getElementById("report-time");
const cellLoading = document.querySelector(".loading");
const showBtnE = document.getElementById("show-btn");
const cellInit = document.querySelector(".init");
const cellList = document.querySelector(".list");
const cellShow = document.querySelector(".show");
const showNodes = [
    document.getElementById("showNode1"),
    document.getElementById("showNode2"),
    document.getElementById("showNode3"),
    document.getElementById("showNode4"),
];
let cellSelected = 0;
let moduleList = {};
let activeList = [];
let showType = 1;
let stage = 0;
let ctrlObj;

// 切换卡片函数
function switchCard(cardId) {
    if (cardId < 0 || cardId > 3) return;

    stage = cardId;
    [cellLoading, cellInit, cellList, cellShow].forEach((card, index) => {
        card.classList.toggle("active", index === cardId);
    });
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
        return true;
    } catch (e) {
        showNote('error', e.message);
        return false;
    } finally {
        btnE.disabled = false;
    }
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
        const time = new Date(data.report_time);
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
    activeList.forEach((v, i) => {
        try {
            if (!showNodes[i]) return;
            await moduleList[v]?.divUpdate?.(showNodes[i], false);
        } catch (e) {
            console.error(e);
            showNote('warn', `实例 [${v}] 执行 divUpdate 失败: ${e?.message || e}`);
        }
    });
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
            nameList[time] = name;
        }
    }
    // 自动排序
    activeList = Object.values(Object.keys(nameList));

    // 进行数据更新
    activeList.forEach((v, i) => {
        try {
            if (!showNodes[i]) return;
            await moduleList[v]?.divUpdate?.(showNodes[i], true);
        } catch (e) {
            console.error(e);
            showNote('warn', `实例 [${v}] 执行 divUpdate 失败: ${e?.message || e}`);
        }
    });

    switchCard(3);
}

// 页面初始化函数
async function init() {
    const startTime = performance.now();
    const showListE = document.querySelector(".show-list");

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
        if (moduleList[cellName.toLowerCase()]) {
            showNote('warn', '检测到重复的模块(已跳过)');
            continue;
        }

        try {
            // 加载模块
            const module = await import(`./module/${cell.name}/index.js`);
            const mClass = new module.default();
            if (typeof mClass.init === 'function') mClass.init();
            moduleList[cellName.toLowerCase()] = mClass;

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
            div.dataset.name = cellName.toLowerCase();
            if (perSelect.has(cellName.toLowerCase())) {
                div.dataset.cell_select = "1";
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
            showListE.appendChild(div);

            loadCount++;
        } catch (e) {
            console.error(e);
            showNote('warn', cellName + '模块加载错误(已跳过): ' + e.message);
        }
    }

    if (loadCount > 0) {
        // 隐藏无模块提示
        document.getElementById("showListNote").style.display = "none";

        // 隐藏不需要的模式选择按钮
        const overflow = 4 - loadCount;
        if (overflow > 0) {
            for (let i = loadCount; i < 4; i++) {
                document.getElementById("showTypeBtn" + (i + 1)).style.display = "none";
            }
        }
    }

    // 启动数据获取循环 (每15s获取一次)
    await getData();
    setInterval(getData, 15000);

    // 提示信息处理
    const totalTime = (performance.now() - startTime).toFixed(2);
    showNote('info', `初始化成功: 已加载 ${loadCount} 个模块, 用时 ${totalTime} ms.`);

    // 切换卡片
    switchCard(1);

    // 自动切换逻辑
    if (params.auto) {
        if (!(await getBasicInfo())) return;
        if (perSelect.size > 0) showCards();
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
document.addEventListener('DOMContentLoaded', init);