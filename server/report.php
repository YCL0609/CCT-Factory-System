<?php
// 初始化
define('SECRET_KEY', '@@KEY@@'); // 密钥
require_once __DIR__ . '/bootstrap.php';

// 处理路径是目录的情况
if (is_dir($dataPath) and !rmdir($dataPath)) {
    errExit(500, 'Internal Error: The storage path is a directory and deletion failed');
}

// 数据准备
$payload = json_encode([
    'report_time' => $cTime,
    'data'        => $body
], JSON_UNESCAPED_UNICODE);
$tmpPath = $dataPath . '.tmp.' . uniqid('', true);

// 原子写入
if (file_put_contents($tmpPath, $payload) === false) {
    errExit(500, 'Internal Error: Write failed on /dev/shm');
}
if (rename($tmpPath, $dataPath) === false) {
    if (file_exists($tmpPath)) { // 失败时清理临时文件
        @unlink($tmpPath);
    }
    errExit(500, 'Internal Error: File overwrite error');
}

// 控制信号文件获取
$ctrlJson = [];
if (is_file($ctrlPath)) {
    // 尝试读文件
    $content = @file_get_contents($ctrlPath);
    if ($content !== false) {
        // json解码
        $data = @json_decode($content, true);
        if (is_array($data)) {
            $ctrlJson = $data;
        }
    }
} elseif (file_exists($ctrlPath)) {
    @rmdir($ctrlPath); // 尝试进行清理
}

// 返回数据
http_response_code(200);
echo json_encode($ctrlJson, JSON_UNESCAPED_UNICODE);
exit();
