<?php
/**
 * 备用上报数据读取接口 (解决部分情况下的CORS问题)
 */

require_once __DIR__ . '/bootstrap.php';

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    errExit(405, 'Method Not Allowed: only GET is supported');
}

$raw = '{}';
if (is_file(DATA_PATH)) {
    $content = @file_get_contents(DATA_PATH);
    if ($content === false) {
        errExit(500, 'Internal Error: Cannot read report file');
    }
    // 校验内容确实为 JSON
    if ($content !== '' && json_decode($content, true) === null && json_last_error() !== JSON_ERROR_NONE) {
        errExit(500, 'Internal Error: Report file is corrupted');
    }
    $raw = $content === '' ? '{}' : $content;
} else {
    jsonExit(404, ['error' => 'No report data available yet']);
}

http_response_code(200);
header('Content-Type: application/json; charset=utf-8');
echo $raw;
exit();
