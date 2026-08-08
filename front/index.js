import { getUrlParams } from "https://tool.ycl.cool/public-library/function.esm.min.js";
import { serverCtrl } from "./lib/sendControl.js";
import { showNote } from "./lib/showNote.js";

const reportTimeE = document.getElementById("report-time");
const cellLoading = document.querySelector(".loading");
const cellInit = document.querySelector(".init");
const cellList = document.querySelector(".list");
const cellShow = document.querySelector(".show");
let moduleList = [];
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
    const results = await Promise.all(
        moduleList.map(cl =>
            Promise.resolve()
                .then(() => cl.dataUpdate())
                .then(() => true)
                .catch((e) => { console.error(e); return false; })
        )
    );
    if (results.includes(false)) showNote('warn', '一个或多个数据处理函数报错，查询控制台获取详细信息')
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
        urlE.value = "";
        pwdE.value = "";
        switchCard(2);
    } catch (e) {
        showNote('error', e.message);
    } finally {
        btnE.disabled = false;
    }
}

// 页面初始化函数
async function init() {
    // url参数解析
    const params = getUrlParams();
    if (params.server) {
        document.getElementById("init-url").value = decodeURIComponent(params.server);
    }

    const startTime = performance.now();
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
    for (const name of list) {
        try {
            const module = await import(`./module/${name}.js`);
            const mClass = new module.default();
            if (typeof mClass.init === 'function') mClass.init();
            moduleList.push(mClass);
            loadCount++;
        } catch (e) {
            console.error(e);
            showNote('warn', name + '模块加载错误(已跳过): ' + e.message);
        }
    }

    // 收尾
    const totalTime = (performance.now() - startTime).toFixed(2);
    showNote('info', `初始化成功: 已加载 ${loadCount} 个模块, 用时 ${totalTime} ms.`);
    switchCard(1);
    if (!!params.auto) getBasicInfo(); // 自动切换
}

/**
 * 向服务器发送控制信号
 * @param {data} data 要发送的数据
 */
export function sendData(data) {
    if (!data || !ctrlObj) return;
    data = String(data);
    ctrlObj.sendCtrl(data);
}

//  页面加载事件
document.addEventListener('DOMContentLoaded', init);

// 初始页面确认按钮
document.getElementById("init-btn").addEventListener('click', getBasicInfo);