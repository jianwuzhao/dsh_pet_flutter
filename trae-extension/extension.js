// 桌宠 <-> Trae 桥：轮询桌宠本机服务拿待发消息，直接执行
// workbench.action.chat.open 把它送进 Trae 对话。
//
// 为什么用轮询而不是 WebSocket：VS Code 扩展宿主只有 Node 标准库（http 可用，
// ws 需要打包依赖），而 800ms 的回环轮询对"发一句话"的延迟完全无感。
//
// 日志全部进 "dsh-pet-bridge" 输出通道：在 Trae 的 Output 面板选中它，
// 就能看到扩展是否激活、是否在轮询、每条消息的投递结果。
'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vscode = require('vscode');

const POLL_INTERVAL_MS = 800;
const TOKEN_RETRY_MS = 5000;

function activate(context) {
  const output = vscode.window.createOutputChannel('dsh-pet-bridge');
  context.subscriptions.push(output);
  const log = (line) => output.appendLine(`[dsh-pet-bridge] ${line}`);

  const home = process.env.DSH_PET_HOME || path.join(os.homedir(), '.dsh_pet_flutter');
  const tokenPath = path.join(home, 'token');
  const port = Number(process.env.DSH_PET_PORT || 7341);
  const adapterId = 'trae-cn';

  // token 由桌宠首次启动时生成：Trae 先起来也没关系，这里会等它。
  let token = '';

  const stopped = { value: false };
  context.subscriptions.push({ dispose: () => { stopped.value = true; } });

  const readToken = () => {
    try {
      return fs.readFileSync(tokenPath, 'utf8').trim();
    } catch {
      return '';
    }
  };

  const request = (method, requestPath, body) =>
    new Promise((resolve, reject) => {
      const req = http.request(
        {
          host: '127.0.0.1',
          port,
          method,
          path: requestPath,
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          timeout: 3000,
        },
        (res) => {
          let data = '';
          res.on('data', (chunk) => { data += chunk; });
          res.on('end', () => {
            if (res.statusCode !== 200) {
              reject(new Error(`HTTP ${res.statusCode}: ${data}`));
              return;
            }
            try { resolve(JSON.parse(data)); } catch { resolve(null); }
          });
        },
      );
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
      if (body !== undefined) req.write(JSON.stringify(body));
      req.end();
    });

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // isPartialQuery 不传 = 直接提交这句话，和用户在聊天框里回车等价。
  // executeCommand 在被遮挡/后台窗口可能一直不 resolve，必须设上限，
  // 否则宠物那边永远等不到回执（表现就是投递超时）。
  const DELIVER_TIMEOUT_MS = 6000;

  async function deliver(prompt) {
    let timer;
    try {
      await Promise.race([
        vscode.commands.executeCommand('workbench.action.chat.open', {
          query: prompt.text,
        }),
        new Promise((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`workbench.action.chat.open ${DELIVER_TIMEOUT_MS / 1000} 秒未返回`)),
            DELIVER_TIMEOUT_MS,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async function runPrompt(prompt) {
    let ok = true;
    let message = '';
    try {
      await deliver(prompt);
      log(`已投递 #${prompt.id} 到 Trae 对话（${prompt.text.length} 字）`);
    } catch (error) {
      ok = false;
      message = error && error.message ? error.message : String(error);
      log(`投递 #${prompt.id} 失败：${message}`);
    }
    try {
      await request('POST', '/bridge/ack', { id: prompt.id, ok, message });
    } catch (error) {
      log(`回执失败（桌宠退出了？）：${error.message}`);
    }
  }

  async function pollLoop() {
    log(`已激活，等宠物投喂：${
      token
        ? `开始轮询 127.0.0.1:${port}（每 ${POLL_INTERVAL_MS}ms）`
        : `桌宠还没启动过（缺 ${tokenPath}），每 ${TOKEN_RETRY_MS / 1000} 秒重试`
    }`);
    let lastError = '';
    while (!stopped.value) {
      if (!token) {
        token = readToken();
        if (!token) {
          await sleep(TOKEN_RETRY_MS);
          continue;
        }
        log(`拿到 token，开始轮询 127.0.0.1:${port}（每 ${POLL_INTERVAL_MS}ms）`);
      }
      try {
        const response = await request('GET', `/bridge/pending?adapter=${adapterId}`);
        for (const prompt of (response && response.prompts) || []) {
          await runPrompt(prompt);
        }
        if (lastError) {
          log('轮询已恢复');
          lastError = '';
        }
      } catch (error) {
        const text = String(error.message);
        // 桌宠没开（ECONNREFUSED）是常态：只在状态变化时记一条，避免刷屏。
        if (text !== lastError) {
          log(/ECONNREFUSED/.test(text)
            ? `连不上桌宠（${text}），等它启动后会自动恢复`
            : `轮询异常：${text}`);
          lastError = text;
        }
        if (/HTTP 401/.test(text)) {
          // 宠物可能重装重发了 token，下轮重读。
          token = '';
        }
      }
      await sleep(POLL_INTERVAL_MS);
    }
  }

  pollLoop();
}

function deactivate() {}

module.exports = { activate, deactivate };
