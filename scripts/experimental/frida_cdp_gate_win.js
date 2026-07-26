/**
 * Frida agent (Windows): open official Claude with --remote-debugging-port
 * without writing app.asar / Claude.exe on disk.
 *
 * Host passes equal-length replacements (CDP gate + asar integrity hex +
 * Claude.exe embedded asar header hash). Agent:
 *  1) Immediately patches Claude.exe PE image in memory (header hash)
 *  2) Hooks CreateFile/ReadFile/MapViewOfFile for app.asar IO
 *  3) Periodically rescans memory for late-loaded asar gate bytes
 *
 * Disk files stay stock (ASAR/EXE_UNCHANGED).
 */

'use strict';

const state = {
  mode: 'both',
  startMs: Date.now(),
  trackedHandles: {}, // handle.toString() -> 'asar' | 'exe'
  sectionKinds: {}, // mapping object handle -> kind
  ioPatches: 0,
  memPatchHits: 0,
  blockedExits: 0,
  replacements: [], // [{oldHex, newBytes, label, len, hitCount}]
  hooks: { io: false, exit: false },
  events: [],
  configured: false,
  autoRescanTimer: null,
  lastRescanMs: 0,
  redirectAsarPath: '',
  redirectAsarNtPath: '',
  redirectHits: 0,
};

function note(msg) {
  const line = '[frida-cdp-gate-win] ' + msg;
  state.events.push(line);
  if (state.events.length > 160) {
    state.events.shift();
  }
  send({ type: 'log', message: line });
}

function resolveExport(modName, expName) {
  try {
    const mod = Process.findModuleByName(modName);
    if (mod) {
      const a = mod.getExportByName(expName);
      if (a) {
        return a;
      }
    }
  } catch (e) {}
  try {
    return Module.getGlobalExportByName(expName);
  } catch (e2) {
    return null;
  }
}

function pathFromAnsi(ptr) {
  if (!ptr || ptr.isNull()) {
    return null;
  }
  try {
    return ptr.readAnsiString();
  } catch (e) {
    try {
      return ptr.readCString();
    } catch (e2) {
      return null;
    }
  }
}

function pathFromUtf16(ptr) {
  if (!ptr || ptr.isNull()) {
    return null;
  }
  try {
    return ptr.readUtf16String();
  } catch (e) {
    return null;
  }
}

