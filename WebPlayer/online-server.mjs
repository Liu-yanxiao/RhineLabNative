import http from 'node:http';
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const www = path.join(here, 'dist');
const dataDir = process.env.RHINE_DATA_DIR || path.join(here, '.online-data');
const collectionDefs = [
  ['gufeng', '古风 DJ', '古风 DJ', '古风DJ'], ['guofeng', '国风混音', '古风 DJ', '国风DJ'],
  ['driving', '开车小曲', '开车小曲', '开车小曲'], ['car-dj', '车载 DJ', '开车小曲', '车载DJ'],
  ['energy', '热血燃曲', '热血', '热血燃曲'], ['battle', '战斗 BGM', '热血', '战斗BGM'],
  ['pop', '流行精选', '流行', '华语流行'], ['world-pop', '欧美流行', '流行', '欧美流行'],
  ['favorites', '喜欢的音乐', '我的歌单', ''], ['custom', '我的歌单', '我的歌单', ''],
];
const genres = [...new Set(collectionDefs.map(d => d[2]))].map((name, i) => ({ id: `genre-${i}`, name }));
let snapshot = { playlists: {}, updated: {}, source: 'xinghai' };
let scan = { running: false };
let scanJob;
let publicKey;
const audioURLs = new Map();

async function save() {
  await mkdir(dataDir, { recursive: true });
  await writeFile(path.join(dataDir, 'library.json'), JSON.stringify(snapshot, null, 2));
}
async function load() {
  try { snapshot = { ...snapshot, ...JSON.parse(await readFile(path.join(dataDir, 'library.json'), 'utf8')) }; }
  catch {
    if (process.env.RHINE_LEGACY_DATA) {
      try { snapshot = { ...snapshot, ...JSON.parse(await readFile(process.env.RHINE_LEGACY_DATA, 'utf8')) }; } catch {}
    }
  }
  for (const [key, value] of Object.entries(snapshot.updated)) if (typeof value === 'number') snapshot.updated[key] = new Date((value + 978307200) * 1000).toISOString();
  if (!snapshot.playlists.gufeng?.length) {
    snapshot.playlists.gufeng = JSON.parse(await readFile(path.join(here, 'music-seed.json'), 'utf8'));
  }
}
async function jsonFetch(url, options = {}) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(18000) });
  if (!response.ok) throw new Error(`音乐服务暂不可用（${response.status}）`);
  const data = await response.json();
  if (data.code !== 200) throw new Error(data.msg || data.message || '音乐服务未返回结果');
  return data;
}
const endpoint = (base, params) => { const url = new URL(base); for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v)); return url; };
const clock = n => `${Math.floor(n / 60)}:${String(Math.floor(n % 60)).padStart(2, '0')}`;
const webURL = value => { try { const u = new URL(value); return ['http:', 'https:'].includes(u.protocol) ? u : null; } catch { return null; } };

async function search(keyword) {
  const data = await jsonFetch(endpoint('https://yy.zddyr.top/web/api/search.php', { source: 'wy', keyword, page: 1, count: 30 }));
  return (data.data || []).map(t => {
    const [m, s] = String(t.interval || '0:0').split(':').map(Number);
    return { songID: String(t.songmid), title: t.name, artist: t.singer, album: t.albumName || '', duration: (m || 0) * 60 + (s || 0), artwork: t.cover || null, platform: 'wy' };
  });
}
async function updateCollections(force = false) {
  if (scanJob) return scanJob;
  scan = { running: true, startedAt: new Date().toISOString() };
  scanJob = (async () => {
    let errors = [];
    for (const [id, , , query] of collectionDefs) {
      if (!query || (!force && snapshot.updated[id] && Date.now() - new Date(snapshot.updated[id]).getTime() < 7 * 86400000)) continue;
      try {
        const tracks = await search(query);
        if (tracks.length) { snapshot.playlists[id] = tracks; snapshot.updated[id] = new Date().toISOString(); await save(); }
      } catch (e) { errors.push('部分频道暂时更新失败，已有歌单仍可播放'); }
    }
    scan = { running: false, finishedAt: new Date().toISOString(), ...(errors.length ? { error: errors[0] } : {}) };
  })().finally(() => { scanJob = undefined; });
  return scanJob;
}

