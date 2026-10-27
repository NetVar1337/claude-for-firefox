/**
 * Firefox API Compatibility Layer for Claude Browser Extension
 * Loaded FIRST in every extension page context.
 * Shims Chrome-only APIs so bundled Chrome JS runs unmodified on Firefox.
 */
(function () {
  'use strict';

  // Guard: skip entirely if running in actual Chrome
  if (typeof browser === 'undefined') return;

  const TAG = '[Claude Firefox]';
  const STORAGE_KEY = '_ffTabGroups';
  const TAB_GROUP_ID_NONE = -1;

  // ─── Utility ──────────────────────────────────────────────────────
  /** Wrap a browser.* promise-based API as a Chrome callback-style API */
  function promiseToCallback(fn) {
    return function (...args) {
      const last = args[args.length - 1];
      const cb = typeof last === 'function' ? args.pop() : null;
      const p = fn.apply(this, args);
      if (cb) {
        p.then(r => cb(r), e => { chrome.runtime.lastError = e; cb(undefined); });
      }
      return p;
    };
  }

  /** Minimal chrome.Event stub */
  function makeEvent() {
    const listeners = new Set();
    return {
      addListener(fn) { listeners.add(fn); },
      removeListener(fn) { listeners.delete(fn); },
      hasListener(fn) { return listeners.has(fn); },
      hasListeners() { return listeners.size > 0; },
      _fire(...args) { for (const fn of listeners) { try { fn(...args); } catch (_) { /* swallow */ } } },
    };
  }

  // ─── 1. chrome.sidePanel → browser.sidebarAction ──────────────────
  if (typeof chrome.sidePanel === 'undefined' && browser.sidebarAction) {
    chrome.sidePanel = {
      setOptions(opts, cb) {
        const work = async () => {
          if (opts && opts.path) {
            await browser.sidebarAction.setPanel({ panel: opts.path, tabId: opts.tabId });
          }
          if (opts && typeof opts.enabled === 'boolean') {
            // Firefox doesn't have per-tab enable, but we can set title to signal
          }
        };
        const p = work();
        if (cb) p.then(() => cb(), e => { chrome.runtime.lastError = e; cb(); });
        return p;
      },
      open(opts, cb) {
        // browser.sidebarAction.open() requires user gesture in Firefox
        const p = browser.sidebarAction.open().catch(() => {
          // toggle is available in older Firefox
          if (browser.sidebarAction.toggle) return browser.sidebarAction.toggle();
        });
        if (cb) p.then(() => cb(), e => { chrome.runtime.lastError = e; cb(); });
        return p;
      },
      close(opts, cb) {
        const p = browser.sidebarAction.close ? browser.sidebarAction.close() : Promise.resolve();
        if (cb) p.then(() => cb(), e => { chrome.runtime.lastError = e; cb(); });
        return p;
      },
      getOptions(opts, cb) {
        const result = { enabled: true };
        if (cb) cb(result);
        return Promise.resolve(result);
      },
      setPanelBehavior(behavior, cb) {
        // Chrome MV3 concept, no Firefox equivalent
        if (cb) cb();
        return Promise.resolve();
      },
    };
  }

  // ─── 2. chrome.tabGroups polyfill ─────────────────────────────────
  const TAB_GROUP_COLORS = Object.freeze([
    'grey', 'blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange',
  ]);

  // In-memory group cache: groupId → { id, title, color, collapsed, windowId }
  let groupCache = new Map();
  // tabId → groupId
  let tabGroupMap = new Map();
  let nextGroupId = 1;
  let cacheLoaded = false;

  async function loadGroupCache() {
    if (cacheLoaded) return;
    try {
      const data = await browser.storage.local.get(STORAGE_KEY);
      const saved = data[STORAGE_KEY];
      if (saved) {
        groupCache = new Map(saved.groups || []);
        tabGroupMap = new Map(saved.tabMap || []);
        nextGroupId = saved.nextId || 1;
      }
    } catch (_) { /* first run, empty cache */ }
    cacheLoaded = true;
  }

  async function persistGroupCache() {
    try {
      await browser.storage.local.set({
        [STORAGE_KEY]: {
          groups: [...groupCache.entries()],
          tabMap: [...tabGroupMap.entries()],
          nextId: nextGroupId,
        },
      });
    } catch (_) { /* best-effort */ }
  }

  function makeGroup(windowId) {
    const id = nextGroupId++;
    const group = { id, title: '', color: 'grey', collapsed: false, windowId: windowId || -1 };
    groupCache.set(id, group);
    return group;
  }

  function matchesQuery(group, query) {
    if (!query) return true;
    if (query.collapsed !== undefined && group.collapsed !== query.collapsed) return false;
    if (query.color !== undefined && group.color !== query.color) return false;
    if (query.title !== undefined && group.title !== query.title) return false;
    if (query.windowId !== undefined && query.windowId !== -2 && group.windowId !== query.windowId) return false;
    return true;
  }

  chrome.tabGroups = {
    TAB_GROUP_ID_NONE,
    Color: TAB_GROUP_COLORS.reduce((o, c) => { o[c.toUpperCase()] = c; return o; }, {}),

    get: promiseToCallback(async function (groupId) {
      await loadGroupCache();
      const g = groupCache.get(groupId);
      if (!g) throw new Error(`No group with id: ${groupId}`);
      return { ...g };
    }),

    query: promiseToCallback(async function (queryInfo) {
      await loadGroupCache();
      const results = [];
      for (const g of groupCache.values()) {
        if (matchesQuery(g, queryInfo)) results.push({ ...g });
      }
      return results;
    }),

    update: promiseToCallback(async function (groupId, updateProperties) {
      await loadGroupCache();
      const g = groupCache.get(groupId);
      if (!g) throw new Error(`No group with id: ${groupId}`);
      if (updateProperties.title !== undefined) g.title = updateProperties.title;
      if (updateProperties.color !== undefined) g.color = updateProperties.color;
      if (updateProperties.collapsed !== undefined) g.collapsed = updateProperties.collapsed;
      groupCache.set(groupId, g);
      await persistGroupCache();
      return { ...g };
    }),

    move: promiseToCallback(async function (groupId, moveProperties) {
      await loadGroupCache();
      const g = groupCache.get(groupId);
      if (!g) throw new Error(`No group with id: ${groupId}`);
      if (moveProperties && moveProperties.windowId !== undefined) g.windowId = moveProperties.windowId;
      groupCache.set(groupId, g);
      await persistGroupCache();
      return { ...g };
    }),

    onCreated: makeEvent(),
    onUpdated: makeEvent(),
    onRemoved: makeEvent(),
    onMoved: makeEvent(),
  };

  // Firefox rejects about:newtab / chrome://newtab as an explicit URL; omitting it opens the default new tab
  const NEWTAB_URL = /^(about:newtab\/?|chrome:\/\/newtab\/?)$/;
  function withoutNewtabUrl(info) {
    if (!info || typeof info.url !== 'string' || !NEWTAB_URL.test(info.url)) return info;
    const { url, ...rest } = info;
    return rest;
  }
  const nativeTabsCreate = browser.tabs.create.bind(browser.tabs);
  // The extension opens an OAuth login tab on every (temporary) install; the installer already bootstraps tokens from Claude Code
  const OAUTH_LOGIN_URL = /^https:\/\/claude\.ai\/(login|oauth\/authorize)/;
  async function hasUsableTokens() {
    const stored = await browser.storage.local.get(['accessToken']);
    if (stored.accessToken) return true;
    try {
      const file = await (await fetch(chrome.runtime.getURL('firefox-injected-tokens.json'))).json();
      return Boolean(file.accessToken);
    } catch (_) {
      return false;
    }
  }
  chrome.tabs.create = promiseToCallback(async function (info) {
    if (info && typeof info.url === 'string' && OAUTH_LOGIN_URL.test(info.url) && await hasUsableTokens()) {
      return { id: browser.tabs.TAB_ID_NONE, windowId: browser.windows.WINDOW_ID_NONE, index: -1, active: false, url: 'about:blank' };
    }
    return nativeTabsCreate(withoutNewtabUrl(info));
  });
  const nativeWindowsCreate = browser.windows.create.bind(browser.windows);
  chrome.windows.create = promiseToCallback(async function (info) {
    return nativeWindowsCreate(withoutNewtabUrl(info));
  });

  // Patch chrome.tabs.group
  const nativeTabsGet = browser.tabs.get.bind(browser.tabs);
  const nativeTabsQuery = browser.tabs.query.bind(browser.tabs);
  const origTabsGroup = chrome.tabs.group;
  chrome.tabs.group = promiseToCallback(async function (options) {
    await loadGroupCache();
    let groupId = options.groupId;
    if (groupId === undefined || groupId === null) {
      const tabIds = Array.isArray(options.tabIds) ? options.tabIds : [options.tabIds];
      let windowId = -1;
      if (tabIds.length > 0) {
        try {
          const t = await nativeTabsGet(tabIds[0]);
          windowId = t.windowId;
        } catch (_) { /* fallback */ }
      }
      const g = makeGroup(windowId);
      groupId = g.id;
      chrome.tabGroups.onCreated._fire({ ...g });
    }
    const tabIds = Array.isArray(options.tabIds) ? options.tabIds : [options.tabIds];
    for (const tid of tabIds) {
      tabGroupMap.set(tid, groupId);
    }
    await persistGroupCache();
    return groupId;
  });

  // Patch chrome.tabs.ungroup
  const origTabsUngroup = chrome.tabs.ungroup;
  chrome.tabs.ungroup = promiseToCallback(async function (tabIds) {
    await loadGroupCache();
    const ids = Array.isArray(tabIds) ? tabIds : [tabIds];
    for (const tid of ids) {
      tabGroupMap.delete(tid);
    }
    // Clean up empty groups
    const usedGroups = new Set(tabGroupMap.values());
    for (const gid of [...groupCache.keys()]) {
      if (!usedGroups.has(gid)) {
        const removed = groupCache.get(gid);
        groupCache.delete(gid);
        if (removed) chrome.tabGroups.onRemoved._fire({ ...removed });
      }
    }
    await persistGroupCache();
  });

  // Patch chrome.tabs.get to include groupId
  chrome.tabs.get = promiseToCallback(async function (tabId) {
    const tab = await nativeTabsGet(tabId);
    await loadGroupCache();
    tab.groupId = tabGroupMap.get(tabId) ?? TAB_GROUP_ID_NONE;
    return tab;
  });

  // Patch chrome.tabs.query to include groupId and support groupId filter
  chrome.tabs.query = promiseToCallback(async function (queryInfo) {
    const filterGroupId = queryInfo ? queryInfo.groupId : undefined;
    const cleanQuery = { ...queryInfo };
    delete cleanQuery.groupId;
    const tabs = await nativeTabsQuery(cleanQuery);
    await loadGroupCache();
    for (const tab of tabs) {
      tab.groupId = tabGroupMap.get(tab.id) ?? TAB_GROUP_ID_NONE;
    }
    if (filterGroupId !== undefined) {
      return tabs.filter(t => t.groupId === filterGroupId);
    }
    return tabs;
  });

  // Auto-cleanup when tabs are removed
  if (browser.tabs && browser.tabs.onRemoved) {
    browser.tabs.onRemoved.addListener(async (tabId) => {
      await loadGroupCache();
      if (tabGroupMap.has(tabId)) {
        const gid = tabGroupMap.get(tabId);
        tabGroupMap.delete(tabId);
        // Remove group if now empty
        const usedGroups = new Set(tabGroupMap.values());
        if (!usedGroups.has(gid)) {
          const removed = groupCache.get(gid);
          groupCache.delete(gid);
          if (removed) chrome.tabGroups.onRemoved._fire({ ...removed });
        }
        await persistGroupCache();
      }
    });
  }

  // ─── 3. chrome.offscreen ──────────────────────────────────────────
  if (typeof chrome.offscreen === 'undefined') {
    chrome.offscreen = {
      Reason: Object.freeze({
        TESTING: 'TESTING',
        AUDIO_PLAYBACK: 'AUDIO_PLAYBACK',
        IFRAME_SCRIPTING: 'IFRAME_SCRIPTING',
        DOM_SCRAPING: 'DOM_SCRAPING',
        BLOBS: 'BLOBS',
        DOM_PARSER: 'DOM_PARSER',
        USER_MEDIA: 'USER_MEDIA',
        DISPLAY_MEDIA: 'DISPLAY_MEDIA',
        WEB_RTC: 'WEB_RTC',
        CLIPBOARD: 'CLIPBOARD',
        LOCAL_STORAGE: 'LOCAL_STORAGE',
        WORKERS: 'WORKERS',
        BATTERY_STATUS: 'BATTERY_STATUS',
        MATCH_MEDIA: 'MATCH_MEDIA',
        GEOLOCATION: 'GEOLOCATION',
      }),
      createDocument(params, cb) {
        // Firefox background pages have full DOM access; no-op
        if (cb) cb();
        return Promise.resolve();
      },
      hasDocument(cb) {
        // Always report true — Firefox background can do what offscreen does
        if (cb) cb(true);
        return Promise.resolve(true);
      },
      closeDocument(cb) {
        if (cb) cb();
        return Promise.resolve();
      },
    };
  }

  // ─── 4. chrome.identity bridge ────────────────────────────────────
  if (typeof chrome.identity === 'undefined' || !chrome.identity.getRedirectURL) {
    const existing = chrome.identity || {};
    chrome.identity = {
      ...existing,
      getRedirectURL(path) {
        if (browser.identity && browser.identity.getRedirectURL) {
          return browser.identity.getRedirectURL(path || '');
        }
        // Fallback: construct a plausible redirect URL
        const extId = browser.runtime.id || 'claude-for-firefox';
        const base = `https://${extId}.extensions.allizom.org/`;
        return path ? base + path : base;
      },
      launchWebAuthFlow: promiseToCallback(async function (details) {
        if (browser.identity && browser.identity.launchWebAuthFlow) {
          return browser.identity.launchWebAuthFlow(details);
        }
        throw new Error('identity.launchWebAuthFlow not available');
      }),
      getAuthToken: promiseToCallback(async function (details) {
        // Chrome-specific; Firefox uses launchWebAuthFlow instead
        throw new Error('getAuthToken is Chrome-only; use launchWebAuthFlow or native messaging');
      }),
      removeCachedAuthToken: promiseToCallback(async function (details) {
        // No-op on Firefox
        return {};
      }),
      getProfileUserInfo: promiseToCallback(async function (details) {
        // Chrome-specific
        return { email: '', id: '' };
      }),
    };
  }

  // Page-side implementations of the CDP Input domain, run through scripting.executeScript
  async function pageInput(tabId, func, params) {
    const [injected] = await browser.scripting.executeScript({ target: { tabId }, func, args: [params || {}] });
    return injected && injected.result;
  }

  function dispatchMouseInPage(p) {
    const el = document.elementFromPoint(p.x, p.y) || document.body;
    const button = p.button === 'right' ? 2 : p.button === 'middle' ? 1 : 0;
    const init = {
      bubbles: true, cancelable: true, composed: true, view: window,
      clientX: p.x, clientY: p.y, button, buttons: p.buttons || 0, detail: p.clickCount || 0,
      ctrlKey: !!(p.modifiers & 2), shiftKey: !!(p.modifiers & 8), altKey: !!(p.modifiers & 1), metaKey: !!(p.modifiers & 4),
    };
    const fire = (type, Ctor = MouseEvent) => el.dispatchEvent(new Ctor(type, init));
    if (p.type === 'mouseMoved') {
      fire('pointermove', PointerEvent); fire('mousemove');
    } else if (p.type === 'mousePressed') {
      fire('pointerdown', PointerEvent); fire('mousedown');
      const focusable = el.closest('a[href],button,input,select,textarea,summary,[tabindex],[contenteditable]');
      if (focusable && focusable.focus) focusable.focus();
    } else if (p.type === 'mouseReleased') {
      fire('pointerup', PointerEvent); fire('mouseup');
      if (button === 2) fire('contextmenu');
      else {
        fire('click');
        if (p.clickCount === 2) fire('dblclick');
      }
    } else if (p.type === 'mouseWheel') {
      el.dispatchEvent(new WheelEvent('wheel', { ...init, deltaX: p.deltaX || 0, deltaY: p.deltaY || 0 }));
      window.scrollBy(p.deltaX || 0, p.deltaY || 0);
    }
  }

  function insertTextInPage(p) {
    const el = document.activeElement;
    if (!el) return;
    if (el.isContentEditable) {
      document.execCommand('insertText', false, p.text);
    } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      const start = el.selectionStart == null ? el.value.length : el.selectionStart;
      const end = el.selectionEnd == null ? el.value.length : el.selectionEnd;
      setter.call(el, el.value.slice(0, start) + p.text + el.value.slice(end));
      el.setSelectionRange && el.setSelectionRange(start + p.text.length, start + p.text.length);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: p.text, inputType: 'insertText' }));
    }
  }

  function dispatchKeyInPage(p) {
    const el = document.activeElement || document.body;
    const init = {
      bubbles: true, cancelable: true, composed: true, key: p.key, code: p.code,
      ctrlKey: !!(p.modifiers & 2), shiftKey: !!(p.modifiers & 8), altKey: !!(p.modifiers & 1), metaKey: !!(p.modifiers & 4),
    };
    const type = p.type === 'keyUp' ? 'keyup' : p.type === 'char' ? 'keypress' : 'keydown';
    const proceed = el.dispatchEvent(new KeyboardEvent(type, init));
    if (!proceed || p.type === 'keyUp') return;
    const editable = el.isContentEditable || el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
    if (p.text && p.type !== 'rawKeyDown' && editable && !(p.modifiers & 6)) {
      insertTextInPage({ text: p.text });
    } else if (p.key === 'Backspace' && editable) {
      if (el.isContentEditable) document.execCommand('delete');
      else {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        const start = el.selectionStart, end = el.selectionEnd;
        const from = start === end ? Math.max(0, start - 1) : start;
        setter.call(el, el.value.slice(0, from) + el.value.slice(end));
        el.setSelectionRange(from, from);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
      }
    } else if (p.key === 'Enter' && p.type !== 'rawKeyDown') {
      if (el instanceof HTMLTextAreaElement || el.isContentEditable) insertTextInPage({ text: '\n' });
      else if (el instanceof HTMLInputElement && el.form) el.form.requestSubmit();
      else if (el instanceof HTMLButtonElement || el instanceof HTMLAnchorElement) el.click();
    }
  }

  // ─── 5. chrome.debugger shim ──────────────────────────────────────
  if (typeof chrome.debugger === 'undefined') {
    const debuggerSessions = new Map(); // tabId → true

    chrome.debugger = {
      onEvent: makeEvent(),
      onDetach: makeEvent(),

      attach: promiseToCallback(async function (target, requiredVersion) {
        if (target && target.tabId != null) {
          debuggerSessions.set(target.tabId, true);
        }
        // Firefox doesn't have chrome.debugger; best-effort attach
      }),

      detach: promiseToCallback(async function (target) {
        if (target && target.tabId != null) {
          debuggerSessions.delete(target.tabId);
          chrome.debugger.onDetach._fire(target, 'canceled_by_user');
        }
      }),

      sendCommand: promiseToCallback(async function (target, method, commandParams) {
        const tabId = target && target.tabId;
        if (tabId == null) throw new Error('debugger.sendCommand requires target.tabId');

        // Limited method support via scripting / tabs APIs
        if (method === 'Runtime.evaluate') {
          const expr = commandParams && commandParams.expression;
          if (!expr) return { result: { type: 'undefined' } };
          const evaluate = async (source) => {
            try {
              const value = await (0, eval)(source);
              return { value };
            } catch (e) {
              return { error: String((e && e.stack) || e) };
            }
          };
          let injected;
          for (const world of ['MAIN', 'ISOLATED']) {
            try {
              injected = await browser.scripting.executeScript({ target: { tabId }, func: evaluate, args: [expr], world });
              if (!injected[0].result.error || world === 'ISOLATED') break;
            } catch (e) {
              injected = [{ result: { error: e.message } }];
            }
          }
          const outcome = injected[0].result;
          if (outcome.error) {
            return {
              result: { type: 'object', subtype: 'error', description: outcome.error },
              exceptionDetails: { text: outcome.error, exception: { description: outcome.error } },
            };
          }
          const value = outcome.value;
          return { result: { type: value === null ? 'object' : typeof value, value, description: String(value) } };
        }

        if (method === 'Input.dispatchMouseEvent') {
          await pageInput(tabId, dispatchMouseInPage, commandParams);
          return {};
        }

        if (method === 'Input.dispatchKeyEvent') {
          await pageInput(tabId, dispatchKeyInPage, commandParams);
          return {};
        }

        if (method === 'Input.insertText') {
          await pageInput(tabId, insertTextInPage, commandParams);
          return {};
        }

        if (method === 'Page.captureScreenshot') {
          try {
            const dataUrl = await browser.tabs.captureTab(tabId, {
              format: (commandParams && commandParams.format) || 'png',
            });
            // Strip "data:image/...;base64," prefix
            const base64 = dataUrl.replace(/^data:[^;]+;base64,/, '');
            return { data: base64 };
          } catch (e) {
            throw new Error('Page.captureScreenshot failed: ' + e.message);
          }
        }

        // Unsupported methods return empty result
        console.warn(TAG, `debugger.sendCommand: unsupported method "${method}"`);
        return {};
      }),

      getTargets: promiseToCallback(async function () {
        return [];
      }),
    };
  }

  // ─── 6. declarativeNetRequest constants ───────────────────────────
  if (chrome.declarativeNetRequest) {
    const dnr = chrome.declarativeNetRequest;

    if (!dnr.RuleActionType) {
      dnr.RuleActionType = Object.freeze({
        BLOCK: 'block',
        REDIRECT: 'redirect',
        ALLOW: 'allow',
        UPGRADE_SCHEME: 'upgradeScheme',
        MODIFY_HEADERS: 'modifyHeaders',
        ALLOW_ALL_REQUESTS: 'allowAllRequests',
      });
    }

    if (!dnr.HeaderOperation) {
      dnr.HeaderOperation = Object.freeze({
        APPEND: 'append',
        SET: 'set',
        REMOVE: 'remove',
      });
    }

    if (!dnr.ResourceType) {
      dnr.ResourceType = Object.freeze({
        MAIN_FRAME: 'main_frame',
        SUB_FRAME: 'sub_frame',
        STYLESHEET: 'stylesheet',
        SCRIPT: 'script',
        IMAGE: 'image',
        FONT: 'font',
        OBJECT: 'object',
        XMLHTTPREQUEST: 'xmlhttprequest',
        PING: 'ping',
        CSP_REPORT: 'csp_report',
        MEDIA: 'media',
        WEBSOCKET: 'websocket',
        OTHER: 'other',
      });
    }
  } else {
    // declarativeNetRequest may not exist at all in some Firefox versions
    chrome.declarativeNetRequest = {
      RuleActionType: Object.freeze({
        BLOCK: 'block',
        REDIRECT: 'redirect',
        ALLOW: 'allow',
        UPGRADE_SCHEME: 'upgradeScheme',
        MODIFY_HEADERS: 'modifyHeaders',
        ALLOW_ALL_REQUESTS: 'allowAllRequests',
      }),
      HeaderOperation: Object.freeze({
        APPEND: 'append',
        SET: 'set',
        REMOVE: 'remove',
      }),
      ResourceType: Object.freeze({
        MAIN_FRAME: 'main_frame',
        SUB_FRAME: 'sub_frame',
        STYLESHEET: 'stylesheet',
        SCRIPT: 'script',
        IMAGE: 'image',
        FONT: 'font',
        OBJECT: 'object',
        XMLHTTPREQUEST: 'xmlhttprequest',
        PING: 'ping',
        CSP_REPORT: 'csp_report',
        MEDIA: 'media',
        WEBSOCKET: 'websocket',
        OTHER: 'other',
      }),
      getDynamicRules: promiseToCallback(async () => []),
      getSessionRules: promiseToCallback(async () => []),
      updateDynamicRules: promiseToCallback(async () => {}),
      updateSessionRules: promiseToCallback(async () => {}),
      getEnabledRulesets: promiseToCallback(async () => []),
      updateEnabledRulesets: promiseToCallback(async () => {}),
      isRegexSupported: promiseToCallback(async () => ({ isSupported: true })),
      getMatchedRules: promiseToCallback(async () => ({ rulesMatchedInfo: [] })),
      onRuleMatchedDebug: makeEvent(),
    };
  }

  // ─── 7. Origin header for api.anthropic.com ───────────────────────
  // Anthropic answers 401 "CORS requests are not allowed for this Organization" to a moz-extension:// Origin
  const dnrNative = browser.declarativeNetRequest;
  if (dnrNative && dnrNative.updateSessionRules) {
    dnrNative.updateSessionRules({
      removeRuleIds: [9001],
      addRules: [{
        id: 9001,
        priority: 1,
        action: { type: 'modifyHeaders', requestHeaders: [{ header: 'origin', operation: 'remove' }] },
        condition: { urlFilter: '||api.anthropic.com/', resourceTypes: ['xmlhttprequest'] },
      }],
    }).catch(e => console.warn(TAG, 'origin header rule failed', e));
  }

  // ─── Init log ─────────────────────────────────────────────────────
  console.log(TAG, 'Compatibility layer loaded');
})();
