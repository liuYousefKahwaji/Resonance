const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function harness() {
  const handlers = {}, calls = [], alarms = [], state = {};
  const source = 'chrome+connector:' + 'a'.repeat(32);
  const chrome = {
    runtime: {
      id: 'our-extension', getURL: path => 'chrome-extension://our-extension/' + path,
      onMessage: {addListener: listener => handlers.message = listener},
      onStartup: {addListener: listener => handlers.startup = listener},
      sendNativeMessage: async (host, message) => {
        calls.push({host, message});
        return message.command === 'pending' ? {ok: true, source} : {ok: true};
      },
    },
    storage: {local: {get: async () => state, set: async value => Object.assign(state, value)}},
    cookies: {
      getAll: async filter => {
        assert.equal(filter.domain, 'youtube.com');
        return [{domain: '.youtube.com', name: 'SID', value: 'fake'}, {domain: '.youtube.com', name: 'SID', value: 'partitioned', partitionKey: {topLevelSite: 'https://example.test'}}];
      },
      onChanged: {addListener: listener => handlers.cookies = listener},
    },
    alarms: {create: async (name, options) => alarms.push({name, options}), onAlarm: {addListener: listener => handlers.alarm = listener}},
  };
  const context = vm.createContext({chrome});
  vm.runInContext(fs.readFileSync('assets/browser_connector/background.js', 'utf8'), context);
  return {context, handlers, calls, alarms, state, source};
}

test('explicit connection uses the pending authorization and omits partitioned cookies', async () => {
  const h = harness();
  await vm.runInContext('connect()', h.context);
  assert.equal(h.calls.length, 2);
  assert.equal(h.calls[1].host, 'com.resonance.youtube');
  assert.equal(h.calls[1].message.source, h.source);
  assert.equal(h.calls[1].message.cookies.length, 1);
  assert.equal(h.calls[1].message.cookies[0].value, 'fake');
  assert.equal(h.state.source, h.source);
  assert.equal(h.alarms[0].name, 'resonance-refresh');
});

test('other extension/page messages cannot request a session export', () => {
  const h = harness();
  assert.equal(h.handlers.message({command: 'connect'}, {id: 'other', url: 'https://evil.test'}, () => {}), false);
  assert.equal(h.handlers.message({command: 'connect'}, {id: 'our-extension', url: 'https://youtube.com'}, () => {}), false);
  assert.equal(h.calls.length, 0);
});

test('refresh requires a connected profile and cookie changes are debounced', async () => {
  const h = harness();
  await assert.rejects(vm.runInContext('refresh()', h.context));
  assert.equal(h.calls.length, 0);
  h.handlers.cookies({cookie: {domain: '.google.com'}});
  assert.equal(h.alarms.length, 0);
  h.handlers.cookies({cookie: {domain: '.youtube.com'}});
  assert.equal(h.alarms[0].name, 'resonance-cookie-change');
  h.state.source = h.source;
  await vm.runInContext('refresh()', h.context);
  assert.equal(h.calls[0].message.source, h.source);
});
