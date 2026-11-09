// Host regression checks with mocked Harmony services. Does not emulate ArkWeb or device downloads.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const os = require('node:os');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const ts = require(process.env.ARKTS_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets/webvideo');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'webvideo-verify-'));
const fixtures = new Map();
let requests = [], createDelay, createEntered;
const kitFs = {
  OpenMode: { CREATE: 64, WRITE_ONLY: 1, TRUNC: 512, READ_ONLY: 0 },
  accessSync: fs.existsSync, unlinkSync: fs.unlinkSync, renameSync: fs.renameSync,
  statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
  mkdirSync: p => fs.mkdirSync(p, { recursive: true }), listFileSync: fs.readdirSync,
  rmdirSync: fs.rmdirSync, openSync: (p, mode) => ({ fd: fs.openSync(p, mode) }),
  closeSync: f => fs.closeSync(typeof f === 'number' ? f : f.fd),
  readSync: (fd, buf) => fs.readSync(fd, Buffer.from(buf), 0, buf.byteLength, null),
  writeSync: (fd, data) => fs.writeSync(fd, data)
};
const request = { SESSION_SUCCESSFUL: 8, SESSION_FAILED: 16,
  async downloadFile(ctx, config) {
    requests.push(config);
    if (createEntered) createEntered();
    if (createDelay) await createDelay;
    const listeners = new Map(); let paused = false, removed = false, status = 2;
    const finish = () => {
      if (paused || removed || status === 8 || status === 16) return;
      if (!fixtures.has(config.url)) { status = 16; listeners.get('fail')?.(404); return; }
      const data = fixtures.get(config.url);
      fs.writeFileSync(config.filePath, data); status = 8;
      listeners.get('progress')?.(Buffer.byteLength(data), Buffer.byteLength(data));
      listeners.get('complete')?.();
    };
    const task = {
      on: (k, f) => listeners.set(k, f), off: k => listeners.delete(k),
      query: async () => ({ status }), pause: async () => { paused = true; },
      resume: async () => { paused = false; setImmediate(finish); },
      delete: async () => { removed = true; if (fs.existsSync(config.filePath)) fs.unlinkSync(config.filePath); }
    };
    setImmediate(finish); return task;
  }
};
const kits = {
  '@kit.MediaKit': { media: { createAVMetadataExtractor: async () => ({
    fdSrc: undefined,
    async fetchMetadata() {
      const b = Buffer.alloc(128); fs.readSync(this.fdSrc.fd, b, 0, 128, 0);
      if (b[0] === 60) throw new Error('not media');
      return { videoWidth: '1920', videoHeight: '1080' };
    }, async release() {}
  }) } },
  '@kit.CoreFileKit': { fileIo: kitFs }, '@kit.AbilityKit': {},
  '@kit.BasicServicesKit': { request },
  '@kit.ArkTS': { url: { URL }, util: { generateRandomUUID: () => randomUUID() } },
  '@kit.ArkWeb': { webview: { WebCookieManager: { fetchCookie: async target => new URL(target).hostname + '=cookie' } } }
};
const cache = new Map();
function load(name) {
  const filename = path.join(root, name + '.ets');
  if (cache.has(filename)) return cache.get(filename).exports;
  const module = { exports: {} }; cache.set(filename, module);
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext(`(function(require,module,exports){${code}\n})`, { filename })(
    key => key.startsWith('.') ? load(key.slice(2)) : kits[key], module, module.exports);
  return module.exports;
}
const { HlsEngine, DirectEngine, selectVariant } = load('NativeEngines');
const { MediaKind, TaskState } = load('Contracts');
const { NativeTransfer } = load('NativeTransfer');
const { MediaDiscovery, DefaultClassifier, ArkWebHeaders } = load('MediaDiscovery');
const { DownloadManager } = load('DownloadManager');
const { extractPageAddress, canonicalVideoPage } = load('PageAddress');
const { VIDEO_SCRIPT } = load('PageScript');
const options = { network: { metered: false, roaming: false, background: false }, maxVideoHeight: 720 };
let sequence = 0, passed = 0;
function input(source, kind = MediaKind.Hls) {
  const directory = path.join(temp, 'job' + sequence++); fs.mkdirSync(directory);
  return { candidate: { url: source, kind }, page: { url: 'https://page.test/watch?secret=1', title: 'Video', userAgent: 'test-UA' }, directory,
    options, headers: new ArkWebHeaders(), progress: { update() {} } };
}
async function check(name, run) { await run(); passed++; console.log('PASS ' + name); }
(async () => {
  await check('extracts Douyin URL from complete share text and preserves signed query', () => {
    assert.equal(extractPageAddress('2.84 :3pm TLW:/ 12/19 分享文字https://v.douyin.com/xot_p30XZ6A/ 复制打开抖音'), 'https://v.douyin.com/xot_p30XZ6A/');
    assert.equal(extractPageAddress('  https://www.douyin.com/video/123?from=share&token=a%2Fb  '), 'https://www.douyin.com/video/123?from=share&token=a%2Fb');
    assert.equal(extractPageAddress('视频链接：https://v.douyin.com/abc/。'), 'https://v.douyin.com/abc/');
    assert.equal(extractPageAddress('https://[broken https://v.douyin.com/ok/'), 'https://v.douyin.com/ok/');
    assert.equal(extractPageAddress('仅分享文案'), '');
    assert.equal(extractPageAddress('javascript:alert(1)'), '');
  });
  await check('normalizes legacy Douyin video shares without altering other pages or looping', () => {
    assert.equal(canonicalVideoPage('https://www.iesdouyin.com/share/video/7699740412805993317/?region=CN'), 'https://www.douyin.com/video/7699740412805993317');
    assert.equal(canonicalVideoPage('https://iesdouyin.com/share/video/123'), 'https://www.douyin.com/video/123');
    for (const value of ['https://m.douyin.com/share/video/123', 'https://www.douyin.com/video/123',
      'https://v.douyin.com/xot_p30XZ6A/', 'https://iesdouyin.com.attacker.test/share/video/123',
      'https://www.iesdouyin.com/share/note/123/', 'https://www.iesdouyin.com/share/video/not-an-id/', 'invalid']) {
      assert.equal(canonicalVideoPage(value), '', value);
    }
  });
  await check('original page extraction script parses as JavaScript', () => new vm.Script(VIDEO_SCRIPT));
  await check('classifies signed URLs, MIME types and blob separately', () => {
    const c = new DefaultClassifier();
    assert.equal(c.classify('https://cdn.test/a?token=mp4').kind, MediaKind.Unknown);
    assert.equal(c.classify('https://cdn.test/a.M3U8?sig=x').kind, MediaKind.Hls);
    assert.equal(c.classify('https://cdn.test/a', 'application/dash+xml').kind, MediaKind.Dash);
    assert.equal(c.classify('blob:https://page.test/1').kind, MediaKind.Blob);
  });
  await check('late discovery result cannot contaminate a new page', async () => {
    const d = new MediaDiscovery(); let finish;
    const pending = d.scan({ runJavaScript: () => new Promise(r => { finish = r; }) });
    d.reset(); finish(JSON.stringify({ urls: ['https://cdn.test/old.mp4'], activeUrl: '' }));
    await pending; assert.equal(d.candidates().length, 0);
  });
  await check('headers scope cookies to media host and reduce cross-origin referrer', async () => {
    const h = await new ArkWebHeaders().headers('https://cdn.test/a', input('x').page);
    assert.equal(h.Cookie, 'cdn.test=cookie'); assert.equal(h.Referer, 'https://page.test/');
  });
  const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200,RESOLUTION=1920x1080\nhd.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1280x720,AUDIO="a"\nvideo/main.m3u8\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",DEFAULT=YES,URI="audio/main.m3u8"\n';
  await check('selects requested quality without choosing higher bitrate blindly', () => assert.equal(selectVariant(master, 720).height, 720));
  await check('HLS downloads video, audio, init and AES key; publishes fully local manifests', async () => {
    fixtures.set('https://cdn.test/master.m3u8', master);
    fixtures.set('https://cdn.test/video/main.m3u8', '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-KEY:METHOD=AES-128,URI="../secret.key"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:5,\n../part.ts?sig=x\n#EXT-X-ENDLIST');
    fixtures.set('https://cdn.test/audio/main.m3u8', '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\npart.aac\n#EXT-X-ENDLIST');
    ['https://cdn.test/secret.key', 'https://cdn.test/video/init.mp4', 'https://cdn.test/part.ts?sig=x', 'https://cdn.test/audio/part.aac'].forEach(u => fixtures.set(u, 'abcdefghijklmnop'));
    const i = input('https://cdn.test/master.m3u8'); const result = await new HlsEngine({}).create(i).run();
    assert.equal(result.format, 'hls-package'); assert.equal(result.bytes, 64);
    const names = fs.readdirSync(i.directory);
    assert.equal(names.filter(n => n.endsWith('.m3u8')).length, 3);
    for (const name of names.filter(n => n.endsWith('.m3u8'))) {
      const text = fs.readFileSync(path.join(i.directory, name), 'utf8'); assert(!text.includes('https://'));
      const references = [...text.matchAll(/URI="([^"]+)"/g)].map(m => m[1]).concat(text.split('\n').filter(l => l && !l.startsWith('#')));
      for (const ref of references) assert(fs.existsSync(path.join(i.directory, ref)), ref);
    }
    assert(requests.every(r => r.enableMetered === false));
  });
  for (const [name, playlist, code] of [
    ['live', '#EXTM3U\n#EXTINF:5,\na.ts', 'LIVE_UNSUPPORTED'],
    ['range', '#EXTM3U\n#EXT-X-BYTERANGE:10@0\n#EXTINF:5,\na.ts\n#EXT-X-ENDLIST', 'HLS_RANGE_UNSUPPORTED'],
    ['DRM', '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\n#EXTINF:5,\na.ts\n#EXT-X-ENDLIST', 'DRM_UNSUPPORTED']
  ]) await check('rejects unsupported ' + name + ' before publishing', async () => {
    fixtures.set('https://cdn.test/reject.m3u8', playlist); const i = input('https://cdn.test/reject.m3u8');
    await assert.rejects(new HlsEngine({}).create(i).run(), e => e.code === code);
    assert(!fs.existsSync(path.join(i.directory, 'index.m3u8')));
  });
  await check('missing HLS segment never publishes success manifest', async () => {
    fixtures.set('https://cdn.test/missing.m3u8', '#EXTM3U\n#EXTINF:5,\nmissing.ts\n#EXT-X-ENDLIST');
    const i = input('https://cdn.test/missing.m3u8');
    await assert.rejects(new HlsEngine({}).create(i).run()); assert(!fs.existsSync(path.join(i.directory, 'index.m3u8')));
  });
  await check('HTML 200 response is not reported as downloaded video', async () => {
    fixtures.set('https://cdn.test/error.mp4', '<html>login required</html>'); const i = input('https://cdn.test/error.mp4', MediaKind.Direct);
    await assert.rejects(new DirectEngine({}).create(i).run(), e => e.code === 'INVALID_MEDIA');
    assert(!fs.existsSync(path.join(i.directory, 'video.mp4')));
  });
  await check('pause before creation blocks network; cancellation releases waiter', async () => {
    const t = new NativeTransfer({}, options.network); await t.pause(); const count = requests.length;
    const running = t.download('https://cdn.test/x', path.join(temp, 'paused'), {}, () => {});
    await Promise.resolve(); assert.equal(requests.length, count); await t.cancel();
    await assert.rejects(running, e => e.code === 'CANCELLED');
  });
  await check('cancel while system task is being created cannot publish a file', async () => {
    let release, entered; createDelay = new Promise(r => { release = r; }); const started = new Promise(r => { entered = r; }); createEntered = entered;
    const t = new NativeTransfer({}, options.network); const output = path.join(temp, 'cancelled');
    const running = t.download('https://cdn.test/x', output, {}, () => {});
    await started; await t.cancel(); release(); await assert.rejects(running, e => e.code === 'CANCELLED');
    assert(!fs.existsSync(output)); createDelay = undefined; createEntered = undefined;
  });
  await check('manager deduplicates tasks, restores completed history and removes files', async () => {
    const context = { filesDir: path.join(temp, 'manager') }; fs.mkdirSync(context.filesDir);
    const manager = new DownloadManager(context); fixtures.set('https://cdn.test/a.mp4', Buffer.from([0,0,0,24,102,116,121,112,1,2,3,4]));
    const i = input('https://cdn.test/a.mp4', MediaKind.Direct);
    const done = new Promise(resolve => manager.subscribe(tasks => { if (tasks.some(t => t.state === TaskState.Completed)) resolve(); }));
    const id = manager.start(i.candidate, i.page); assert.equal(manager.start(i.candidate, i.page), id);
    await done; const restored = new DownloadManager(context); assert.equal(restored.list()[0].id, id);
    const result = restored.list()[0].result.path; await restored.remove(id); assert(!fs.existsSync(result)); assert.equal(restored.list().length, 0);
  });
  console.log(`${passed} checks passed (host mocks; device integration not covered)`);
})().catch(e => { console.error(e); process.exitCode = 1; }).finally(() => fs.rmSync(temp, { recursive: true, force: true }));
