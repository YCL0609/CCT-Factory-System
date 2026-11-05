<?php

/**
 * Web 前端控制接口
 * ---------------------------------------------------------------------------
 * * 请求: POST, 请求头 ctime/csha512, 请求体为 JSON 对象 {"<单元tag>": true}
 * * 语义:
 *     {"tag": true}       -> 请求切换该单元状态
 *     {"tag": false|null} -> 撤销该单元的请求
 *     {"__reset": true}   -> 清空整个控制列表
 *     {"ping": true}      -> 仅探测服务是否可用
 */

require_once __DIR__ . '/bootstrap.php';

[, $rawBody] = requireSignedPost(FRONT_KEY);
$body = parseJsonBody($rawBody);

// Ping 请求响应: 不写任何数据, 仅告知服务可用
if (($body['ping'] ?? false) !== false) {
        http_response_code(204);
        exit();
}

// 拦截数组形json
if (isListArray($body)) {
    errExit(400, 'Bad Request: Request body must be an associative array');
}

// 目录校验
dirCheck();

// 锁内操作
$result = withLock(function () use ($body) {
    // 读取源控制信号文件内容
    $merged = readJsonFile(CTRL_PATH);

    // 合并请求
    foreach ($body as $key => $value) {
        if (!is_string($key)) continue;

        // 清空信号
        if ($key === '__reset') {
            if ($value) $merged = [];
            continue;
        }

        // 保留字段, 忽略
        if (strncmp($key, '__', 2) === 0) continue;

        // 合并
        if ($value === false || $value === null) {
            unset($merged[$key]);
        } else {
            $merged[$key] = $value;
        }
    }

    // 文件内容构造
    $payload = json_encode($merged, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($payload === false) {
        return 'json';
    }

    // 原子写入
    return atomicWrite(CTRL_PATH, $payload) ? 'ok' : 'write';
});

if ($result === 'json') {
    errExit(500, 'Internal Error: JSON encoding failed');
}
if ($result !== 'ok') {
    errExit(500, 'Internal Error: Write failed on ' . STORAGE_DIR);
}

// 返回空数据
jsonExit(201, ['error' => '']);
