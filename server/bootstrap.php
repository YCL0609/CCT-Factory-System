<?php

declare(strict_types=1);

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

/**
 * 解析默认存储目录
 */
function defaultStorageDir(): string
{
    // Linux 内存盘, 读写最快
    if (is_dir('/dev/shm') && is_writable('/dev/shm')) {
        return '/dev/shm/CCT-Factory-Hub';
    }
    return rtrim(sys_get_temp_dir(), "/\\") . DIRECTORY_SEPARATOR . 'CCT-Factory-Hub';
}

$configFile = __DIR__ . '/config.php';
$config = [];
if (is_file($configFile)) {
    $loaded = require $configFile;
    if (is_array($loaded)) {
        $config = $loaded;
    }
}

$storageDir = isset($config['storage_dir']) && is_string($config['storage_dir']) && $config['storage_dir'] !== ''
    ? $config['storage_dir']
    : defaultStorageDir();

define('STORAGE_DIR', rtrim($storageDir, "/\\"));
define('DATA_PATH', STORAGE_DIR . DIRECTORY_SEPARATOR . 'latest_report.json');
define('CTRL_PATH', STORAGE_DIR . DIRECTORY_SEPARATOR . 'control_list.json');
define('REPLAY_PATH', STORAGE_DIR . DIRECTORY_SEPARATOR . 'replay_guard.json');
define('LOCK_PATH', STORAGE_DIR . DIRECTORY_SEPARATOR . 'storage.lock');
define('REPLAY_MAX_PER_TIME', 16);
define('CCT_KEY', isset($config['cct_key']) && is_string($config['cct_key']) ? $config['cct_key'] : '');
define('FRONT_KEY', isset($config['front_key']) && is_string($config['front_key']) ? $config['front_key'] : '');
define('TIME_TOLERANCE_MS', isset($config['time_tolerance_ms']) ? (int) $config['time_tolerance_ms'] : 30000);

// ---------------------------------------------------------------------------
// 响应头
// ---------------------------------------------------------------------------

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With, ctime, csha512');
header('Access-Control-Expose-Headers: stime, ssha512');
header('Access-Control-Max-Age: 3600');
header('Cache-Control: private, no-store, no-cache, max-age=0');

// 预检请求直接返回
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
    http_response_code(204);
    exit();
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/**
 * 输出 JSON 错误并结束请求
 */
function errExit(int $code, string $message): void
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit();
}

/**
 * 输出 JSON 数据并结束请求
 */
function jsonExit(int $code, array $data): void
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit();
}

/**
 * 确保存储目录存在且可写
 */
function dirCheck(): void
{
    if (is_dir(STORAGE_DIR)) {
        if (!is_writable(STORAGE_DIR)) {
            errExit(500, 'Internal Error: Storage directory is not writable: ' . STORAGE_DIR);
        }
        return;
    }
    if (file_exists(STORAGE_DIR)) {
        errExit(500, 'Internal Error: Storage path exists but is not a directory: ' . STORAGE_DIR);
    }
    if (!@mkdir(STORAGE_DIR, 0777, true) && !is_dir(STORAGE_DIR)) {
        errExit(500, 'Internal Error: Unable to create storage directory: ' . STORAGE_DIR);
    }
}

/**
 * 原子写入文件
 */
function atomicWrite(string $path, string $payload): bool
{
    $tmpPath = $path . '.tmp.' . bin2hex(random_bytes(8));
    if (@file_put_contents($tmpPath, $payload) === false) {
        return false;
    }
    if (!@rename($tmpPath, $path)) {
        @unlink($tmpPath);
        return false;
    }
    return true;
}

/**
 * 在文件锁保护下执行回调
 * * 回调内应避免调用 exit() (虽然系统仍会释放锁, 但 finally 不会执行)
 *
 * @param callable $fn 需要互斥执行的逻辑
 * @return mixed 回调的返回值
 */
function withLock(callable $fn)
{
    dirCheck();

    $handle = @fopen(LOCK_PATH, 'c');
    if ($handle === false) {
        errExit(500, 'Internal Error: Unable to open lock file: ' . LOCK_PATH);
    }
    if (!flock($handle, LOCK_EX)) {
        fclose($handle);
        errExit(500, 'Internal Error: Unable to acquire the storage lock');
    }

    try {
        return $fn();
    } finally {
        flock($handle, LOCK_UN);
        fclose($handle);
    }
}

/**
 * 重放防护: 登记并校验 (请求时间, 签名)
 *
 * @param string $ctime     客户端请求时间
 * @param string $signature 服务端计算出的预期签名
 */
