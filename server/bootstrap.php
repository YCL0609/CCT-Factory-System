<?php
// CORS 跨域配置
header("Access-Control-Allow-Origin: *");
header("Access-Control-Allow-Methods: POST, OPTIONS");
header("Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With, ctime, csha512");
header("Access-Control-Expose-Headers: stime, ssha512");

// 防CDN缓存标头
header("Cache-Control: private, no-store, no-cache, max-age=0");

// 处理 OPTIONS 预检请求
header("Access-Control-Max-Age: 3600"); // 预检请求允许缓存1h
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit();
}

// 拦截非 POST 请求
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Content-Type: text/html; charset=utf-8');
    echo '<center><h1>Method Not Allowed</h1><hr>';
    exit();
}

// 报错退出函数
function errExit(int $code, string $message)
{
    http_response_code($code);
    echo json_encode(['error' => $message], JSON_UNESCAPED_UNICODE);
    exit();
}

// 正常请求基础配置
header("Content-Type: application/json; charset=utf-8");
define('STORAGE_DIR', '/dev/shm/CCT-Factory-Server');
$dataPath = STORAGE_DIR . '/latest_report.json';
$ctrlPath = STORAGE_DIR . '/control_list.json';

// 获取请求数据
$headers = array_change_key_case(getallheaders() ?: [], CASE_LOWER);
$cTime   = $headers['ctime'] ?? null;
$cSha512 = $headers['csha512'] ?? null;
$rawBody = file_get_contents('php://input');
if (!$cTime || !$cSha512) { // 标头缺失
    errExit(400, 'Bad Request: Missing cTime/cSha512 headers');
}
if ($rawBody === false) { // 请求体缺失
    errExit(400, 'Bad Request: Request body is empty');
}

// 防重放校验 (允许 30 秒偏差)
$nowMs = round(microtime(true) * 1000);
if (abs($nowMs - (float)$cTime) > 30000) {
    errExit(403, 'Forbidden: Request expired or time drift too large');
}

// 签名验证
$expectedSign = hash_hmac('sha512', $rawBody . $cTime, SECRET_KEY);
if (!hash_equals($expectedSign, strtolower($cSha512))) {
    errExit(401, 'Unauthorized: Signature mismatch');
}

// 数据解析
$body = json_decode($rawBody, true);
if (json_last_error() !== JSON_ERROR_NONE) {
    errExit(400, 'Bad Request: Invalid JSON body');
}

// 确保文件夹存在
if (!is_dir(STORAGE_DIR)) {
    @mkdir(STORAGE_DIR, 0777, true);
}