function classifyPath(pathStr) {
  if (!pathStr) {
    return null;
  }
  // Strip Win32 long-path / device prefixes
  let p = String(pathStr);
  if (p.indexOf('\\\\?\\') === 0) {
    p = p.slice(4);
  }
  if (p.indexOf('\\??\\') === 0) {
    p = p.slice(4);
  }
  const norm = p.replace(/\//g, '\\').toLowerCase();
  if (norm.indexOf('app.asar.unpacked') !== -1) {
    return null;
  }
  // Prefer exact-ish app.asar (not .unpacked)
  if (/(^|[\\/])app\.asar$/i.test(p.replace(/\//g, '\\')) || norm.endsWith('\\app.asar')) {
    return 'asar';
  }
  if (norm.indexOf('app.asar') !== -1 && norm.indexOf('app.asar.') === -1) {
    return 'asar';
  }
  // Main Claude.exe only (skip helpers / chrome-native-host / cowork)
  if (/(^|[\\/])claude\.exe$/i.test(p.replace(/\//g, '\\'))) {
    if (norm.indexOf('helper') !== -1) {
      return null;
    }
    if (norm.indexOf('cowork') !== -1) {
      return null;
    }
    if (norm.indexOf('chrome-native-host') !== -1) {
      return null;
    }
    return 'exe';
  }
  return null;
}

function normalizePathForCompare(pathStr) {
  if (!pathStr) {
    return '';
  }
  let p = String(pathStr).replace(/\//g, '\\');
  if (p.indexOf('\\\\?\\') === 0) {
    p = p.slice(4);
  }
  if (p.indexOf('\\??\\') === 0) {
    p = p.slice(4);
  }
  return p.toLowerCase();
}

function shouldRedirectAsar(pathStr) {
  if (!state.redirectAsarPath) {
    return false;
  }
  if (classifyPath(pathStr) !== 'asar') {
    return false;
  }
  return normalizePathForCompare(pathStr) !== normalizePathForCompare(state.redirectAsarPath);
}

function ntPathFromWin32(pathStr) {
  let p = String(pathStr || '').replace(/\//g, '\\');
  if (p.indexOf('\\??\\') === 0) {
    return p;
  }
  if (p.indexOf('\\\\?\\') === 0) {
    p = p.slice(4);
  }
  if (/^[A-Za-z]:\\/.test(p)) {
    return '\\??\\' + p;
  }
  return p;
}

function utf8Bytes(str) {
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
      hitCount: 0,
    });
  }
  note('loaded ' + state.replacements.length + ' replacements');
}

function safeWriteBytes(addr, bytes, label) {
  try {
    addr.writeByteArray(bytes);
    return true;
  } catch (e1) {
    // PE / code pages are often r-x; briefly make writable.
    try {
      Memory.protect(addr, bytes.length, 'rwx');
      addr.writeByteArray(bytes);
      try {
        Memory.protect(addr, bytes.length, 'r-x');
      } catch (e2) {}
      return true;
    } catch (e3) {
      try {
        Memory.protect(addr, bytes.length, 'rw-');
        addr.writeByteArray(bytes);
        try {
          Memory.protect(addr, bytes.length, 'r--');
        } catch (e4) {}
        return true;
      } catch (e5) {
        note('write fail ' + label + ' @ ' + addr + ': ' + e5);
        return false;
      }
    }
  }
}

function patchBuffer(buf, size, source) {
  if (!buf || buf.isNull() || size <= 0 || !state.replacements.length) {
    return 0;
  }
  // Clamp absurd sizes (MapView whole-file with unknown length)
  if (size > 128 * 1024 * 1024) {
    size = 128 * 1024 * 1024;
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
        if (safeWriteBytes(results[j].address, rep.newBytes, rep.label)) {
          hits += 1;
          rep.hitCount += 1;
        }
      }
    } catch (e2) {
      // ignore range errors
    }
  }
  if (hits > 0 && source) {
    note('patched hits=' + hits + ' via ' + source + ' totalIo=' + state.ioPatches + ' totalMem=' + state.memPatchHits);
  }
  return hits;
}

function handleKey(h) {
  try {
    if (h.isNull && h.isNull()) {
      return null;
    }
    return h.toString();
  } catch (e) {
    try {
      return String(h);
    } catch (e2) {
      return null;
    }
  }
}

function trackHandle(h, pathStr) {
  const key = handleKey(h);
  if (!key || key === '0x0' || key === 'NULL') {
    return;
  }
  const kind = classifyPath(pathStr);
  if (!kind) {
    return;
  }
  state.trackedHandles[key] = kind;
  note('track handle=' + key + ' kind=' + kind + ' path=' + pathStr);
}

function untrackHandle(h) {
  const key = handleKey(h);
  if (key && state.trackedHandles[key]) {
    note('untrack handle=' + key);
    delete state.trackedHandles[key];
  }
}

function installIoHooks() {
  if (state.hooks.io) {
    return true;
  }
  let ok = false;

  function hookCreateFile(name, isWide) {
    const addr = resolveExport('kernel32.dll', name) || resolveExport('KERNEL32.DLL', name);
    if (!addr) {
      note('no export ' + name);
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          this._path = isWide ? pathFromUtf16(args[0]) : pathFromAnsi(args[0]);
          if (shouldRedirectAsar(this._path)) {
            const target = state.redirectAsarPath;
            this._redirectPtr = isWide
              ? Memory.allocUtf16String(target)
              : Memory.allocAnsiString(target);
            args[0] = this._redirectPtr;
            this._path = target;
            state.redirectHits += 1;
            if (state.redirectHits <= 6) {
              note('redirect app.asar -> ' + target);
            }
          }
        },
        onLeave(retval) {
          try {
            if (retval.isNull()) {
              return;
            }
            // INVALID_HANDLE_VALUE == -1
            const v = retval.toInt32();
            if (v === -1) {
              return;
            }
            trackHandle(retval, this._path);
          } catch (e) {}
        },
      });
      note('hooked ' + name);
      ok = true;
    } catch (e) {
      note('hook fail ' + name + ': ' + e);
    }
  }

  hookCreateFile('CreateFileW', true);
  hookCreateFile('CreateFileA', false);

  // NtCreateFile covers some AppX / Chromium paths that bypass CreateFile*
  (function () {
    const addr =
      resolveExport('ntdll.dll', 'NtCreateFile') ||
      resolveExport('NTDLL.DLL', 'NtCreateFile');
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          this._outHandle = args[0];
          this._path = null;
          try {
            // ObjectAttributes -> ObjectName (UNICODE_STRING*)
            const oa = args[2];
            if (!oa || oa.isNull()) {
              return;
            }
            const namePtr = oa.add(Process.pointerSize === 8 ? 16 : 8).readPointer();
            if (!namePtr || namePtr.isNull()) {
              return;
            }
            const len = namePtr.readU16(); // Length in bytes
            const buf = namePtr.add(Process.pointerSize === 8 ? 8 : 4).readPointer();
            if (!buf || buf.isNull() || len <= 0) {
              return;
            }
            this._path = buf.readUtf16String(len / 2);
            if (shouldRedirectAsar(this._path)) {
              const target = state.redirectAsarNtPath || ntPathFromWin32(state.redirectAsarPath);
              const targetPtr = Memory.allocUtf16String(target);
              const byteLen = target.length * 2;
              namePtr.writeU16(byteLen);
              namePtr.add(2).writeU16(byteLen + 2);
              namePtr.add(Process.pointerSize === 8 ? 8 : 4).writePointer(targetPtr);
              this._redirectPtr = targetPtr;
              this._path = target;
              state.redirectHits += 1;
              if (state.redirectHits <= 6) {
                note('redirect NtCreateFile app.asar -> ' + target);
              }
            }
          } catch (e) {
            this._path = null;
          }
        },
        onLeave(retval) {
          try {
            // STATUS_SUCCESS == 0
            if (retval.toInt32() !== 0 || !this._path || !this._outHandle) {
              return;
            }
            const h = this._outHandle.readPointer();
            trackHandle(h, this._path);
          } catch (e) {}
        },
      });
      note('hooked NtCreateFile');
      ok = true;
    } catch (e) {
      note('hook fail NtCreateFile: ' + e);
    }
  })();

  (function () {
    const addr = resolveExport('kernel32.dll', 'CloseHandle');
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            untrackHandle(args[0]);
          } catch (e) {}
        },
      });
      note('hooked CloseHandle');
    } catch (e) {}
  })();

  (function () {
    const addr = resolveExport('kernel32.dll', 'ReadFile');
    if (!addr) {
      note('no export ReadFile');
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._key = handleKey(args[0]);
            this._buf = args[1];
            this._nPtr = args[3];
            this._kind = this._key ? state.trackedHandles[this._key] || null : null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          if (!this._kind) {
            return;
          }
          let success = 0;
          try {
            success = retval.toInt32();
          } catch (e) {
            return;
          }
          if (!success) {
            return;
          }
          let n = 0;
          try {
            if (this._nPtr && !this._nPtr.isNull()) {
              n = this._nPtr.readU32();
            }
          } catch (e2) {
            return;
          }
          if (n <= 0) {
            return;
          }
          const hits = patchBuffer(this._buf, n, null);
          if (hits > 0) {
            state.ioPatches += hits;
            note(
              'ReadFile patched hits=' +
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
      note('hooked ReadFile');
      ok = true;
    } catch (e) {
      note('hook fail ReadFile: ' + e);
    }
  })();

  (function () {
    const addr = resolveExport('kernel32.dll', 'ReadFileEx');
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._key = handleKey(args[0]);
            this._buf = args[1];
            this._n = args[2].toInt32();
            this._kind = this._key ? state.trackedHandles[this._key] || null : null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          // Completion is async; best-effort patch the buffer size requested.
          if (!this._kind || !this._buf || this._n <= 0) {
            return;
          }
          const hits = patchBuffer(this._buf, this._n, null);
          if (hits > 0) {
            state.ioPatches += hits;
            note('ReadFileEx patched hits=' + hits + ' kind=' + this._kind);
          }
        },
      });
      note('hooked ReadFileEx');
      ok = true;
    } catch (e) {
      note('hook fail ReadFileEx: ' + e);
    }
  })();

  // NtReadFile — used by some Node/Chromium IO paths
  (function () {
    const addr = resolveExport('ntdll.dll', 'NtReadFile');
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          try {
            this._key = handleKey(args[0]);
            this._buf = args[5];
            this._n = args[6].toInt32();
            this._iosb = args[4];
            this._kind = this._key ? state.trackedHandles[this._key] || null : null;
          } catch (e) {
            this._kind = null;
          }
        },
        onLeave(retval) {
          if (!this._kind || !this._buf) {
            return;
          }
          let n = this._n;
          try {
            // IO_STATUS_BLOCK.Information
            if (this._iosb && !this._iosb.isNull()) {
              const info = Process.pointerSize === 8
                ? this._iosb.add(Process.pointerSize).readU64()
                : this._iosb.add(4).readU32();
              const infoN = Number(info);
              if (infoN > 0 && infoN < 256 * 1024 * 1024) {
                n = infoN;
              }
            }
          } catch (e) {}
          if (!n || n <= 0) {
            return;
          }
          // STATUS_SUCCESS or STATUS_PENDING (0 / 0x103) — try patch anyway
          const hits = patchBuffer(this._buf, n, null);
          if (hits > 0) {
            state.ioPatches += hits;
            note('NtReadFile patched hits=' + hits + ' kind=' + this._kind + ' n=' + n);
          }
        },
      });
      note('hooked NtReadFile');
      ok = true;
    } catch (e) {
      note('hook fail NtReadFile: ' + e);
    }
  })();

  (function () {
    // MapViewOfFile(hFileMappingObject, dwDesiredAccess, dwFileOffsetHigh,
    //               dwFileOffsetLow, dwNumberOfBytesToMap)
    // CreateFileMapping associates section -> kind.
    state.sectionKinds = state.sectionKinds || {};

    const cfmW = resolveExport('kernel32.dll', 'CreateFileMappingW');
    const cfmA = resolveExport('kernel32.dll', 'CreateFileMappingA');
    function hookCfm(addr, name) {
      if (!addr) {
        return;
      }
      try {
        Interceptor.attach(addr, {
          onEnter(args) {
            try {
              this._key = handleKey(args[0]);
              this._kind = this._key ? state.trackedHandles[this._key] || null : null;
            } catch (e) {
              this._kind = null;
            }
          },
          onLeave(retval) {
            if (!this._kind || retval.isNull()) {
              return;
            }
            const sk = handleKey(retval);
            if (sk) {
              state.sectionKinds[sk] = this._kind;
              note('section ' + sk + ' kind=' + this._kind + ' via ' + name);
            }
          },
        });
        note('hooked ' + name);
        ok = true;
      } catch (e) {
        note('hook fail ' + name + ': ' + e);
      }
    }
    hookCfm(cfmW, 'CreateFileMappingW');
    hookCfm(cfmA, 'CreateFileMappingA');

    // NtMapViewOfSection for Chromium-style mapping
    (function () {
      const addr = resolveExport('ntdll.dll', 'NtMapViewOfSection');
      if (!addr) {
        return;
      }
      try {
        Interceptor.attach(addr, {
          onEnter(args) {
            try {
              this._sk = handleKey(args[0]);
              this._kind = this._sk ? state.sectionKinds[this._sk] || null : null;
              this._baseOut = args[2]; // PVOID *BaseAddress
              this._sizeOut = args[8]; // PSIZE_T ViewSize
            } catch (e) {
              this._kind = null;
            }
          },
          onLeave(retval) {
            if (!this._kind) {
              return;
            }
            try {
              if (retval.toInt32() !== 0) {
                return;
              }
              const base = this._baseOut.readPointer();
              let len = 0;
              try {
                len = Process.pointerSize === 8
                  ? Number(this._sizeOut.readU64())
                  : this._sizeOut.readU32();
              } catch (e) {
                len = 0;
              }
              if (!len || len < 0 || len > 128 * 1024 * 1024) {
                len = 64 * 1024 * 1024;
              }
              const hits = patchBuffer(base, len, null);
              if (hits > 0) {
                state.ioPatches += hits;
                note('NtMapViewOfSection patched hits=' + hits + ' kind=' + this._kind + ' len=' + len);
              }
            } catch (e2) {}
          },
        });
        note('hooked NtMapViewOfSection');
        ok = true;
      } catch (e) {
        note('hook fail NtMapViewOfSection: ' + e);
      }
    })();

    const mv = resolveExport('kernel32.dll', 'MapViewOfFile');
    if (mv) {
      try {
        Interceptor.attach(mv, {
          onEnter(args) {
            try {
              this._sk = handleKey(args[0]);
              this._kind = this._sk ? state.sectionKinds[this._sk] || null : null;
              this._len = 0;
              try {
                // size_t NumberOfBytesToMap — 0 means whole section
                this._len = Process.pointerSize === 8 ? Number(args[4]) : args[4].toInt32();
              } catch (e) {
                this._len = 0;
              }
            } catch (e2) {
              this._kind = null;
            }
          },
          onLeave(retval) {
            if (!this._kind || retval.isNull()) {
              return;
            }
            let len = this._len;
            if (!len || len < 0 || len > 128 * 1024 * 1024) {
              // Unknown size: bounded scan
              len = 64 * 1024 * 1024;
            }
            const hits = patchBuffer(retval, len, null);
            if (hits > 0) {
              state.ioPatches += hits;
              note(
                'MapViewOfFile patched hits=' +
                  hits +
                  ' kind=' +
                  this._kind +
                  ' len=' +
                  len
              );
            } else {
              note('MapViewOfFile ' + this._kind + ' len=' + len + ' (no needles)');
            }
          },
        });
        note('hooked MapViewOfFile');
        ok = true;
      } catch (e) {
        note('hook fail MapViewOfFile: ' + e);
      }
    }

    const mvEx = resolveExport('kernel32.dll', 'MapViewOfFileEx');
    if (mvEx) {
      try {
        Interceptor.attach(mvEx, {
          onEnter(args) {
            try {
              this._sk = handleKey(args[0]);
              this._kind = this._sk ? state.sectionKinds[this._sk] || null : null;
              this._len = 0;
              try {
                this._len = Process.pointerSize === 8 ? Number(args[4]) : args[4].toInt32();
              } catch (e) {
                this._len = 0;
              }
            } catch (e2) {
              this._kind = null;
            }
          },
          onLeave(retval) {
            if (!this._kind || retval.isNull()) {
              return;
            }
            let len = this._len;
            if (!len || len < 0 || len > 128 * 1024 * 1024) {
              len = 64 * 1024 * 1024;
            }
            const hits = patchBuffer(retval, len, null);
            if (hits > 0) {
              state.ioPatches += hits;
              note('MapViewOfFileEx patched hits=' + hits + ' kind=' + this._kind);
            }
          },
        });
        note('hooked MapViewOfFileEx');
        ok = true;
      } catch (e) {
        note('hook fail MapViewOfFileEx: ' + e);
      }
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
  const perLabel = {};
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
      // Per-replacement so we can report labels and use protect on r-x
      for (let r = 0; r < state.replacements.length; r++) {
        const rep = state.replacements[r];
        if (range.size < rep.len) {
          continue;
        }
        try {
          const results = Memory.scanSync(range.base, range.size, rep.oldHex);
          for (let j = 0; j < results.length; j++) {
            if (safeWriteBytes(results[j].address, rep.newBytes, rep.label)) {
              local += 1;
              rep.hitCount += 1;
              perLabel[rep.label] = (perLabel[rep.label] || 0) + 1;
            }
          }
        } catch (e) {}
      }
    }
  } catch (e) {
    note('mem-patch error: ' + e);
  }
  if (local) {
    state.memPatchHits += local;
  }
  state.lastRescanMs = Date.now();
  const detail = Object.keys(perLabel)
    .map(function (k) {
      return k + '=' + perLabel[k];
    })
    .join(',');
  note(
    'mem-patch ' +
      label +
      ' local=' +
      local +
      ' total=' +
      state.memPatchHits +
      (detail ? ' [' + detail + ']' : '')
  );
  return local;
}

