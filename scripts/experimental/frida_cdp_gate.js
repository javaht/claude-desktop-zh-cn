/**
 * Frida agent (Frida 17+): open official Claude with --remote-debugging-port
 * without writing app.asar on disk.
 *
 * Host passes equal-length replacements (gate + asar integrity hex + Info.plist
 * ElectronAsarIntegrity hash). Agent patches them on open/read/mmap of
 * app.asar and Info.plist so Electron's integrity checks stay consistent
 * with the in-memory gate NOP.
 */

'use strict';

const state = {
  mode: 'both',
  startMs: Date.now(),
  allowExit: false,
  trackedFds: {}, // fd -> 'asar' | 'plist'
  ioPatches: 0,
  memPatchHits: 0,
  menuPatches: 0,
  blockedExits: 0,
  replacements: [], // [{oldHex, newBytes, label, len}]
  menuMap: {}, // English label -> Chinese label (native NSMenuItem hook)
  hooks: { io: false, exit: false, menu: false },
  events: [],
  configured: false,
};

function note(msg) {
  const line = '[frida-cdp-gate] ' + msg;
  state.events.push(line);
  if (state.events.length > 140) {
    state.events.shift();
  }
  send({ type: 'log', message: line });
}

function resolveExport(name) {
  try {
    const a = Module.getGlobalExportByName(name);
    if (a) {
      return a;
    }
  } catch (e) {}
  const mods = ['libsystem_kernel.dylib', 'libsystem_c.dylib', 'libsystem_pthread.dylib'];
  for (let i = 0; i < mods.length; i++) {
    try {
      const mod = Process.findModuleByName(mods[i]);
      if (mod) {
        const a = mod.getExportByName(name);
        if (a) {
          return a;
        }
      }
    } catch (e2) {}
  }
  return null;
}

function classifyPath(pathStr) {
  if (!pathStr) {
    return null;
  }
  if (pathStr.indexOf('app.asar.unpacked') !== -1) {
    return null;
  }
  if (pathStr.indexOf('app.asar') !== -1) {
    return 'asar';
  }
  // Only the main app Info.plist carries ElectronAsarIntegrity for Resources/app.asar.
  // Avoid tracking every system/framework Info.plist (noise; hash needles are unique
  // but scanning every plist read is wasteful).
  if (/\/Claude\.app\/Contents\/Info\.plist$/i.test(pathStr)) {
    return 'plist';
  }
  return null;
}

function pathFromPtr(ptr) {
  if (!ptr || ptr.isNull()) {
    return null;
  }
  try {
    return ptr.readUtf8String();
  } catch (e) {
    try {
      return ptr.readCString();
    } catch (e2) {
      return null;
    }
  }
}

function utf8Bytes(str) {
  // Frida agent JS is not a browser; encode UTF-8 manually so Chinese
  // equal-length replacements are byte-correct (charCodeAt alone is UTF-16).
  const bytes = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      const c2 = str.charCodeAt(i + 1);
      if (c2 >= 0xdc00 && c2 <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        i++;
      }
    }
    if (c <= 0x7f) {
      bytes.push(c);
    } else if (c <= 0x7ff) {
      bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c <= 0xffff) {
      bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else {
      bytes.push(
        0xf0 | (c >> 18),
        0x80 | ((c >> 12) & 0x3f),
        0x80 | ((c >> 6) & 0x3f),
        0x80 | (c & 0x3f)
      );
    }
  }
  return bytes;
}

function bytesToHexPattern(bytes) {
  const parts = [];
  for (let i = 0; i < bytes.length; i++) {
    parts.push(('0' + bytes[i].toString(16)).slice(-2));
  }
  return parts.join(' ');
}

function setReplacements(list) {
  state.replacements = [];
  if (!list || !list.length) {
    note('no replacements configured');
    return;
  }
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    const oldS = String(item.old || item[0] || '');
    const newS = String(item.new || item[1] || '');
    const label = String(item.label || i);
    if (!oldS) {
      note('skip empty replacement ' + label);
      continue;
    }
    const oldBytes = utf8Bytes(oldS);
    const newBytes = utf8Bytes(newS);
    if (oldBytes.length !== newBytes.length) {
      note(
        'skip bad replacement ' +
          label +
          ' utf8-lens ' +
          oldBytes.length +
          '/' +
          newBytes.length
      );
      continue;
    }
    state.replacements.push({
      label: label,
      oldHex: bytesToHexPattern(oldBytes),
      newBytes: newBytes,
      len: oldBytes.length,
      old: oldS,
      neu: newS,
    });
  }
  note('loaded ' + state.replacements.length + ' replacements');
}

