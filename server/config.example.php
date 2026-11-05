<?php
/**
 * CCT-Factory-Hub 服务端配置模板
 */

// 禁止通过 HTTP 直接访问本文件
if (isset($_SERVER['SCRIPT_FILENAME']) && @realpath($_SERVER['SCRIPT_FILENAME']) === @realpath(__FILE__)) {
    http_response_code(403);
    exit();
}

return [
    /**
     * 运行期数据目录
     * * 该目录必须对 Web 服务进程可读写
     * * 留空则自动选择: /dev/shm 可用时用, 否则退回系统临时目录
     */
    'storage_dir' => '/dev/shm/CCT-Factory-Hub',

    /**
     * CCT 客户端 上报所用的签名密钥, 64 位十六进制字符串
     */
    'cct_key' => '0000000000000000000000000000000000000000000000000000000000000000',

    /**
     * Web 前端下发控制信号所用的签名密钥, 64 位十六进制字符串
     */
    'front_key' => '0000000000000000000000000000000000000000000000000000000000000000',

    /**
     * 允许的请求时间偏差 (毫秒), 用于防重放
     */
    'time_tolerance_ms' => 30000,
];
