import { config } from '../config.js';

/** 语言包缓存: 短id -> 语言包对象 */
const dictCache = new Map();

/** 当前语言包 */
let dict = null;
/** 默认(兜底)语言包 */
let fallbackDict = null;
/** 当前语言短id */
let currentId = '';
/** 是否已初始化 */
let initialized = false;

const DEFAULT_ID = () => config.lang?.default ?? 'zh';
const STORAGE_KEY = () => config.lang?.storage_key ?? 'factoryhub.lang';
const SUPPORTED = () => (Array.isArray(config.lang?.supported) && config.lang.supported.length > 0
    ? config.lang.supported
    : [DEFAULT_ID()]);

/**
 * 把语言标识规范化为短 id
 * @param {unknown} id
 * @returns {string}
 */
function shortId(id) {
    return String(id ?? '').trim().toLowerCase().replace(/_/g, '-').split('-')[0];
}

/**
 * 语言短 id 是否受支持
 * @param {string} id
 * @returns {boolean}
 */
function isSupported(id) {
    return SUPPORTED().includes(id);
}

/**
 * 动态导入语言包
 * @param {string} id 语言短 id
 * @returns {Promise<object>} 语言包对象
 */
async function importDict(id) {
    if (dictCache.has(id)) return dictCache.get(id);
    const module = await import(`../lang/${id}.js`);
    const data = module?.default;
    if (!data || typeof data !== 'object' || typeof data.Info?.lang !== 'string') {
        throw new Error(`Invalid language module: lang/${id}.js`);
    }
    dictCache.set(id, data);
    return data;
}

/**
 * 按路径读取翻译文案
 * @param {object} source 语言包
 * @param {string} path 形如 'app.title' 的路径
 * @returns {unknown}
 */
function lookup(source, path) {
    if (!source) return undefined;
    let value = source;
    for (const key of String(path).split('.')) {
        if (value === null || typeof value !== 'object' || !(key in value)) return undefined;
        value = value[key];
    }
    return value;
}

/**
 * 取翻译文案 (当前语言 -> 默认语言 -> fallback)
 * @param {string} path 语言包路径, 如 'note.loaded'
 * @param {Record<string, unknown>|null} [vars] 占位符变量, 文案中用 {name} 引用
 * @param {string|null} [fallback] 全部语言包都缺失时使用的兜底文案
 * @returns {string}
 */
export function t(path, vars = null, fallback = null) {
    let text = lookup(dict, path);
    if (typeof text !== 'string') text = lookup(fallbackDict, path);
    if (typeof text !== 'string') text = typeof fallback === 'string' ? fallback : String(path);
    if (vars && typeof vars === 'object') {
        text = text.replace(/\{(\w+)\}/g, (match, key) => (
            Object.prototype.hasOwnProperty.call(vars, key) && vars[key] !== undefined
                ? String(vars[key])
                : match
        ));
    }
    return text;
}

/** 当前语言短 id */
export function currentLang() {
    return currentId || DEFAULT_ID();
}

/** 受支持的语言短 id 列表 */
export function languages() {
    return SUPPORTED().slice();
}

/**
 * 语言列表 (含各语言的自称, 用于选择器)
 * @returns {Promise<Array<{id:string, name:string, langLong:string}>>}
 */
export async function languageList() {
    const list = [];
    for (const id of SUPPORTED()) {
        try {
            const data = await importDict(id);
            list.push({
                id,
                name: typeof data.Info.name === 'string' && data.Info.name !== '' ? data.Info.name : id,
                langLong: typeof data.Info.langLong === 'string' && data.Info.langLong !== '' ? data.Info.langLong : id,
            });
        } catch (e) {
            console.warn('[i18n] Cannot load language', id, e?.message || e);
        }
    }
    return list;
}

/** 浏览器首选语言 (取第一个受支持的语言) */
function detectFromNavigator() {
    const prefers = Array.isArray(navigator.languages) && navigator.languages.length > 0
        ? navigator.languages
        : [navigator.language];
    for (const raw of prefers) {
        const id = shortId(raw);
        if (isSupported(id)) return id;
    }
    return null;
}

/** URL 参数 ?lang=xx */
function detectFromUrl() {
    try {
        const raw = new URL(location.href).searchParams.get('lang');
        if (!raw) return null;
        const id = shortId(raw);
        return isSupported(id) ? id : null;
    } catch {
        return null;
    }
}

/** localStorage 中记住的语言 */
function detectFromStorage() {
    try {
        const id = shortId(localStorage.getItem(STORAGE_KEY()));
        return isSupported(id) ? id : null;
    } catch {
        return null;
    }
}

/** 按优先级推导首选语言 */
export function preferredLang() {
    return detectFromUrl() ?? detectFromStorage() ?? detectFromNavigator() ?? DEFAULT_ID();
}

/**
 * 激活指定语言的字典 (失败则回退默认语言)
 * @param {string} id
 * @returns {Promise<string>} 实际生效的语言短 id
 */
async function activate(id) {
    if (!fallbackDict) {
        fallbackDict = await importDict(DEFAULT_ID()).catch((e) => {
            console.error('[i18n] Cannot load default language', e?.message || e);
            return null;
        });
    }

    const target = isSupported(id) ? id : DEFAULT_ID();
    let next = null;
    try {
        next = await importDict(target);
    } catch (e) {
        console.warn('[i18n] Cannot load language', target, e?.message || e);
    }
    if (!next) {
        next = fallbackDict;
        currentId = DEFAULT_ID();
    } else {
        currentId = target;
    }
    dict = next;
    return currentId;
}

/**
 * 应用所有静态文案 (data-i18n*)
 * @param {ParentNode} [root=document]
 */
export function applyStatic(root = document) {
    const scope = root ?? document;
    for (const el of scope.querySelectorAll('[data-i18n], [data-i18n-placeholder], [data-i18n-title], [data-i18n-aria-label]')) {
        if (el.dataset.i18n) el.textContent =  * - Placeholders are written as {name} and replaced by t(path, { name: '...' })
t(el.dataset.i18n);
        if (el.dataset.i18nPlaceholder !== undefined) el.setAttribute('placeholder', t(el.dataset.i18nPlaceholder));
        if (el.dataset.i18nTitle !== undefined) el.setAttribute('title', t(el.dataset.i18nTitle));
        if (el.dataset.i18nAriaLabel !== undefined) el.setAttribute('aria-label', t(el.dataset.i18nAriaLabel));
    }
    // 页面标题
    if (typeof document !== 'undefined' && document.documentElement) {
        document.documentElement.lang = dict?.Info?.langLong || dict?.Info?.lang || DEFAULT_ID();
    }
}

/**
 * 初始化语言
 * @returns {Promise<string>} 生效的语言短 id
 */
export async function initLang() {
    if (initialized) {
        applyStatic();
        return currentId;
    }
    await activate(preferredLang());
    initialized = true;
    applyStatic();
    return currentId;
}

/**
 * 切换语言
 * @param {string} id 语言短 id
 * @param {{persist?: boolean}} [options] persist=false 时不写入 localStorage
 * @returns {Promise<string>} 生效的语言短 id
 */
export async function setLang(id, options = {}) {
    const { persist = true } = options;
    const next = await activate(id);
    if (persist) {
        try {
            localStorage.setItem(STORAGE_KEY(), next);
        } catch {
            /* localStorage 不可用时忽略 */
        }
    }
    applyStatic();
    document.dispatchEvent(new CustomEvent('langchange', {
        detail: { lang: next, info: dict?.Info ?? null },
    }));
    return next;
}