function normalizeMenuKey(s) {
  return String(s || '')
    .replace(/…/g, '...')
    .replace(/\s+/g, ' ')
    .trim();
}

function setMenuMap(map) {
  state.menuMap = {};
  if (!map || typeof map !== 'object') {
    note('no menu map configured');
    return;
  }
  const keys = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const v = map[k];
    if (!k || v == null || v === '') {
      continue;
    }
    state.menuMap[k] = String(v);
    const nk = normalizeMenuKey(k);
    if (nk && !state.menuMap[nk]) {
      state.menuMap[nk] = String(v);
    }
    // Ellipsis variants both ways.
    if (k.indexOf('…') !== -1) {
      const dots = k.replace(/…/g, '...');
      if (!state.menuMap[dots]) {
        state.menuMap[dots] = String(v).replace(/…/g, '...');
      }
    }
    if (k.indexOf('...') !== -1) {
      const ell = k.replace(/\.\.\./g, '…');
      if (!state.menuMap[ell]) {
        state.menuMap[ell] = String(v).replace(/\.\.\./g, '…');
      }
    }
  }
  note('loaded menu map entries=' + Object.keys(state.menuMap).length);
}

function lookupMenuTitle(title) {
  if (!title) {
    return null;
  }
  if (state.menuMap[title]) {
    return state.menuMap[title];
  }
  const n = normalizeMenuKey(title);
  if (state.menuMap[n]) {
    return state.menuMap[n];
  }
  // If already Chinese / already patched, leave alone.
  return null;
}

function installMenuHooks() {
  if (state.hooks.menu) {
    return true;
  }
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    note('ObjC unavailable; native menu hooks deferred');
    return false;
  }
  if (!Object.keys(state.menuMap).length) {
    note('menu map empty; native menu hooks skipped');
    return false;
  }

  let ok = false;
  try {
    const NSMenuItem = ObjC.classes.NSMenuItem;
    const NSString = ObjC.classes.NSString;
    if (!NSMenuItem || !NSString) {
      note('NSMenuItem/NSString missing');
      return false;
    }

    function rewriteTitleArg(args, argIndex, where) {
      try {
        const original = new ObjC.Object(args[argIndex]);
        if (!original || original.isNull()) {
          return;
        }
        let title = null;
        try {
          if (original.respondsToSelector_(ObjC.selector('string'))) {
            title = original.string().toString();
          } else {
            title = original.toString();
          }
        } catch (e) {
          title = original.toString();
        }
        const mapped = lookupMenuTitle(title);
        if (!mapped || mapped === title) {
          return;
        }
        args[argIndex] = NSString.stringWithString_(mapped);
        state.menuPatches += 1;
        if (state.menuPatches <= 40 || state.menuPatches % 25 === 0) {
          note(
            'menu ' +
              where +
              ' "' +
              title +
              '" -> "' +
              mapped +
              '" total=' +
              state.menuPatches
          );
        }
      } catch (e) {
        // ignore individual title failures
      }
    }

    const setTitle = NSMenuItem['- setTitle:'];
    if (setTitle) {
      Interceptor.attach(setTitle.implementation, {
        onEnter(args) {
          rewriteTitleArg(args, 2, 'setTitle');
        },
      });
      note('hooked NSMenuItem setTitle:');
      ok = true;
    }

    const initWithTitle = NSMenuItem['- initWithTitle:action:keyEquivalent:'];
    if (initWithTitle) {
      Interceptor.attach(initWithTitle.implementation, {
        onEnter(args) {
          rewriteTitleArg(args, 2, 'initWithTitle');
        },
      });
      note('hooked NSMenuItem initWithTitle:action:keyEquivalent:');
      ok = true;
    }

    const setAttr = NSMenuItem['- setAttributedTitle:'];
    if (setAttr) {
      Interceptor.attach(setAttr.implementation, {
        onEnter(args) {
          try {
            const attr = new ObjC.Object(args[2]);
            if (!attr || attr.isNull()) {
              this._mapped = null;
              return;
            }
            const title = attr.string().toString();
            const mapped = lookupMenuTitle(title);
            if (!mapped || mapped === title) {
              this._mapped = null;
              return;
            }
            this._self = new ObjC.Object(args[0]);
            this._mapped = mapped;
          } catch (e) {
            this._mapped = null;
          }
        },
        onLeave(retval) {
          if (this._mapped && this._self) {
            try {
              this._self.setTitle_(this._mapped);
              state.menuPatches += 1;
            } catch (e) {}
          }
        },
      });
      note('hooked NSMenuItem setAttributedTitle:');
      ok = true;
    }
  } catch (e) {
    note('menu hook install failed: ' + e);
    return false;
  }

  state.hooks.menu = ok;
  if (ok) {
    // Rewrite titles already present on the main menu bar.
    try {
      rewriteExistingMenus();
    } catch (e) {
      note('rewriteExistingMenus failed: ' + e);
    }
  }
  return ok;
}

