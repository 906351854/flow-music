import Foundation

/// 落雪（LX Music）自定义源脚本的宿主环境。
///
/// 脚本本身是普通 JS（ES6+），只能看到 `globalThis.lx` 这一套约定 API：
/// `request / on / send / utils / env / version / EVENT_NAMES`。
/// 所以这一层的作用就是**把 lx 对象原样搭出来**，让社区音源脚本可以不加改动地跑起来。
///
/// 为什么用 JS 引擎而不是把某个音源接口写死成原生请求：
/// 音源是「猫鼠游戏」，单个接口平均寿命只有几周（实测 lxmusicapi 已停服、
/// 聚合 API 已经返回 source not match）。引擎只负责协议，脚本失效时换一个 .js
/// 就行，不用重新发版。这也符合「配置/素材外部化」的一贯做法。
///
/// 原生只暴露 6 个通道，其余全部在 JS 里实现：
/// - `__lxHTTP(id, url, specJSON)`      发 HTTP
/// - `__lxHTTPDone(id, err, code, headersJSON, body, isBinary)`
/// - `__lxSend(event, dataJSON)`         脚本上报 inited / updateAlert
/// - `__lxMusicUrlDone(id, err, url)`    取流 Promise 的落点
/// - `__lxTimer(id, ms, repeat)` / `__lxTimerFire(id)`
/// - `__lxLog(level, message)` / `__lxMD5(text)` / `__lxRandomHex(bytes)`
enum LuoxueGlue {

    static let source: String = #"""
    (function () {
      'use strict';
      if (globalThis.lx) return;

      /* ------------------------- 编解码（JSC 没有 atob/TextEncoder） ------------------------- */

      var B64CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

      function b64ToBytes(input) {
        var s = String(input == null ? '' : input).replace(/[^A-Za-z0-9+/]/g, '');
        var out = [];
        var buf = 0;
        var bits = 0;
        for (var i = 0; i < s.length; i++) {
          var v = B64CHARS.indexOf(s.charAt(i));
          if (v < 0) continue;
          buf = (buf << 6) | v;
          bits += 6;
          if (bits >= 8) {
            bits -= 8;
            out.push((buf >> bits) & 0xFF);
          }
        }
        return new Uint8Array(out);
      }

      function bytesToB64(bytes) {
        var out = '';
        for (var i = 0; i < bytes.length; i += 3) {
          var b0 = bytes[i];
          var b1 = bytes[i + 1];
          var b2 = bytes[i + 2];
          out += B64CHARS.charAt(b0 >> 2);
          out += B64CHARS.charAt(((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4));
          out += b1 === undefined ? '=' : B64CHARS.charAt(((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6));
          out += b2 === undefined ? '=' : B64CHARS.charAt(b2 & 63);
        }
        return out;
      }

      function hexToBytes(hex) {
        var s = String(hex == null ? '' : hex);
        var out = [];
        for (var i = 0; i + 1 < s.length; i += 2) {
          var v = parseInt(s.substr(i, 2), 16);
          if (!isNaN(v)) out.push(v);
        }
        return new Uint8Array(out);
      }

      function bytesToHex(bytes) {
        var out = '';
        for (var i = 0; i < bytes.length; i++) {
          var h = bytes[i].toString(16);
          out += h.length === 1 ? '0' + h : h;
        }
        return out;
      }

      function stringToBytes(str) {
        var s = String(str);
        var out = [];
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c < 0x80) {
            out.push(c);
          } else if (c < 0x800) {
            out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
          } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
            var c2 = s.charCodeAt(i + 1);
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
              var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
              out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
              i++;
              continue;
            }
            out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
          } else {
            out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
          }
        }
        return new Uint8Array(out);
      }

