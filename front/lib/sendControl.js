import { showNote } from './showNote.js';
import { config } from '../config.js/index.js';
import { t } from './i18n.js';

/**
 * @class
 * 主机连接控制器
 */
export class serverCtrl {
    /** @type {string} */
    #serverURL;
    /** @type {string} */
    #serverKEY;
    /** @type {number} */
    #errorCount = 0;
    /** @type {string|null} 已验证可用的数据路径 */
    #dataPath = null;

    /**
     * @param {string} url 服务器基础 URL
     * @param {string} [key] 服务器控制密钥
     */
    constructor(url, key) {
        const text = String(url ?? '').trim();

        // URL合规性测试
        try { new URL(text); } catch {
            throw new Error(t('note.ctrl.badUrl'));
        }
        this.#serverURL = text.replace(/\/+$/, '');

        // 密钥合规性校验
        const keyText = String(key ?? '').trim();
        if (keyText !== '' && keyText.length < 16) {
            throw new Error(t('note.ctrl.keyTooShort'));
        }
        this.#serverKEY = keyText;
    }

    /** 是否处于只读演示模式 */
    get readonly() {
        return this.#serverKEY === '';
    }

    /** 当前是否已连续失败过多 */
    get failed() {
        return this.#errorCount > config.sendControl.error_limit;
    }

    /**
     * 计算 HMAC-SHA512 签名
     * @param {string} data 待签名数据
     * @returns {Promise<string>} 十六进制签名 (无密钥时返回空串)
     */
    async #hmacSha512(data) {
        if (!this.#serverKEY) return '';
        const encoder = new TextEncoder();
        const cryptoKey = await crypto.subtle.importKey(
            'raw', encoder.encode(this.#serverKEY),
            { name: 'HMAC', hash: { name: 'SHA-512' } },
            false, ['sign'],
        );
        const signature = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(data));
        return Array.from(new Uint8Array(signature), (b) => b.toString(16).padStart(2, '0')).join('');
    }

    /**
     * 带超时的 fetch
     * @param {string} path
     * @param {RequestInit} [options]
     * @returns {Promise<Response>}
     */
    async #fetchWithTimeout(path, options = {}) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), config.sendControl.request_timeout);
        try {
            return await fetch(this.#serverURL + path, {
                cache: 'no-store',
                ...options,
                signal: controller.signal,
            });
        } finally {
            clearTimeout(timer);
        }
    }

    /**
     * 探测服务是否可用 (需要密钥)
     * @returns {Promise<boolean>}
     */
    async ping() {
        if (!this.#serverURL || this.readonly) return false;
        try {
            const time = Date.now();
            const response = await this.#fetchWithTimeout('/control.php', {
                method: 'POST',
                headers: {
                    ctime: String(time),
                    csha512: await this.#hmacSha512(`{"ping":true}${time}`),
                    'content-type': 'application/json; charset=utf-8',
                },
                body: '{"ping":true}',
            });
            if (response.ok && response.status !== 204) showNote('warn', t('note.ctrl.badStatus', { status: response.status, statusText: response.statusText }));
            return response.ok;
        } catch (e) {
            console.warn('ping failed:', e);
            return false;
        }
    }

    /**
     * 读取主机上报数据
     * @returns {Promise<{ok:boolean, data:object|null, error?:string errorCode:number}>} ok=false 表示与服务器通讯失败; data=null 表示服务器当前还没有数据
     */
    async getData() {
        if (this.failed) {
            return { ok: false, data: null, error: t('note.ctrl.tooMany'), errorCode: -999 };
        }

        // 优先使用上次成功的路径
        const paths = this.#dataPath
            ? [this.#dataPath, ...config.sendControl.data_paths.filter(p => p !== this.#dataPath)]
            : config.sendControl.data_paths;

        // 遍历尝试获取数据
        let lastError = '';
        let lastErrorCode = 0;
        for (const path of paths) {
            try {
                const response = await this.#fetchWithTimeout(path);
                // 服务器无数据
                if (response.status === 404) {
                    lastError = t('note.ctrl.noData');
                    lastErrorCode = 404;
                }
                // 其他Http错误
                if (!response.ok) {
                    lastError = t('note.ctrl.httpError', { status: response.status, statusText: response.statusText });
                    lastErrorCode = response.status;
                    continue;
                }
                // 解析数据
                let data;
                try { data = await response.json(); } catch (_) { }
                if (!data || typeof data !== 'object' || typeof data.data !== 'object' || data.data === null) {
                    lastError = t('note.ctrl.invalidData');
                    lastErrorCode = -1;
                    continue;
                }
                this.#dataPath = path;
                this.#errorCount = 0;
                return { ok: true, data, errorCode: 0 };
            } catch (e) {
                lastError = e?.name === 'AbortError' ? t('note.ctrl.timeout') : (e?.message || String(e));
                lastErrorCode = -2;
            }
        }

        this.#errorCount++;
        if (this.#errorCount > config.sendControl.error_limit) {
            showNote('error', t('note.ctrl.fetchFailedLimit'), true);
        }
        return { ok: false, data: null, error: lastError, errorCode: lastErrorCode };
    }

    /**
     * 下发控制信号 (未设置密钥时静默成功并返回)
     * @param {string|object|Array} payload 要发送的数据 (对象会自动序列化为 JSON)
     * @returns {Promise<boolean>} 是否成功
     */
    async sendCtrl(payload) {
        if (!this.#serverURL) return false;
        if (this.readonly) {
            showNote('warn', t('note.ctrl.noKey'));
            return true;
        }

        try {
            // 发送控制数据
            const time = Date.now();
            const msg = typeof payload === 'string' ? payload : JSON.stringify(payload ?? {});
            const response = await this.#fetchWithTimeout('/control.php', {
                method: 'POST',
                headers: {
                    ctime: String(time),
                    csha512: await this.#hmacSha512(msg + time),
                    'content-type': 'application/json; charset=utf-8',
                },
                body: msg,
            });

            // 错误处理
            if (!response.ok) {
                let detail = t('note.ctrl.httpError', { status: response.status, statusText: response.statusText });
                try {
                    const errJson = await response.json();
                    if (errJson?.error) detail = errJson.error;
                } catch { /* 忽略解析失败 */ }
                showNote('error', t('note.ctrl.errorReported', { detail }));
                return false;
            }

            // 合规性警告
            if (response.status !== 201) {
                showNote('warn', t('note.ctrl.badStatus', { status: response.status, statusText: response.statusText }));
            }
            return true;
        } catch (e) {
            const errText = e?.name === 'AbortError' ? t('note.ctrl.timeout') : (e?.message || String(e));
            showNote('error', t('note.ctrl.sendFailed', { error: errText }));
            return false;
        }
    }
}