function rewriteMenuItem(item) {
  if (!item || item.isNull()) {
    return 0;
  }
  let n = 0;
  try {
    const title = item.title() ? item.title().toString() : '';
    const mapped = lookupMenuTitle(title);
    if (mapped && mapped !== title) {
      item.setTitle_(mapped);
      n += 1;
      state.menuPatches += 1;
    }
  } catch (e) {}
  try {
    const sub = item.submenu();
    if (sub && !sub.isNull()) {
      n += rewriteMenu(sub);
    }
  } catch (e2) {}
  return n;
}

function rewriteMenu(menu) {
  if (!menu || menu.isNull()) {
    return 0;
  }
  let n = 0;
  try {
    const count = menu.numberOfItems();
    for (let i = 0; i < count; i++) {
      try {
        n += rewriteMenuItem(menu.itemAtIndex_(i));
      } catch (e) {}
    }
  } catch (e2) {}
  return n;
}

function rewriteExistingMenus() {
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    return 0;
  }
  let total = 0;
  try {
    const app = ObjC.classes.NSApplication.sharedApplication();
    if (!app) {
      return 0;
    }
    const mainMenu = app.mainMenu();
    if (mainMenu && !mainMenu.isNull()) {
      total += rewriteMenu(mainMenu);
    }
    // Also walk windows' menus if any.
    try {
      const windows = app.windows();
      const wcount = windows ? windows.count() : 0;
      for (let i = 0; i < wcount; i++) {
        try {
          const w = windows.objectAtIndex_(i);
          const wm = w.menu && w.menu();
          if (wm && !wm.isNull()) {
            total += rewriteMenu(wm);
          }
        } catch (e) {}
      }
    } catch (e2) {}
  } catch (e3) {
    note('rewriteExistingMenus error: ' + e3);
  }
  if (total) {
    note('rewrote existing menu titles=' + total + ' totalPatches=' + state.menuPatches);
  } else {
    note('no existing menu titles rewritten yet');
  }
  return total;
}

function tryInstallMenuHooks(reason) {
  if (state.hooks.menu) {
    // Even if already hooked, rewalk menus (they may be rebuilt).
    try {
      rewriteExistingMenus();
    } catch (e) {}
    return true;
  }
  note('tryInstallMenuHooks (' + reason + ') ObjC=' + (typeof ObjC !== 'undefined' && ObjC.available));
  return installMenuHooks();
}

function patchBuffer(buf, size) {
  if (!buf || buf.isNull() || size <= 0 || !state.replacements.length) {
    return 0;
  }
  let hits = 0;
  for (let r = 0; r < state.replacements.length; r++) {
    const rep = state.replacements[r];
    if (size < rep.len) {
      continue;
    }
    try {
      const results = Memory.scanSync(buf, size, rep.oldHex);
      for (let j = 0; j < results.length; j++) {
        try {
          results[j].address.writeByteArray(rep.newBytes);
          hits += 1;
        } catch (e) {
          note('write fail ' + rep.label + ' @ ' + results[j].address + ': ' + e);
        }
      }
    } catch (e2) {
      // ignore range errors
    }
  }
  return hits;
}