function library() {
  return {
    version: 1, genres, roots: [], scan, onlineEnabled: false,
    albums: collectionDefs.map(([id, title, category, query], i) => {
      const songs = snapshot.playlists[id] || [];
      return {
        id, title, artist: 'RHINE · 频道歌单', genreId: genres.find(g => g.name === category).id,
        discCount: 1, rawGenres: [category], folder: '在线歌单', offline: false, producers: [],
        description: query ? `由“${query}”频道收集的曲目。歌单可手动更新，超过 7 天会在应用打开时更新。` : '你自己的音乐收藏。',
        coverUrl: songs[0]?.artwork ? `/api/artwork/${id}?v=${encodeURIComponent(songs[0].songID)}` : undefined,
        tracks: songs.map((song, n) => ({
          id: `${id}:${song.platform || 'wy'}:${song.songID}`, albumId: id, title: song.title, artist: song.artist,
          trackNumber: n + 1, duration: song.duration, format: 'MP3', codec: 'MP3', lossless: false,
          browserPlayable: true, audioUrl: `/api/audio/${encodeURIComponent(`${id}:${song.platform || 'wy'}:${song.songID}`)}?source=${snapshot.source}`,
          relativePath: '在线曲目',
        })),
      };
    }),
  };
}
function findTrack(id) {
  const [collection, platform, songID] = id.split(':');
  return (snapshot.playlists[collection] || []).find(t => (t.platform || 'wy') === platform && t.songID === songID);
}
async function resolve(track, source) {
  const key = `${source}:${track.platform}:${track.songID}`;
  const cached = audioURLs.get(key);
  if (cached && Date.now() - cached.at < 120000) return cached.url;
  let data;
  if (source === 'hyw') {
    if (!publicKey) {
      const release = await jsonFetch(endpoint('https://103.79.184.97/api/releases', { script: 'HYWmusic_公益版', scriptType: 'free', releaseType: 'lx' }));
      const download = new URL(release.data.url, 'https://103.79.184.97');
      if (download.origin !== 'https://103.79.184.97') throw new Error('HYW 配置地址变更');
      const response = await fetch(download, { signal: AbortSignal.timeout(15000) });
      const script = await response.text();
      publicKey = script.match(/const\s+CARD_KEY\s*=\s*['"]([^'"\r\n]{1,160})['"]/)?.[1];
      if (!publicKey) throw new Error('HYW 公益配置暂不可用');
    }
    data = await jsonFetch(endpoint('https://103.79.184.97/api/music/url', {
      platform: 'wy', source: 'wy', songId: track.songID, songmid: track.songID, name: track.title, singer: track.artist,
      albumName: track.album, interval: clock(track.duration), quality: '128k', key: publicKey,
    }), { headers: { 'X-Card-Key': publicKey, 'User-Agent': 'lx-music-desktop/2.0.0' } });
  } else {
    const token = Buffer.from(JSON.stringify({ device_id: 'lx-online-' + crypto.randomUUID().slice(0, 10), ip: '0.0.0.0', timestamp: Math.floor(Date.now() / 1000), random: crypto.randomUUID().slice(0, 10) })).toString('base64');
    data = await jsonFetch(endpoint('https://yy.zddyr.top/lx/api/', {
      source: 'wy', songmid: track.songID, name: track.title, singer: track.artist, albumName: track.album,
      interval: clock(track.duration), quality: '128k', _t: Date.now(),
    }), { headers: { 'X-Token': token, 'X-Client': 'XingHaiMusicSource/v3.2.15 (macOS)', 'User-Agent': 'lx-music', 'Cache-Control': 'no-cache' } });
  }
  const url = webURL(data.url || (typeof data.data === 'string' ? data.data : data.data?.url));
  if (!url) throw new Error('音源未返回播放地址');
  url.protocol = 'https:';
  const probe = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(8000) });
  if (!probe.ok && probe.status !== 405) throw new Error('播放地址已经过期');
  audioURLs.set(key, { at: Date.now(), url: url.href });
  return url.href;
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.glb': 'model/gltf-binary', '.woff2': 'font/woff2', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ogg': 'audio/ogg', '.mp3': 'audio/mpeg', '.wav': 'audio/wav' };
function send(res, code, value) { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); }
async function body(req) {
  let text = ''; for await (const chunk of req) { text += chunk; if (text.length > 100000) throw new Error('请求太大'); }
  return text ? JSON.parse(text) : {};
}
const server = http.createServer(async (req, res) => {
  try {
    const origin = `http://127.0.0.1:${server.address().port}`;
    if (req.headers.host !== `127.0.0.1:${server.address().port}` || (req.headers.origin && req.headers.origin !== origin)) return send(res, 403, { message: '仅允许本机访问' });
    const url = new URL(req.url, origin);
    if (req.method === 'POST' && !String(req.headers['content-type'] || '').startsWith('application/json')) return send(res, 415, { message: '需要 JSON 请求' });
    if (url.pathname === '/api/library') return send(res, 200, library());
    if (url.pathname === '/api/config') {
      if (req.method === 'POST') { const input = await body(req); if (['xinghai', 'hyw'].includes(input.source)) snapshot.source = input.source; await save(); }
      return send(res, 200, { source: snapshot.source, roots: [], onlineEnabled: false });
    }
    if (url.pathname === '/api/library/scan') { void updateCollections(true); return send(res, 202, library()); }
    if (url.pathname === '/api/search') return send(res, 200, { tracks: await search(url.searchParams.get('q') || '') });
    if (url.pathname === '/api/custom' && req.method === 'POST') {
      const input = await body(req), track = input.track;
      if (!track?.songID || typeof track.title !== 'string' || track.platform !== 'wy') return send(res, 400, { message: '歌曲数据无效' });
      snapshot.playlists.custom ||= [];
      if (!snapshot.playlists.custom.some(t => t.songID === track.songID)) snapshot.playlists.custom.push(track);
      await save(); return send(res, 200, { ok: true });
    }
    if (url.pathname.startsWith('/api/artwork/')) {
      const id = decodeURIComponent(url.pathname.slice('/api/artwork/'.length));
      const artwork = snapshot.playlists[id]?.[0]?.artwork;
      const target = webURL(artwork);
      if (!target || !target.hostname.endsWith('.music.126.net')) return send(res, 404, { message: '没有封面' });
      const image = await fetch(target, { signal: AbortSignal.timeout(10000) });
      if (!image.ok) return send(res, 404, { message: '封面暂不可用' });
      res.writeHead(200, { 'Content-Type': image.headers.get('content-type') || 'image/jpeg', 'Cache-Control': 'public, max-age=3600' });
      return Readable.fromWeb(image.body).pipe(res);
    }
    if (url.pathname.startsWith('/api/audio/')) {
      const track = findTrack(decodeURIComponent(url.pathname.slice('/api/audio/'.length)));
      if (!track) return send(res, 404, { message: '曲目不在歌单里' });
      const preferred = (url.searchParams.get('source') || snapshot.source) === 'hyw' ? 'hyw' : 'xinghai';
      let audio;
      try { audio = await resolve(track, preferred); } catch { audio = await resolve(track, preferred === 'hyw' ? 'xinghai' : 'hyw'); }
      const abort = new AbortController();
      res.on('close', () => abort.abort());
      const upstream = await fetch(audio, { method: req.method === 'HEAD' ? 'HEAD' : 'GET', headers: req.headers.range ? { Range: req.headers.range } : {}, signal: abort.signal });
      if (!upstream.ok) return send(res, 502, { message: '音频连接失效，请换一首' });
      const headers = { 'Content-Type': 'audio/mpeg', 'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes' };
      for (const name of ['content-length', 'content-range']) if (upstream.headers.has(name)) headers[name] = upstream.headers.get(name);
      res.writeHead(upstream.status, headers);
      if (req.method === 'HEAD') return res.end();
      Readable.fromWeb(upstream.body).on('error', () => res.destroy()).pipe(res);
      return;
    }
    if (url.pathname.startsWith('/api/')) return send(res, 404, { message: '此试听版未接入该功能' });
    const file = path.resolve(www, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
    if (!file.startsWith(www + path.sep)) return send(res, 403, { message: '路径无效' });
    const info = await stat(file);
    if (!info.isFile()) return send(res, 404, { message: '没有这个文件' });
    res.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream', 'Content-Length': info.size });
    createReadStream(file).pipe(res);
  } catch (e) {
    if (!res.headersSent) send(res, 502, { message: e.message || '音乐连接失败' }); else res.destroy();
  }
});
await load();
const requestedPort = Number(process.env.RHINE_PORT ?? 57563);
server.once('error', error => { if (error.code === 'EADDRINUSE' && requestedPort !== 0) server.listen(0, '127.0.0.1'); else { console.error('音乐连接启动失败'); process.exit(1); } });
server.on('listening', () => {
  console.log(`RHINE_READY ${server.address().port}`);
  void updateCollections(false);
});
server.listen(requestedPort, '127.0.0.1');
process.on('SIGTERM', () => { server.close(); process.exit(0); });