      function bytesToString(bytes) {
        var out = '';
        var i = 0;
        while (i < bytes.length) {
          var b = bytes[i++];
          if (b < 0x80) {
            out += String.fromCharCode(b);
          } else if (b < 0xE0) {
            out += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i++] & 0x3F));
          } else if (b < 0xF0) {
            out += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F));
          } else {
            var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
            cp -= 0x10000;
            out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
          }
        }
        return out;
      }

      function isBytes(v) {
        return v instanceof Uint8Array || (typeof ArrayBuffer !== 'undefined' && v instanceof ArrayBuffer);
      }

      function asBytes(v) {
        if (v instanceof Uint8Array) return v;
        if (typeof ArrayBuffer !== 'undefined' && v instanceof ArrayBuffer) return new Uint8Array(v);
        if (Array.isArray(v)) return new Uint8Array(v);
        return new Uint8Array(0);
      }

      /* ------------------------- 日志 ------------------------- */

      function fmt(v) {
        if (typeof v === 'string') return v;
        if (v instanceof Error) return v.message || String(v);
        try { return JSON.stringify(v); } catch (e) { return String(v); }
      }

      function logger(level) {
        return function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) parts.push(fmt(arguments[i]));
          try { __lxLog(level, parts.join(' ')); } catch (e) {}
        };
      }

      globalThis.console = {
        log: logger('log'),
        info: logger('info'),
        warn: logger('warn'),
        error: logger('error'),
        debug: logger('debug'),
        trace: logger('trace'),
        group: function () {},
        groupEnd: function () {},
        table: logger('table'),
        time: function () {},
        timeEnd: function () {}
      };

      /* ------------------------- 定时器（JSC 默认没有） ------------------------- */

      var timers = {};
      var timerSeq = 0;
      var timerInterval = {};

      globalThis.setTimeout = function (fn, ms) {
        if (typeof fn !== 'function') return 0;
        var id = ++timerSeq;
        timers[id] = { fn: fn, exec: fn, ms: Math.max(0, Number(ms) || 0) };
        try { __lxTimer(id, timers[id].ms, false); } catch (e) {}
        return id;
      };

      globalThis.setInterval = function (fn, ms) {
        if (typeof fn !== 'function') return 0;
        var id = ++timerSeq;
        timers[id] = { fn: fn, exec: fn, ms: Math.max(1, Number(ms) || 1) };
        timerInterval[id] = true;
        try { __lxTimer(id, timers[id].ms, true); } catch (e) {}
        return id;
      };

      globalThis.setImmediate = function (fn) { return globalThis.setTimeout(fn, 0); };
      globalThis.clearTimeout = function (id) { delete timers[id]; delete timerInterval[id]; };
      globalThis.clearInterval = function (id) { delete timers[id]; delete timerInterval[id]; };

      globalThis.__lxTimerFire = function (id) {
        var t = timers[id];
        if (!t) return;
        var repeat = !!timerInterval[id];
        if (repeat) {
          try { __lxTimer(id, t.ms, true); } catch (e) {}
        } else {
          delete timers[id];
        }
        try { t.exec(); } catch (e) { console.error('timer error', e); }
      };

      /* ------------------------- utils ------------------------- */

      var bufferUtils = {
        from: function (data, format) {
          if (isBytes(data)) return asBytes(data);
          if (typeof data === 'string') {
            var f = String(format || 'utf8').toLowerCase();
            if (f === 'base64') return b64ToBytes(data);
            if (f === 'hex') return hexToBytes(data);
            return stringToBytes(data);
          }
          if (Array.isArray(data)) return new Uint8Array(data);
          return new Uint8Array(0);
        },
        bufToString: function (buf, format) {
          var bytes = asBytes(buf);
          var f = String(format || 'utf8').toLowerCase();
          if (f === 'base64') return bytesToB64(bytes);
          if (f === 'hex') return bytesToHex(bytes);
          return bytesToString(bytes);
        }
      };

      var cryptoUtils = {
        md5: function (text) { return __lxMD5(String(text)); },
        randomBytes: function (size) { return hexToBytes(__lxRandomHex(Number(size) || 16)); },
        aesEncrypt: function () { throw new Error('当前音源宿主暂不支持 aesEncrypt'); },
        aesDecrypt: function () { throw new Error('当前音源宿主暂不支持 aesDecrypt'); },
        rsaEncrypt: function () { throw new Error('当前音源宿主暂不支持 rsaEncrypt'); },
        rsaDecrypt: function () { throw new Error('当前音源宿主暂不支持 rsaDecrypt'); }
      };

      var zlibUtils = {
        inflate: function () { throw new Error('当前音源宿主暂不支持 zlib.inflate'); },
        deflate: function () { throw new Error('当前音源宿主暂不支持 zlib.deflate'); }
      };

      /* ------------------------- HTTP ------------------------- */

      var pending = {};
      var reqSeq = 0;

      globalThis.__lxHTTPDone = function (id, err, statusCode, headersJSON, body, isBinary) {
        var cb = pending[id];
        delete pending[id];
        if (typeof cb !== 'function') return;
        if (err) {
          cb(new Error(String(err)));
          return;
        }
        var parsedBody = body;
        if (isBinary) {
          parsedBody = b64ToBytes(body);
        } else {
          var trimmed = String(body == null ? '' : body).replace(/^\s+/, '');
          if (trimmed.charAt(0) === '{' || trimmed.charAt(0) === '[') {
            try { parsedBody = JSON.parse(trimmed); } catch (e) { parsedBody = body; }
          }
        }
        var headers = {};
        try { headers = JSON.parse(headersJSON || '{}'); } catch (e) {}
        cb(null, { statusCode: Number(statusCode) || 0, headers: headers, body: parsedBody });
      };

      function request(url, options, callback) {
        if (typeof options === 'function') {
          callback = options;
          options = {};
        }
        options = options || {};

        var id = 'q' + (++reqSeq);
        if (typeof callback === 'function') pending[id] = callback;

        var headers = {};
        var rawHeaders = options.headers || {};
        for (var hk in rawHeaders) {
          if (Object.prototype.hasOwnProperty.call(rawHeaders, hk)) headers[hk] = String(rawHeaders[hk]);
        }

        var bodyKind = 'none';
        var bodyValue = '';

        if (options.form) {
          var parts = [];
          for (var fk in options.form) {
            if (!Object.prototype.hasOwnProperty.call(options.form, fk)) continue;
            var fv = options.form[fk];
            parts.push(encodeURIComponent(fk) + '=' + encodeURIComponent(fv == null ? '' : fv));
          }
          bodyKind = 'form';
          bodyValue = parts.join('&');
        } else if (options.formData) {
          var fields = [];
          for (var dk in options.formData) {
            if (!Object.prototype.hasOwnProperty.call(options.formData, dk)) continue;
            var dv = options.formData[dk];
            if (dv && typeof dv === 'object' && dv.value !== undefined) {
              fields.push({
                name: dk,
                kind: isBytes(dv.value) ? 'base64' : 'text',
                value: isBytes(dv.value) ? bytesToB64(asBytes(dv.value)) : String(dv.value),
                filename: dv.filename || dk
              });
            } else if (isBytes(dv)) {
              fields.push({ name: dk, kind: 'base64', value: bytesToB64(asBytes(dv)), filename: dk });
            } else {
              fields.push({ name: dk, kind: 'text', value: String(dv) });
            }
          }
          bodyKind = 'formData';
          bodyValue = JSON.stringify(fields);
        } else if (options.body !== undefined && options.body !== null) {
          var b = options.body;
          if (isBytes(b)) {
            bodyKind = 'base64';
            bodyValue = bytesToB64(asBytes(b));
          } else if (typeof b === 'string') {
            bodyKind = 'text';
            bodyValue = b;
          } else {
            bodyKind = 'json';
            bodyValue = JSON.stringify(b);
          }
        }

        var spec = JSON.stringify({
          method: String(options.method || 'GET').toUpperCase(),
          headers: headers,
          bodyKind: bodyKind,
          bodyValue: bodyValue,
          timeout: Number(options.timeout) || 0,
          binary: !!options.binary
        });

        try {
          __lxHTTP(id, String(url), spec);
        } catch (e) {
          delete pending[id];
          if (typeof callback === 'function') callback(new Error(String(e && e.message || e)));
        }
        return id;
      }

      /* ------------------------- lx 对象 ------------------------- */

      var EVENT_NAMES = {
        request: 'request',
        inited: 'inited',
        updateAlert: 'updateAlert'
      };

      var handlers = {};

      globalThis.lx = {
        EVENT_NAMES: EVENT_NAMES,
        env: 'mobile',
        version: '2.11.0',
        currentScriptInfo: { name: '', description: '', version: '', author: '', homepage: '' },
        request: request,
        on: function (event, handler) {
          if (typeof handler === 'function') handlers[String(event)] = handler;
        },
        send: function (event, data) {
          var json = 'null';
          try { json = JSON.stringify(data === undefined ? null : data); } catch (e) {}
          try { __lxSend(String(event), json); } catch (e) {}
        },
        utils: {
          buffer: bufferUtils,
          crypto: cryptoUtils,
          zlib: zlibUtils
        }
      };

      globalThis.global = globalThis;

      /* ------------------------- 取流入口（Swift 调用） ------------------------- */

      globalThis.__lxGetMusicUrl = function (requestId, source, quality, musicInfoJSON) {
        var settled = false;
        function finish(err, url) {
          if (settled) return;
          settled = true;
          try { __lxMusicUrlDone(String(requestId), err == null ? '' : String(err), url == null ? '' : String(url)); } catch (e) {}
        }

        var handler = handlers[EVENT_NAMES.request];
        if (typeof handler !== 'function') {
          finish('音源脚本没有注册 request 处理器');
          return;
        }

        var info;
        try {
          info = { type: String(quality), musicInfo: JSON.parse(musicInfoJSON) };
        } catch (e) {
          finish('musicInfo 解析失败');
          return;
        }

        var ret;
        try {
          ret = handler({ action: 'musicUrl', source: String(source), info: info });
        } catch (e) {
          finish(String((e && e.message) || e));
          return;
        }

        Promise.resolve(ret).then(function (u) {
          if (typeof u === 'string') {
            finish('', u);
          } else if (u && typeof u === 'object') {
            finish('', u.url || u.data || '');
          } else {
            finish('音源没有返回播放地址');
          }
        }, function (e) {
          finish(String((e && e.message) || e));
        });
      };
    })();
    """#
}