function trackFd(fd, pathStr) {
  if (fd < 0) {
    return;
  }
  const kind = classifyPath(pathStr);
  if (!kind) {
    return;
  }
  state.trackedFds[fd] = kind;
  note('track fd=' + fd + ' kind=' + kind + ' path=' + pathStr);
}

function untrackFd(fd) {
  if (state.trackedFds[fd]) {
    note('untrack fd=' + fd);
    delete state.trackedFds[fd];
  }
}

function installIoHooks() {
  if (state.hooks.io) {
    return true;
  }
  let ok = false;

  function hookOpen(name, pathArgIndex) {
    const addr = resolveExport(name);
    if (!addr) {
      note('no export ' + name);
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          this._path = pathFromPtr(args[pathArgIndex]);
        },
        onLeave(retval) {
          try {
            trackFd(retval.toInt32(), this._path);
          } catch (e) {}
        },
      });
      note('hooked ' + name);
      ok = true;
    } catch (e) {
      note('hook fail ' + name + ': ' + e);
    }
  }

  hookOpen('open', 0);
  hookOpen('openat', 1);

  (function () {
    const addr = resolveExport('close');
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            untrackFd(args[0].toInt32());
          } catch (e) {}
        },
      });
    } catch (e) {}
  })();

  function hookRead(name, fdIndex, bufIndex) {
    const addr = resolveExport(name);
    if (!addr) {
      note('no export ' + name);
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._fd = args[fdIndex].toInt32();
            this._buf = args[bufIndex];
            this._kind = state.trackedFds[this._fd] || null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          if (!this._kind) {
            return;
          }
          let n = 0;
          try {
            n = retval.toInt32();
          } catch (e) {
            return;
          }
          if (n <= 0) {
            return;
          }
          const hits = patchBuffer(this._buf, n);
          if (hits > 0) {
            state.ioPatches += hits;
            note(
              name +
                ' patched hits=' +
                hits +
                ' kind=' +
                this._kind +
                ' totalIo=' +
                state.ioPatches +
                ' n=' +
                n
            );
          }
        },
      });
      note('hooked ' + name);
      ok = true;
    } catch (e) {
      note('hook fail ' + name + ': ' + e);
    }
  }

  hookRead('read', 0, 1);
  hookRead('pread', 0, 1);

  function hookReadv(name) {
    const addr = resolveExport(name);
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._fd = args[0].toInt32();
            this._iov = args[1];
            this._iovcnt = args[2].toInt32();
            this._kind = state.trackedFds[this._fd] || null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          if (!this._kind) {
            return;
          }
          let n = 0;
          try {
            n = retval.toInt32();
          } catch (e) {
            return;
          }
          if (n <= 0 || !this._iov || this._iovcnt <= 0) {
            return;
          }
          let remaining = n;
          let hits = 0;
          const stride = Process.pointerSize * 2;
          for (let i = 0; i < this._iovcnt && remaining > 0; i++) {
            const base = this._iov.add(i * stride).readPointer();
            const len = Number(this._iov.add(i * stride + Process.pointerSize).readULong());
            const chunk = Math.min(remaining, len);
            hits += patchBuffer(base, chunk);
            remaining -= chunk;
          }
          if (hits > 0) {
            state.ioPatches += hits;
            note(name + ' patched hits=' + hits + ' totalIo=' + state.ioPatches);
          }
        },
      });
      note('hooked ' + name);
      ok = true;
    } catch (e) {
      note('hook fail ' + name + ': ' + e);
    }
  }

  hookReadv('readv');
  hookReadv('preadv');

  (function () {
    const addr = resolveExport('mmap');
    if (!addr) {
      note('no export mmap');
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._len = Number(args[1]);
            this._fd = args[4].toInt32();
            this._kind = state.trackedFds[this._fd] || null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          if (!this._kind || retval.isNull()) {
            return;
          }
          const hits = patchBuffer(retval, this._len);
          if (hits > 0) {
            state.ioPatches += hits;
            note('mmap patched hits=' + hits + ' kind=' + this._kind + ' len=' + this._len);
          } else {
            note('mmap ' + this._kind + ' len=' + this._len + ' (no needles)');
          }
        },
      });
      note('hooked mmap');
      ok = true;
    } catch (e) {
      note('hook fail mmap: ' + e);
    }
  })();

  state.hooks.io = ok;
  return ok;
}

