export const config = {
    /** 主程序配置 */
    main: {
        /** 合规模块名称正则 */
        module_name_regx: /^[A-Za-z0-9_.-]+$/,
        /** 数据刷新间隔 (毫秒) */
        refresh_interval: 15000,
        /** 单次渲染超时 (毫秒) */
        render_timeout: 5000,
        /** 报告时间超过该毫秒数后标记为陈旧 (前端置灰) */
        stale_after: 60000,
    },
    /** 控制信号发送类配置 */
    sendControl: {
        /** 单次请求超时 (毫秒) */
        request_timeout: 10000,
        /** 连续失败多少次后停止自动刷新 */
        error_limit: 5,
        /** 数据读取候选路径 */
        data_paths: ['/data.json', '/data.php']
    },
    /** 信息弹窗工具配置 */
    showNote: {
        /** 页面最大信息弹窗数量 */
        max_notes: 5,
        /** 自动关闭等待时间 (毫秒) */
        auto_close_timeout: 8000,
    },
    /** 多语言配置 */
    lang: {
        /** 支持的“语言短 id”, 对应 lang/<id>.js; 需同步新增语言包 */
        supported: ['zh', 'en'],
        /** 首个加载失败/语言缺失时使用的默认语言 */
        default: 'zh',
        /** localStorage 记住用户选择的键名 */
        storage_key: 'factoryhub.lang',
    },
    modules: {
        UnitStatus: {
            /** 单个指令发送超时时间 (毫秒) [0 表示禁用超时, 默认16s] */
            send_timeout: 16000
        }
    }
}