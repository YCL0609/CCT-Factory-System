<?php

/**
 * CCT 端上报接口
 */

require_once __DIR__ . '/bootstrap.php';

[$cTime, $rawBody] = requireSignedPost(CCT_KEY);
$body = parseJsonBody($rawBody);

dirCheck();

// 数据准备
$payload = json_encode([
    'report_time' => $cTime,
    'data'        => $body,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
if ($payload === false) {
    errExit(500, 'Internal Error: JSON encoding failed');
}

// 原子写入
if (!atomicWrite(DATA_PATH, $payload)) {
    errExit(500, 'Internal Error: Write failed on ' . STORAGE_DIR);
}

// 控制信号文件获取
$ctrlJson = withLock(function () {
    $data = readJsonFile(CTRL_PATH);
    if (!atomicWrite(CTRL_PATH, '{}')) {
        return null;
    }
    return $data;
});
if ($ctrlJson === null) {
    errExit(500, 'Internal Error: Write failed on ' . STORAGE_DIR);
}

// 服务器签名
$sbody = $ctrlJson === []
    ? '{}'
    : json_encode($ctrlJson, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?? '{}';
if ($sbody === false) {
    $sbody = '{}';
}
signResponse($sbody);

// 返回数据
http_response_code(200);
header('Content-Type: application/json; charset=utf-8');
echo $sbody;
exit();