function tryMemPatchOnce(label) {
  if (!state.replacements.length) {
    note('mem-patch skip (no replacements)');
    return 0;
  }
  let local = 0;
  try {
    const ranges = Process.enumerateRanges({ protection: 'r--', coalesce: true })
      .concat(Process.enumerateRanges({ protection: 'rw-', coalesce: true }))
      .concat(Process.enumerateRanges({ protection: 'r-x', coalesce: true }));
    const seen = {};
    for (let i = 0; i < ranges.length; i++) {
      const range = ranges[i];
      const key = String(range.base) + ':' + range.size;
      if (seen[key]) {
        continue;
      }
      seen[key] = true;
      if (range.size > 120 * 1024 * 1024) {
        continue;
      }
      local += patchBuffer(range.base, range.size);
    }
  } catch (e) {
    note('mem-patch error: ' + e);
  }
  if (local) {
    state.memPatchHits += local;
  }
  note('mem-patch ' + label + ' local=' + local + ' total=' + state.memPatchHits);
  return local;
}

function installExitHooks() {
  // Telemetry only — do not swallow exit(1): Node often crashes after a
  // blocked process.exit. Integrity/gate patches must make exit unnecessary.
  if (state.hooks.exit) {
    return true;
  }
  ['_exit', 'exit', 'quick_exit', 'abort'].forEach(function (name) {
    const addr = resolveExport(name);
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          let c = '?';
          try {
            c = args[0].toInt32();
          } catch (e) {}
          note('saw ' + name + '(' + c + ') io=' + state.ioPatches + ' mem=' + state.memPatchHits);
        },
      });
      note('watch ' + name);
    } catch (e) {}
  });
  state.hooks.exit = true;
  return true;
}

function applyMode(mode) {
  if (mode) {
    state.mode = mode;
  }
  note('mode=' + state.mode);
  // Always install IO hooks when we have replacements; mem/exit optional.
  if (state.mode !== 'exit-hook') {
    installIoHooks();
  }
  if (state.mode === 'mem-patch' || state.mode === 'both') {
    // mem scan is expensive; only once after resume via rpc.rescan
  }
  if (state.mode === 'exit-hook' || state.mode === 'both') {
    installExitHooks();
  }
  // Do NOT install menu hooks here. Frida spawn starts the process suspended;
  // touching AppKit/NSMenuItem this early can kill startup. Host installs
  // menus after resume (and again after CDP is up).
}

function getStatus() {
  return {
    mode: state.mode,
    ioPatches: state.ioPatches,
    memPatchHits: state.memPatchHits,
    menuPatches: state.menuPatches,
    blockedExits: state.blockedExits,
    allowExit: state.allowExit,
    replacements: state.replacements.map(function (r) {
      return r.label;
    }),
    menuMapSize: Object.keys(state.menuMap).length,
    menuHooked: state.hooks.menu,
    trackedFds: state.trackedFds,
    ageMs: Date.now() - state.startMs,
    events: state.events.slice(-40),
  };
}

rpc.exports = {
  configure(opts) {
    opts = opts || {};
    if (opts.mode) {
      state.mode = String(opts.mode);
    }
    if (opts.replacements) {
      setReplacements(opts.replacements);
    }
    if (opts.menuMap) {
      setMenuMap(opts.menuMap);
    }
    applyMode(state.mode);
    state.configured = true;
    return getStatus();
  },
  allowExit() {
    state.allowExit = true;
    note('allowExit enabled');
    return getStatus();
  },
  rescan() {
    const n = tryMemPatchOnce('rpc-rescan');
    return { mem: n, ioPatches: state.ioPatches, status: getStatus() };
  },
  installMenuHooks() {
    const ok = tryInstallMenuHooks('rpc');
    let rewritten = 0;
    if (ok) {
      try {
        rewritten = rewriteExistingMenus();
      } catch (e) {}
    }
    return {
      ok: ok,
      menuHooked: state.hooks.menu,
      menuPatches: state.menuPatches,
      rewritten: rewritten,
      objc:
        typeof ObjC !== 'undefined' && !!ObjC.available,
      status: getStatus(),
    };
  },
  getStatus() {
    return getStatus();
  },
};

// IO hooks early so configure can add replacements before resume.
installIoHooks();
note('agent loaded (awaiting configure replacements)');
