import { showNote } from "./showNote.js";

/**
 * 服务器控制类
 */
export class serverCtrl {
    #serverURL;
    #serverKEY;
    #errorCount = 0;

    /**
     * @param {string} url 服务器基础 URL
     * @param {string} [key] 服务器控制密钥
     */
    constructor(url, key) {
        // url验证
        url = String(url)
        let urlOK = false;
        try {
            const urlTest = new URL(url);
            urlOK = urlTest.protocol === 'http:' || urlTest.protocol === 'https:';
        } catch (_) {
            urlOK = false;
        }
        if (!urlOK) throw new Error("服务器URL格式错误");
        if (url.endsWith('/')) {
            this.#serverURL = url.slice(0, -1);
        } else {
            this.#serverURL = url;
        }

        // 密钥验证
        if (key && String(key).length > 16) if (!pwdOK) throw new Error("密钥长度过小 (<16)");
        this.#serverKEY = String(key);
    };

    /**
     * 内部函数:哈希签名函数
     * @param {string} data 要签名的数据
     * @returns {string} 计算后的哈希值
     */
    async #hmacSha512(data) {
        if (!this.#serverKEY) return "";
        const encoder = new TextEncoder();
        const keyData = encoder.encode(this.#serverKEY);
        const messageData = encoder.encode(data);
        const cryptoKey = await crypto.subtle.importKey(
            "raw", keyData, { name: "HMAC", hash: { name: "SHA-512" } },
            false, ["sign"]
        );
        const sig = await crypto.subtle.sign("HMAC", cryptoKey, messageData);
        return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
    };

    /**
     * 获取数据
     * @returns {object|null} 当成功时返回数据，失败时自动弹出报错并返回空
     */
    async getData() {
        if (this.#errorCount > 5) return;
        try {
            const response = await fetch(this.#serverURL + '/data.json');
            if (response.status === 404) {
                // 无数据状态
                showNote('warn', '服务器报告当前无数据');
                return;
            } else if (!response.ok) {
                // 其他 HTTP 错误
                this.#errorCount++;
                showNote('error', `服务器数据获取错误: HTTP ${response.status} ${response.statusText}`);
                if (this.#errorCount > 5) {
                    showNote('error', '服务器数据多次获取失败, 请在服务器在线后手动刷新页面', true);
                }
                return;
            } else {
                // 请求成功
                this.#errorCount = 0;
            }

            // 解析数据
            const data = await response.json();
            if (typeof data.data !== 'object') {
                this.#errorCount++;
                showNote('error', '服务器数据返回了无效数据');
                return;
            }

            return data;
        } catch (e) {
            this.#errorCount++;
            console.error(e);
            showNote('warn', '网络请求错误: ' + e.message);
            if (this.#errorCount > 5) showNote('error', '服务器数据多次获取失败, 请在服务器在线后手动刷新页面', true);
        }
    };

    /**
     * 发送控制信号
     * @param {string} msg 要发送的数据
     */
    async sendCtrl(msg) {
        if (!this.#serverURL) return;
        if (!this.#serverKEY) {
            showNote('warn', '服务器密钥未输入，忽略发送控制信号请求');
            return
        }
        msg = String(msg);

        try {
            const time = Date.now();
            const response = await fetch(serverURL + '/control.php', {
                method: 'POST',
                headers: {
                    ctime: time,
                    csha512: await this.#hmacSha512(msg + time),
                },
                body: msg,
            });

            if (!response.ok) { // 状态码错误
                try {
                    const errJson = await response.json();
                    if (!errJson || !errJson.error) throw new Error();
                    showNote('error', '控制接口报告错误: ' + errJson.error);
                } catch (_) {
                    showNote('error', `控制接口响应码错误: ${response.status} ${response.statusText}`);
                }
            } else {
                if (response.status !== 201) { // 不合规状态码提示
                    showNote('warn', `控制接口成功码不合规: ${response.status} ${response.statusText}`);
                } else {
                    showNote('info', '控制信号发送成功');
                }
            }
        } catch (e) {
            console.error(e);
            showNote('error', '网络请求错误: ' + e.message);
        }
    }
}