function installExitHooks() {
  if (state.hooks.exit) {
    return true;
  }
  // Telemetry only — do not swallow exit(1). Integrity/gate patches must
  // make the CDP gate exit unnecessary.
  ['ExitProcess', 'TerminateProcess'].forEach(function (name) {
    const addr = resolveExport('kernel32.dll', name);
    if (!addr) {
      return;
    }
    try {
      Interceptor.attach(addr, {
        onEnter(args) {
          let c = '?';
          try {
            c = args[name === 'TerminateProcess' ? 1 : 0].toInt32();
          } catch (e) {}
          note(
            'saw ' +
              name +
              '(' +
              c +
              ') io=' +
              state.ioPatches +
              ' mem=' +
              state.memPatchHits +
              ' ageMs=' +
              (Date.now() - state.startMs)
          );
        },
      });
      note('watch ' + name);
    } catch (e) {}
  });
  state.hooks.exit = true;
  return true;
}

function startAutoRescan() {
  if (state.autoRescanTimer) {
    return;
  }
  // Gate JS is deep inside app.asar (~17MB). Early ReadFile only gets the
  // header. Keep rescanning for a few seconds after resume so we catch the
  // gate when Node maps/reads the rest of the archive.
  let ticks = 0;
  state.autoRescanTimer = setInterval(function () {
    ticks += 1;
    try {
      tryMemPatchOnce('auto-' + ticks);
    } catch (e) {
      note('auto-rescan err: ' + e);
    }
    // Stop once gate was hit, or after ~8s
    const gate = state.replacements.filter(function (r) {
      return r.label === 'gate';
    })[0];
    if ((gate && gate.hitCount > 0) || ticks >= 16) {
      clearInterval(state.autoRescanTimer);
      state.autoRescanTimer = null;
      note('auto-rescan stopped ticks=' + ticks + ' gateHits=' + (gate ? gate.hitCount : 0));
    }
  }, 500);
  note('auto-rescan started (500ms x16)');
}

