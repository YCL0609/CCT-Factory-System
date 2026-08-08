<?php
// 初始化
define('SECRET_KEY', '@@KEY@@'); // 密钥
require_once __DIR__ . '/bootstrap.php';

// Ping 请求响应
if (($body->ping ?? false) !== false) {
    http_response_code(201);
    echo '{"error":""}';
    exit();
}

// 路径是目录
if (is_dir($ctrlPath)) {
    errExit(500, 'Internal Error: Path is a directory, expected a file');
}

// 读取源控制信号文件内容
$ctrlJson = [];
if (is_file($ctrlPath)) {
    $content = file_get_contents($ctrlPath);
    if ($content === false) {
        errExit(500, 'Internal Error: Cannot read original file');
    }
    $data = json_decode($content, true);
    if (!is_array($data)) {
        errExit(500, 'Internal Error: Invalid JSON in existing file');
    }
    $ctrlJson = $data;
}

// 验证请求体
if (is_array($body) && array_is_list($body)) {
    errExit(400, 'Bad Request: Request body must be an associative array');
}

// 数据准备
$merged = array_replace($ctrlJson, $body);
$payload = json_encode($merged, JSON_UNESCAPED_UNICODE);
if ($payload === false) {
    errExit(500, 'Internal Error: JSON encoding failed');
}

// 原子写入
$tmpPath = $ctrlPath . '.tmp.' . uniqid('', true);
if (file_put_contents($tmpPath, $payload) === false) {
    errExit(500, 'Internal Error: Write failed');
}
if (rename($tmpPath, $ctrlPath) === false) {
    if (file_exists($tmpPath)) {
        @unlink($tmpPath);
    }
    errExit(500, 'Internal Error: Rename failed');
}

// 返回空数据
http_response_code(201);
echo '{"error":""}';
exit();
