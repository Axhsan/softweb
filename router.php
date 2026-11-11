<?php
/**
 * router.php - Router for PHP 8.4 Built-in Server on Port 22558
 * Run with: php -S 0.0.0.0:22558 router.php
 */

$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

// If request is for /api/*, route directly to api.php
if (strpos($uri, '/api/') === 0 || $uri === '/api') {
    require __DIR__ . '/api.php';
    exit;
}

// If file exists physically on disk (html, css, js, images, json), let PHP serve it directly
$targetFile = __DIR__ . $uri;
if ($uri !== '/' && file_exists($targetFile) && !is_dir($targetFile)) {
    return false;
}

// Root or fallback -> index.html
require __DIR__ . '/index.html';
