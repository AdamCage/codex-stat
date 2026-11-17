param([string]$CodexPath = '', [string]$Proxy = '')
$node = $env:CODEX_NODE
if (-not $node) { $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $node -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
    $node = Get-AppxPackage -Name 'OpenAI.CodexPrimaryRuntime*' | Sort-Object Version -Descending | ForEach-Object {
        $candidate = Join-Path $_.InstallLocation 'dependencies\node\bin\node.exe'
        if (Test-Path -LiteralPath $candidate) { $candidate }
    } | Select-Object -First 1
}
if (-not $node) {
    Write-Error 'Установите Node.js 22.15 или новее и добавьте node в PATH.'
    exit 1
}
Write-Host 'Собираю статистику по локальным сессиям Codex. Одна строка CSV на сессию.'
$OutputPath = (Read-Host 'Имя или путь к CSV (Enter — имя пользователя)').Trim()
if (-not $Proxy) {
    do { $Proxy = (Read-Host 'Статистика по ИИ-прокси? (y/n)').Trim().ToLowerInvariant() }
    until ($Proxy -in 'y','n')
}
$payload = @'
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const zlib = require('node:zlib');
const readline = require('node:readline');
const { pipeline } = require('node:stream/promises');

const [answer, target, source] = process.argv.slice(2).map(value => value === '--default' ? '' : value);
const log = message => console.log(message);
const iso = value => Number.isFinite(value) ? new Date(value).toISOString() : '';
const csv = value => '"' + String(value ?? '').replaceAll('"', '""') + '"';
const sessions = new Map();
const turns = new Map();
const terminals = new Map();
const responses = new Set();
const requestStarts = new Map();
const periodStart = Date.parse('2026-09-01T00:00:00+03:00');
const usageRecords = [];
let duplicates = 0;
let invalid = 0;

function session(id) {
  if (!sessions.has(id)) sessions.set(id, {
    id, start: Infinity, input: 0, output: 0, usageCount: 0, measuredOutput: 0, duration: 0, ttft: [],
    errors: new Set(),
  });
  return sessions.get(id);
}

async function readRollout(file) {
  const fileId = path.basename(file).match(/([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})\.jsonl(?:\.zst)?$/i)?.[1];
  let currentId;
  const input = fs.createReadStream(file);
  const stream = file.endsWith('.zst') ? zlib.createZstdDecompress() : null;
  const complete = stream ? pipeline(input, stream) : null;
  complete?.catch(() => {});
  const lines = readline.createInterface({ input: stream ?? input, crlfDelay: Infinity });
  for await (const line of lines) {
    if (!/"(?:session_meta|task_started|task_complete|turn_aborted|token_usage_record)"/.test(line)) continue;
    let row;
    try { row = JSON.parse(line); } catch { invalid++; continue; }
    const p = row.payload;
    if (!p) continue;
    const timestamp = Date.parse(row.timestamp);
    if (row.type === 'session_meta' && p.id) {
      currentId = p.id;
      if ((!fileId || fileId === currentId) && timestamp >= periodStart) {
        const start = Date.parse(p.timestamp ?? row.timestamp);
        const s = session(currentId);
        if (Number.isFinite(start)) s.start = Math.min(s.start, start);
      }
    }
    if (row.type === 'token_usage_record' && p.thread_id && p.response_id) {
      const inputTokens = p.usage?.input_tokens;
      const outputTokens = p.usage?.output_tokens;
      if (![inputTokens, outputTokens].every(n => Number.isSafeInteger(n) && n >= 0)) continue;
      if (responses.has(p.response_id)) { duplicates++; continue; }
      responses.add(p.response_id);
      usageRecords.push({ p, timestamp, inputTokens, outputTokens });
    }
    if (row.type !== 'event_msg' || !currentId || !p.turn_id) continue;
    if (p.type === 'task_started') {
      const start = Number.isFinite(p.started_at) ? p.started_at * 1000 : timestamp;
      if (Number.isFinite(start)) requestStarts.set(p.turn_id, Math.min(start, requestStarts.get(p.turn_id) ?? Infinity));
      if (start >= periodStart && (!fileId || fileId === currentId)) {
        const s = session(currentId);
        s.start = Math.min(s.start, start);
      }
    }
    if (!['task_complete', 'turn_aborted'].includes(p.type)) continue;
    if (!terminals.has(p.turn_id)) terminals.set(p.turn_id, new Map());
    const copies = terminals.get(p.turn_id);
    const time = Number.isFinite(timestamp) ? timestamp : 0;
    const start = Number.isFinite(p.started_at) ? p.started_at * 1000 : NaN;
    if (Number.isFinite(start)) requestStarts.set(p.turn_id, Math.min(start, requestStarts.get(p.turn_id) ?? Infinity));
    const prior = copies.get(currentId);
    if (!prior || time >= prior.time) copies.set(currentId, {
      time, start, duration: p.duration_ms,
      ttft: p.time_to_first_token_ms, ok: p.type === 'task_complete' && !p.error,
      error: p.type === 'task_complete' && p.error
        ? (typeof p.error === 'string' ? p.error : p.error.message) || 'Сообщение об ошибке отсутствует в журнале.'
        : null,
    });
  }
  await complete;
}