function applyMode(mode) {
  if (mode) {
    state.mode = mode;
  }
  note('mode=' + state.mode);
  if (state.mode !== 'exit-hook') {
    installIoHooks();
  }
  if (state.mode === 'exit-hook' || state.mode === 'both') {
    installExitHooks();
  }
}

function getStatus() {
  return {
    mode: state.mode,
    ioPatches: state.ioPatches,
    memPatchHits: state.memPatchHits,
    blockedExits: state.blockedExits,
    replacements: state.replacements.map(function (r) {
      return r.label + ':' + r.hitCount;
    }),
    trackedHandles: Object.keys(state.trackedHandles).length,
    ageMs: Date.now() - state.startMs,
    events: state.events.slice(-50),
    platform: 'win32',
    lastRescanMs: state.lastRescanMs,
    redirectAsarPath: state.redirectAsarPath,
    redirectHits: state.redirectHits,
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
    if (opts.redirectAsarPath) {
      state.redirectAsarPath = String(opts.redirectAsarPath);
      state.redirectAsarNtPath = ntPathFromWin32(state.redirectAsarPath);
      note('asar redirect target=' + state.redirectAsarPath);
    }
    applyMode(state.mode);
    // Critical: patch Claude.exe embedded asar header hash WHILE SUSPENDED.
    // PE image is already mapped; this does not need IO.
    if (state.mode !== 'exit-hook') {
      tryMemPatchOnce('configure-pre-resume');
    }
    state.configured = true;
    return getStatus();
  },
  rescan() {
    const n = tryMemPatchOnce('rpc-rescan');
    return { mem: n, ioPatches: state.ioPatches, status: getStatus() };
  },
  startWatch() {
    startAutoRescan();
    return getStatus();
  },
  getStatus() {
    return getStatus();
  },
};

installIoHooks();
note('agent loaded (awaiting configure replacements, win32)');
