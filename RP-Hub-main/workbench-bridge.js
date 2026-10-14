/*!
 * workbench-bridge.js —— CYF 综合工作台 ⇄ RP-Hub 运行时的桥
 *
 * 工作台把 RP-Hub 放在 iframe 里试玩，两个页面之间用 postMessage 通信。
 * 这个脚本要由 install-runtime.sh 拷进 RP-Hub 根目录，并在 index.html 的
 * </body> 之前以 <script src="workbench-bridge.js"></script> 引入。
 *
 * 协议（工作台 → 桥）
 *   RPWB_CONFIG  {apiUrl, apiKey, model, qualityModel, balancedModel, fastModel, apiProviderId, customApiUrl}
 *   RPWB_IMPORT  {card}            要导入 RP-Hub 的角色卡 JSON
 *   RPWB_PING                      探活
 * 协议（桥 → 工作台）
 *   RPWB_READY       {token, revision}
 *   RPWB_CONFIGURED  {applied, keys}
 *   RPWB_IMPORTED    {name, via}
 *   RPWB_ERROR       {message}
 *
 * 全部消息都发给 parent，且 targetOrigin 用 '*'：工作台是 file:// 打开的，
 * 它的 origin 是字符串 "null"，没法当 targetOrigin 用。
 */
(function () {
  'use strict';

  var params = new URLSearchParams(location.search || '');
  var TOKEN = params.get('workbenchToken') || '';
  var REVISION = params.get('workbenchRevision') || '';
  var CONFIG_KEYS = ['apiUrl', 'apiKey', 'model', 'qualityModel', 'balancedModel', 'fastModel', 'apiProviderId', 'customApiUrl'];
  var READY_TIMEOUT = 15000;

  function framed() {
    try { return window.parent && window.parent !== window; } catch (e) { return false; }
  }

  function post(type, payload) {
    if (!framed()) return;
    var msg = { type: type, token: TOKEN, revision: REVISION };
    if (payload) for (var k in payload) if (Object.prototype.hasOwnProperty.call(payload, k)) msg[k] = payload[k];
    try { window.parent.postMessage(msg, '*'); } catch (e) { /* 父窗口没了就算了 */ }
  }

  function fail(message) {
    post('RPWB_ERROR', { message: String(message || '未知错误') });
  }

  // ---- RP-Hub 内部句柄 ----------------------------------------------------

  function storage() {
    var s = window.RPHubStorage;
    if (!s || typeof s.getStoredValue !== 'function' || typeof s.setStoredValue !== 'function') return null;
    return s;
  }

  // 就绪判据必须只用 prod 构建里靠得住的东西：
  //   app._instance / el.__vueParentComponent 都是 Vue 的 dev-only 字段，
  //   上游用的是 vue.global.prod.js，那些字段根本不存在。
  //   v-cloak 是 Vue 挂载完成后会摘掉的属性，拿它当「界面已经渲染出来」的信号最稳。
  function runtimeReady() {
    var el = document.getElementById('app');
    if (!el || el.hasAttribute('v-cloak')) return null;
    if (!storage()) return null;
    return el;
  }

  function waitFor(get, timeout) {
    return new Promise(function (resolve) {
      var deadline = Date.now() + timeout;
      (function tick() {
        var value = null;
        try { value = get(); } catch (e) { value = null; }
        if (value) return resolve(value);
        if (Date.now() >= deadline) return resolve(null);
        setTimeout(tick, 150);
      })();
    });
  }

  async function waitUntil(get, timeout) {
    var deadline = Date.now() + timeout;
    for (;;) {
      var value = null;
      try { value = await get(); } catch (e) { value = null; }
      if (value) return value;
      if (Date.now() >= deadline) return null;
      await new Promise(function (r) { setTimeout(r, 150); });
    }
  }

  // RP-Hub 把角色列表存在 'characters' 这个键下（app.js 的 saveCharactersNow）。
  // 靠它来确认导入是真的落地了，而不是只把 change 事件丢出去就算数。
  async function characterNames() {
    var S = storage();
    if (!S || typeof S.getStoredValue !== 'function') return [];
    var list = await S.getStoredValue('characters');
    if (!Array.isArray(list)) return [];
    return list.map(function (c) {
      return (c && (c.name || (c.data && c.data.name))) || '';
    });
  }

  // ---- 配置同步 ----------------------------------------------------------

  async function applyConfig(payload) {
    var S = storage();
    if (!S) throw new Error('RP-Hub 的存储模块还没就绪，稍后再试');
    var current = (await S.getStoredValue('settings')) || {};
    if (typeof current !== 'object' || Array.isArray(current)) current = {};

    // 只覆盖工作台明确给了值的字段：RP-Hub 里其它设置（主题、字号、上下文长度…）原样保留
    var next = {};
    for (var k in current) if (Object.prototype.hasOwnProperty.call(current, k)) next[k] = current[k];
    var applied = [];
    CONFIG_KEYS.forEach(function (key) {
      var value = payload ? payload[key] : undefined;
      if (value === undefined || value === null || value === '') return;
      if (next[key] === value) return;
      next[key] = value;
      applied.push(key);
    });

    await S.setStoredValue('settings', next);
    // total 是合并后整个 settings 的字段数：工作台靠它确认写入是合并而不是覆盖
    post('RPWB_CONFIGURED', { applied: applied.length, keys: applied, total: Object.keys(next).length });

    // RP-Hub 的 settings 是启动时读进响应式对象的，写完必须重载才生效。
    // 一个字段都没变就不折腾了——工作台靠 applied 判断要不要等这次重载。
    if (applied.length) setTimeout(function () { location.reload(); }, 80);
  }

  // ---- 角色卡导入 --------------------------------------------------------

  function safeFileName(name) {
    var base = String(name || 'workbench-card').replace(/[\\/:*?"<>|]+/g, '_').trim();
    return (base || 'workbench-card') + '.json';
  }

  function buttonMatching(re) {
    var buttons = Array.prototype.slice.call(document.querySelectorAll('button'));
    return buttons.find(function (b) {
      return re.test(((b.getAttribute('title') || '') + ' ' + (b.textContent || '')).trim());
    }) || null;
  }

  // RP-Hub 打开时停在首页，「添加角色卡」按钮在角色管理页里才存在。
  // 所以这里要按用户的操作顺序来：先进角色卡管理，再开添加弹窗。
  async function openAddCharacterMenu() {
    var add = buttonMatching(/添加角色卡/) || buttonMatching(/^添加$/);
    if (!add) {
      // RP-Hub 1.8.9 聊天页上这个入口的文案是「前往角色管理」（title 为空），
      // 早期版本叫「角色卡管理」。两个都认，别写死一个。
      // 实测：只匹配 /角色卡管理/ 会在这里 return false，导入直接报「找不到入口」。
      var nav = buttonMatching(/前往角色管理/) || buttonMatching(/角色卡管理/);
      if (!nav) return false;
      nav.click();
      add = await waitFor(function () {
        return buttonMatching(/添加角色卡/) || buttonMatching(/^添加$/);
      }, 5000);
      if (!add) return false;
    }
    add.click();
    return true;
  }

  function cardFileInput() {
    var inputs = Array.prototype.slice.call(document.querySelectorAll('input[type=file]'));
    return inputs.find(function (i) {
      var accept = String(i.accept || '');
      return /\.json/.test(accept) && !/jsonl/.test(accept);
    }) || null;
  }

  async function importCard(payload) {
    var card = payload && (payload.card || payload);
    if (!card || typeof card !== 'object') throw new Error('没有收到可导入的角色卡数据');

    // 先在桥里验一遍：坏数据直接给出可读原因，不要丢给 RP-Hub 只留一句 toast
    var parser = window.RPHubCardUtils && window.RPHubCardUtils.parseImportedCharacterCard;
    if (typeof parser === 'function') {
      try {
        parser(card);
      } catch (err) {
        throw new Error('角色卡数据无法解析：' + ((err && err.message) || err));
      }
    }

    var name = (card.data && card.data.name) || card.name || (payload && payload.name) || 'workbench-card';
    var file = new File([JSON.stringify(card)], safeFileName(name), { type: 'application/json' });
    var before = await characterNames();

    // 只能走 DOM：prod 版 Vue 不暴露组件实例，拿不到 setup() 里的 importCharacter。
    // 于是照着用户的操作来——打开「添加角色卡」弹窗，往它的文件输入框里塞文件。
    var input = cardFileInput();
    if (!input) {
      await openAddCharacterMenu();
      input = await waitFor(cardFileInput, 5000);
    }
    if (!input) throw new Error('找不到 RP-Hub 的导入入口，界面可能已经改版');
    var dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));

    // 事件丢出去不等于导入成功：RP-Hub 解析失败时只弹个 toast 就完了。
    // 所以要等角色列表里真的多出这张卡，才敢回 IMPORTED。
    var landed = await waitUntil(async function () {
      var names = await characterNames();
      return names.length > before.length && names.indexOf(name) >= 0 ? names : null;
    }, 10000);
    if (!landed) throw new Error('RP-Hub 没有接受这张角色卡，可能是卡片数据不合它的要求');
    post('RPWB_IMPORTED', { name: name, via: 'dom', count: landed.length });
  }

  // ---- 启动与消息循环 ----------------------------------------------------

  // 一直等到就绪为止，不做一次性放弃：机器慢的时候 RP-Hub 可能半分钟才起来，
  // 那种情况应该照样能试玩。超过 READY_TIMEOUT 先报一次错让工作台有反馈，
  // 但不停止等待——真的起来了就补一条 READY。
  async function boot() {
    var complained = false;
    var started = Date.now();
    for (;;) {
      if (runtimeReady()) { post('RPWB_READY', {}); return; }
      if (!complained && Date.now() - started > READY_TIMEOUT) {
        complained = true;
        fail('RP-Hub 界面启动很慢（已等 ' + Math.round(READY_TIMEOUT / 1000) + ' 秒），仍在等待…');
      }
      await new Promise(function (r) { setTimeout(r, 120); });
    }
  }

  window.addEventListener('message', function (event) {
    var data = event.data;
    if (!data || typeof data !== 'object') return;
    if (TOKEN && data.token && data.token !== TOKEN) return;

    var run = function (fn) {
      Promise.resolve()
        .then(fn)
        .catch(function (err) { fail((err && err.message) || err); });
    };

    if (data.type === 'RPWB_CONFIG') run(function () { return applyConfig(data.payload || data); });
    else if (data.type === 'RPWB_IMPORT') run(function () { return importCard(data.payload || data); });
    else if (data.type === 'RPWB_PING') run(function () { post('RPWB_READY', {}); });
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