function collectUsage() {
  for (const { p, timestamp, inputTokens, outputTokens } of usageRecords) {
      const start = requestStarts.get(p.turn_id) ?? timestamp;
      if (!(start >= periodStart)) continue;
      const s = session(p.thread_id);
      s.usageCount++;
      s.input += inputTokens;
      s.output += outputTokens;
      s.start = Math.min(s.start, start);
      if (!p.turn_id) continue;
      const turn = turns.get(p.turn_id) ?? { session: s, input: 0, output: 0 };
      if (turn.session !== s) throw new Error('Один запуск связан с несколькими сессиями.');
      turn.output += outputTokens;
      turn.input += inputTokens;
      turns.set(p.turn_id, turn);
  }
}

async function main() {
  if (!['y', 'n'].includes(answer)) throw new Error('Ответьте y или n.');
  if (typeof zlib.createZstdDecompress !== 'function') throw new Error('Требуется Node.js 22.15 или новее с поддержкой Zstandard.');
  const home = path.resolve(source || process.env.CODEX_HOME || path.join(os.homedir(), '.codex'));
  const defaultName = os.userInfo().username + '.csv';
  const filename = target?.trim() || defaultName;
  const output = path.resolve(/\.csv$/i.test(filename) ? filename : filename + '.csv');
  log('1/4. Ищу обычные и сжатые журналы Codex в ' + home);
  const files = ['sessions','archived_sessions'].flatMap(dir => {
    const root = path.join(home, dir);
    if (!fs.existsSync(root)) return [];
    return fs.readdirSync(root, { recursive: true, withFileTypes: true })
      .filter(f => f.isFile() && /^rollout-.*\.jsonl(?:\.zst)?$/.test(f.name))
      .map(f => path.join(f.parentPath, f.name)).sort();
  });
  if (!files.length) throw new Error('Журналы не найдены. Проверьте CODEX_HOME или передайте путь к папке Codex.');
  log('2/4. Читаю ' + files.length + ' файлов. Содержимое сообщений в CSV не записывается.');
  for (const [i, file] of files.entries()) {
    await readRollout(file);
    if ((i + 1) % 50 === 0 || i + 1 === files.length) log('Прочитано ' + (i + 1) + ' из ' + files.length);
  }
  log('3/4. Считаю метрики по сессиям. Повторных записей ответов: ' + duplicates + '.');
  log('Учитываю запросы с 01.09.2026, 00:00 МСК, по времени начала.');
  collectUsage();
  if (invalid) log('Пропущены повреждённые записи: ' + invalid + '.');
  let successes = 0;
  const metrics = { 'Входные токены': [], 'Выходные токены': [], 'TTFT, с': [], 'TPS, токенов/с': [] };
  const requests = new Set([...turns.keys(), ...[...requestStarts].filter(([, start]) => start >= periodStart).map(([id]) => id)]);
  for (const [id, copies] of terminals) {
    const usage = turns.get(id);
    const entry = copies.size === 1 ? [...copies.entries()][0] : null;
    const s = usage?.session ?? (entry ? sessions.get(entry[0]) : null);
    let terminal = copies.get(s?.id);
    if (!terminal) {
      const alternatives = [...copies.values()];
      const first = alternatives[0];
      if (alternatives.every(t => t.ok === first.ok && t.start === first.start && t.duration === first.duration && t.ttft === first.ttft && t.error === first.error)) terminal = first;
    }
    if (!((requestStarts.get(id) ?? terminal?.time) >= periodStart)) continue;
    requests.add(id);
    if (Number.isFinite(terminal?.start)) requestStarts.set(id, Math.min(terminal.start, requestStarts.get(id) ?? Infinity));
    if (terminal?.error && s) s.errors.add(terminal.error);
    if (!terminal?.ok) continue;
    successes++;
    if (Number.isFinite(terminal.ttft) && terminal.ttft >= 0) metrics['TTFT, с'].push(terminal.ttft / 1000);
    if (usage) {
      metrics['Входные токены'].push(usage.input);
      metrics['Выходные токены'].push(usage.output);
      if (terminal.duration > 0) metrics['TPS, токенов/с'].push(usage.output * 1000 / terminal.duration);
    }
    if (!s) continue;
    if (Number.isFinite(terminal.start)) s.start = Math.min(s.start, terminal.start);
    if (Number.isFinite(terminal.ttft) && terminal.ttft >= 0) s.ttft.push(terminal.ttft);
    if (usage && terminal.duration > 0) {
      s.measuredOutput += usage.output;
      s.duration += terminal.duration;
    }
  }
  const rows = ['datetime,session_id,input tokens,output tokens,ttft,tps,is_proxy,status,details'];
  const format = n => Number.isFinite(n) ? Number(n.toFixed(6)) : '';
  for (const s of [...sessions.values()].sort((a,b) => a.start - b.start || a.id.localeCompare(b.id))) {
    s.ttft.sort((a,b) => a-b);
    const mid = Math.floor(s.ttft.length / 2);
    const ttft = s.ttft.length % 2 ? s.ttft[mid] : (s.ttft[mid-1] + s.ttft[mid]) / 2;
    rows.push([
      csv(iso(s.start)), csv(s.id), s.usageCount ? s.input : '', s.usageCount ? s.output : '', format(ttft / 1000),
      format(s.duration ? s.measuredOutput * 1000 / s.duration : NaN), answer === 'y' ? 1 : 0,
      s.errors.size ? 'error' : 'succes', csv([...s.errors].join('\n').replace(/^(\s*[=+@-]|[\t\r\n])/u, "'$&")),
    ].join(','));
  }
  log('4/4. Записываю CSV с ' + sessions.size + ' строками. TTFT в секундах, TPS с учётом полного времени запусков.');
  fs.writeFileSync(output, '\uFEFF' + rows.join('\r\n') + '\r\n');
  log('Готово: ' + output);
  const number = new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 2 });
  const dates = [...requestStarts.values()].filter(start => start >= periodStart).sort((a,b) => a-b);
  log('');
  log('Статистика пользователя ' + os.userInfo().username);
  log('Период (UTC): ' + (dates.length ? iso(dates[0]) + ' — ' + iso(dates.at(-1)) : 'нет дат'));
  log('Запросов Codex: ' + requests.size + ' · успешных: ' + successes + ' · доля: ' +
    (requests.size ? number.format(100 * successes / requests.size) + '%' : '—'));
  log('');
  log('Метрики успешных запросов');
  const labels = {
    'Входные токены': 'Входные токены на запрос',
    'Выходные токены': 'Выходные токены на запрос',
    'TTFT, с': 'Время до первого токена (TTFT), с',
    'TPS, токенов/с': 'Выходные токены за секунду полного запроса (TPS)',
  };
  const table = [['Показатель', 'Среднее', 'Медиана', 'Измерений']];
  for (const [name, values] of Object.entries(metrics)) {
    values.sort((a,b) => a-b);
    const n = values.length;
    const mid = Math.floor(n / 2);
    const median = n % 2 ? values[mid] : (values[mid-1] + values[mid]) / 2;
    const average = values.reduce((sum, v) => sum + v, 0) / n;
    table.push([labels[name], n ? number.format(average) : '—',
      n ? number.format(median) : '—', number.format(n)]);
  }
  const widths = table[0].map((_, i) => Math.max(...table.map(row => row[i].length)));
  const line = row => row.map((value, i) => i === 0 ? value.padEnd(widths[i]) : value.padStart(widths[i])).join(' | ');
  log(line(table[0]));
  log(widths.map(width => '-'.repeat(width)).join('-+-'));
  for (const row of table.slice(1)) log(line(row));
  log('Полное время запроса включает ожидание и работу инструментов.');
}
main().catch(error => { console.error('Ошибка: ' + error.message); process.exitCode = 1; });
'@
$previousEncoding = $OutputEncoding
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    if (-not $OutputPath) { $OutputPath = '--default' }
    if (-not $CodexPath) { $CodexPath = '--default' }
    $payload | & $node - $Proxy.Trim().ToLowerInvariant() "$OutputPath" "$CodexPath"
    $status = $LASTEXITCODE
} finally {
    $OutputEncoding = $previousEncoding
}
exit $status
