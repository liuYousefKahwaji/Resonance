const host = 'com.resonance.youtube';

async function native(message) {
  const result = await chrome.runtime.sendNativeMessage(host, message);
  if (!result?.ok) throw new Error(result?.error || 'Open Resonance and start connecting your browser.');
  return result;
}

async function exportSession(source) {
  // This extension only has YouTube host access. Partitioned embeds are not
  // the signed-in top-level Music session and must not override its cookies.
  const cookies = (await chrome.cookies.getAll({domain: 'youtube.com'})).filter(cookie => !cookie.partitionKey);
  await native({command: 'export', source, cookies});
}

async function connect() {
  const pending = await native({command: 'pending'});
  await exportSession(pending.source);
  await chrome.storage.local.set({source: pending.source});
  await chrome.alarms.create('resonance-refresh', {periodInMinutes: 30});
  return {ok: true};
}

async function refresh() {
  const {source} = await chrome.storage.local.get('source');
  if (!source) throw new Error('Start connecting in Resonance, then press Connect here.');
  await exportSession(source);
  return {ok: true};
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return false;
  if (message.command !== 'connect' && message.command !== 'refresh') return false;
  (message.command === 'connect' ? connect() : refresh()).then(reply).catch(() => {
    reply({ok: false, error: 'Open Resonance → Settings → YouTube access → Connect or Reconnect. Sign in to YouTube, then press Connect here.'});
  });
  return true;
});

chrome.cookies.onChanged.addListener(({cookie}) => {
  const host = cookie.domain.replace(/^\./, '');
  if (host === 'youtube.com' || host.endsWith('.youtube.com')) {
    chrome.alarms.create('resonance-cookie-change', {delayInMinutes: 0.5});
  }
});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === 'resonance-refresh' || alarm.name === 'resonance-cookie-change') refresh().catch(() => {});
});
chrome.runtime.onStartup.addListener(() => refresh().catch(() => {}));