function replayGuard(string $ctime, string $signature): void
{
    $signature = strtolower($signature);

    $result = withLock(function () use ($ctime, $signature) {
        $nowMs = (float) round(microtime(true) * 1000);
        $records = readJsonFile(REPLAY_PATH);

        // 清理旧数据
        $pruned = [];
        foreach ($records as $time => $signatures) {
            if (!is_numeric($time) || !is_array($signatures)) continue;
            if ($nowMs - (float) $time > TIME_TOLERANCE_MS) continue;
            $pruned[(string) $time] = array_values(array_filter($signatures, 'is_string'));
        }

        // 命中即视为重放
        $used = isset($pruned[$ctime]) ? $pruned[$ctime] : [];
        if (in_array($signature, $used, true)) {
            return 'replay';
        }

        // 同一时间戳下做长度上限, 避免被异常刷写撑爆文件
        if (count($used) >= REPLAY_MAX_PER_TIME) {
            array_shift($used);
        }
        $used[] = $signature;
        $pruned[$ctime] = array_values(array_unique($used));

        $payload = json_encode($pruned, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($payload === false || !atomicWrite(REPLAY_PATH, $payload)) {
            return 'storage';
        }
        return 'ok';
    });

    if ($result === 'replay') {
        errExit(409, 'Conflict: This request has already been used (possible replay)');
    }
    if ($result !== 'ok') {
        // 无法持久化时宁可拒绝也不放行可能的重放
        errExit(500, 'Internal Error: Unable to persist the replay guard');
    }
}

/**
 * 读取 JSON 文件, 失败时返回空数组
 */
function readJsonFile(string $path): array
{
    if (!is_file($path)) {
        // 路径存在但不是普通文件尝试清理
        if (file_exists($path) && is_dir($path)) {
            @rmdir($path);
        }
        return [];
    }
    $content = @file_get_contents($path);
    if ($content === false || $content === '') {
        return [];
    }
    $data = json_decode($content, true);
    return is_array($data) ? $data : [];
}

/**
 * 判断是否为 JSON 数组 (list), 兼容 PHP < 8.1
 */
function isListArray(array $value): bool
{
    if (function_exists('array_is_list')) {
        return array_is_list($value);
    }
    $i = 0;
    foreach ($value as $k => $_) {
        if ($k !== $i++) {
            return false;
        }
    }
    return true;
}

/**
 * 获取所有请求头
 */
function requestHeaders(): array
{
    if (function_exists('getallheaders')) {
        $headers = getallheaders();
        if (is_array($headers)) {
            return array_change_key_case($headers, CASE_LOWER);
        }
    }
    $headers = [];
    foreach ($_SERVER as $key => $value) {
        if (strncmp($key, 'HTTP_', 5) === 0) {
            $name = strtolower(str_replace('_', '-', substr($key, 5)));
            $headers[$name] = $value;
        }
    }
    return $headers;
}

// ---------------------------------------------------------------------------
// 请求校验
// ---------------------------------------------------------------------------

/**
 * 校验 POST 请求的时间戳与签名
 *
 * @param string $secretKey 该接口对应的密钥
 * @return array{0:int,1:string} [$clientTime, $rawBody]
 */
function requireSignedPost(string $secretKey): array
{
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        header('Allow: POST');
        errExit(405, 'Method Not Allowed: only POST is supported');
    }

    if ($secretKey === '') {
        errExit(500, 'Internal Error: The secret key is not configured');
    }

    $headers = requestHeaders();
    $cTime   = $headers['ctime'] ?? null;
    $cSha512 = $headers['csha512'] ?? null;
    if (!is_string($cTime) || !is_string($cSha512) || $cTime === '' || $cSha512 === '') {
        errExit(400, 'Bad Request: Missing ctime/csha512 headers');
    }

    $rawBody = file_get_contents('php://input');
    if ($rawBody === false) {
        errExit(400, 'Bad Request: Unable to read request body');
    }

    // 防重放校验 (允许配置的时间偏差)
    $nowMs = (float) round(microtime(true) * 1000);
    if (abs($nowMs - (float) $cTime) > TIME_TOLERANCE_MS) {
        errExit(403, 'Forbidden: Request expired or time drift too large');
    }

    // 签名验证
    $expectedSign = hash_hmac('sha512', $rawBody . $cTime, $secretKey);
    if (!hash_equals($expectedSign, strtolower($cSha512))) {
        errExit(401, 'Unauthorized: Signature mismatch');
    }

    // 重放防护
    replayGuard((string) $cTime, $expectedSign);

    return [(int) $cTime, $rawBody];
}

/**
 * 解析请求体为关联数组
 *
 * @return array<string,mixed>
 */
function parseJsonBody(string $rawBody): array
{
    if (trim($rawBody) === '') {
        return [];
    }
    $body = json_decode($rawBody, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        errExit(400, 'Bad Request: Invalid JSON body');
    }
    if (!is_array($body)) {
        errExit(400, 'Bad Request: Request body must be a JSON object');
    }
    return $body;
}

/**
 * 给响应加上服务端签名头 (ssha512/stime), 供 CCT 端校验
 */
function signResponse(string $body): string
{
    // 使用整数毫秒字符串, 避免 PHP 浮点转字符串带来的精度差异
    $stime = sprintf('%.0f', microtime(true) * 1000);
    $ssha512 = hash_hmac('sha512', $body . $stime, CCT_KEY);
    header('ssha512: ' . $ssha512);
    header('stime: ' . $stime);
    return $stime;
}
