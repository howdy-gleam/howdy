// Exercise the exact script embedded in the Gleam starter pages with a minimal
// DOM and HTTP transport. No dependency or browser installation is required.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const gleam = readFileSync(new URL('../src/howdy/auth/pages.gleam', import.meta.url), 'utf8');
const encoded = gleam.slice(gleam.indexOf('const script = "') + 'const script = '.length).trim();
const script = JSON.parse(encoded.replaceAll('\n', '\\n'));
const settle = () => new Promise(resolve => setImmediate(resolve));
// The English words the server puts in each page's JSON block, as
// pages.words builds them from the catalogue.
const catalogue = JSON.parse(readFileSync(new URL('../locales/pages/en.json', import.meta.url), 'utf8'));
const words = {
  ...catalogue.client,
  passkey_name: catalogue.page.passkey_name_label,
  ...Object.fromEntries(Object.entries(catalogue.error).map(([code, text]) => ['error.' + code, text])),
  ...Object.fromEntries(Object.entries(catalogue.message).map(([code, text]) => ['message.' + code, text])),
};
const wordsBlock = {textContent: JSON.stringify(words)};
// Every page carries its words; a test's document gains them.
const withWords = document => document && {
  ...document,
  getElementById: id => id === 'auth-words' ? wordsBlock : document.getElementById(id),
};
// Browser globals every page has, under whatever a test supplies.
const run = context => vm.runInNewContext(script, {
  URLSearchParams, history: {replaceState() {}}, ...context,
  document: withWords(context.document),
  location: {search: '', hash: '', ...context.location},
});

class Element {
  constructor() { this.children = []; this.handlers = {}; this.dataset = {}; this.elements = {}; }
  addEventListener(event, callback) { this.handlers[event] = callback; }
  async fire(event) { await this.handlers[event]({ preventDefault() {}, currentTarget: this }); await settle(); }
  append(child) { child.parent = this; this.children.push(child); }
  replaceChildren() { this.children = []; }
  remove() { this.parent.children = this.parent.children.filter(child => child !== this); }
  querySelector() { return this.button; }
  querySelectorAll() { return this.buttons || []; }
  reset() { for (const input of Object.values(this.elements)) input.value = ''; }
}

function accountPage({ lifecycle = false, fail = null, approval = false, wrong = false } = {}) {
  const ids = Object.fromEntries(['account', 'status', 'sessions', 'refresh-sessions', 'password-change', 'password-current', 'logout'].map(id => [id, new Element()]));
  if (lifecycle) {
    for (const id of ['linked-providers', 'email-change', 'email-confirm', 'account-delete']) ids[id] = new Element();
    for (const id of ['email-change', 'email-confirm', 'account-delete']) {
      ids[id].button = new Element();
      const field = id === 'email-confirm' ? 'token' : 'email';
      ids[id].elements[field] = {value: field === 'token' ? 'confirmation-secret' : 'new@example.com', focus() { this.focused = true; }};
    }
    ids['email-confirm'].hidden = true;
    if (approval) {
      ids['email-approve'] = new Element();
      ids['email-approve'].button = new Element();
      ids['email-approve'].elements.token = {value: 'approval-secret', focus() { this.focused = true; }};
      ids['email-approve'].hidden = true;
    }
  }
  ids.account.dataset.api = '/api/auth';
  ids['password-change'].button = new Element();
  ids['password-change'].elements.password = { value: 'new synthetic test password' };
  ids['password-current'].button = new Element();
  ids['password-current'].elements.current = { value: 'old synthetic test password' };
  ids['password-current'].elements.password = { value: 'new synthetic test password' };
  ids.account.buttons = [ids['logout'], ids['refresh-sessions'], ids['password-change'].button];
  if (lifecycle) ids.account.buttons.push(...['email-change', 'email-confirm', 'account-delete'].map(id => ids[id].button));
  const calls = [];
  let sessions = [
    { id: 'digest-current', current: true, method: 'email', created_at: 100, last_seen_at: 200 },
    { id: 'digest-other', current: false, method: 'password', created_at: 100, last_seen_at: 200 },
  ];
  run({
    document: { getElementById: id => ids[id] || null, createElement: () => new Element() },
    fetch: async (url, options) => {
      calls.push({ url, ...options });
      if (fail && url.endsWith(fail)) return {status: 403, ok: false, json: async () => ({error: 'Sign in again'})};
      if (url.endsWith('/password/change') && wrong) return {status: 400, ok: false, json: async () => ({code: 'password_incorrect', error: 'current password is incorrect'})};
      if (url.endsWith('/password') && wrong) return {status: 400, ok: false, json: async () => ({code: 'some_new_code', error: 'raw server text'})};
      if (url.endsWith('/providers')) return {status: 200, ok: true, json: async () => [{provider: 'google', issuer: 'https://accounts.google.com'}]};
      if (url.endsWith('/email/change') || url.endsWith('/email/approve')) return {status: 202, ok: true, json: async () => ({message: 'Check your new email address'})};
      if (url.endsWith('/sessions')) return { status: 200, ok: true, json: async () => sessions };
      if (url.endsWith('/password')) sessions = sessions.filter(s => s.current);
      if (url.endsWith('/sessions/revoke')) sessions = sessions.filter(s => s.id !== JSON.parse(options.body).id);
      return { status: 204, ok: true, json: () => { throw Error('204 must not be parsed as JSON'); } };
    },
  });
  return { ids, calls };
}

test('account password change sends the current and new password', async () => {
  const { ids, calls } = accountPage();
  await settle();
  await ids['password-current'].fire('submit');
  assert.equal(ids['password-current'].elements.current.value, '');
  assert.equal(ids['password-current'].elements.password.value, '');
  assert.match(ids.status.textContent, /Password saved/);
  const post = calls.find(call => call.url.endsWith('/password/change'));
  assert.equal(post.method, 'POST');
  assert.deepEqual(JSON.parse(post.body), {
    current: 'old synthetic test password',
    password: 'new synthetic test password',
  });
});

test('errors show the page words for their code, or the server text for unknown codes', async () => {
  const { ids } = accountPage({wrong: true});
  await settle();
  await ids['password-current'].fire('submit');
  assert.equal(ids.status.textContent, words['error.password_incorrect']);
  await ids['password-change'].fire('submit');
  assert.equal(ids.status.textContent, 'raw server text');
});

test('account password reset handles 204, clears the input and refreshes sessions', async () => {
  const { ids, calls } = accountPage();
  await settle();
  assert.equal(ids.sessions.children.length, 2);
  await ids['password-change'].fire('submit');
  assert.equal(ids['password-change'].elements.password.value, '');
  assert.equal(ids.sessions.children.length, 1);
  assert.match(ids.status.textContent, /Password saved/);
  const post = calls.find(call => call.url.endsWith('/password'));
  assert.equal(post.method, 'POST');
  assert.equal(post.credentials, 'same-origin');
  assert.equal(post.headers['Content-Type'], 'application/json');
});

test('revoke and logout use POST, remove the session and disable signed-out controls', async () => {
  const { ids, calls } = accountPage();
  await settle();
  const other = ids.sessions.children[1];
  await other.children[0].fire('click');
  assert.equal(ids.sessions.children.length, 1);
  const revoke = calls.find(call => call.url.endsWith('/sessions/revoke'));
  assert.deepEqual(JSON.parse(revoke.body), { id: 'digest-other' });
  await ids.logout.fire('click');
  assert.equal(ids.sessions.children.length, 0);
  assert.equal(ids.status.textContent, 'You are signed out.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
});

test('revoking the current session leaves the page signed out', async () => {
  const { ids } = accountPage();
  await settle();
  await ids.sessions.children[0].children[0].fire('click');
  assert.equal(ids.status.textContent, 'You are signed out.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
});

test('Google-only login page works without an email form or account controls', () => {
  const status = new Element();
  run({
    document: { getElementById: id => id === 'status' ? status : null },
    fetch: () => { throw Error('provider-only login must use its browser form'); },
  });
});


test('email change requests proof then confirms it and disables signed-out controls', async () => {
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['email-change'].fire('submit');
  assert.equal(ids['email-confirm'].hidden, false);
  assert.equal(ids['email-confirm'].elements.token.focused, true);
  assert.equal(ids['email-change'].elements.email.value, '');
  await ids['email-confirm'].fire('submit');
  assert.equal(ids['email-confirm'].elements.token.value, '');
  assert.match(ids.status.textContent, /Email changed/);
  assert.ok(ids.account.buttons.every(button => button.disabled));
  assert.equal(ids.sessions.children.length, 0);
  const confirmation = calls.find(call => call.url.endsWith('/email/confirm'));
  assert.equal(confirmation.method, 'POST');
  assert.deepEqual(JSON.parse(confirmation.body), {token: 'confirmation-secret'});
});

test('email change with approval asks the current address before the new one', async () => {
  const {ids, calls} = accountPage({lifecycle: true, approval: true});
  await settle();
  await ids['email-change'].fire('submit');
  assert.equal(ids['email-approve'].hidden, false);
  assert.equal(ids['email-approve'].elements.token.focused, true);
  assert.equal(ids['email-confirm'].hidden, true);
  await ids['email-approve'].fire('submit');
  assert.equal(ids['email-approve'].hidden, true);
  assert.equal(ids['email-confirm'].hidden, false);
  assert.equal(ids['email-confirm'].elements.token.focused, true);
  const approvalCall = calls.find(call => call.url.endsWith('/email/approve'));
  assert.deepEqual(JSON.parse(approvalCall.body), {token: 'approval-secret'});
  await ids['email-confirm'].fire('submit');
  assert.match(ids.status.textContent, /Email changed/);
});

test('provider unlink submits only the selected issuer and signs out', async () => {
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['linked-providers'].children[0].children[0].fire('click');
  assert.match(ids.status.textContent, /Provider unlinked/);
  const unlink = calls.find(call => call.url.endsWith('/providers/unlink'));
  assert.equal(unlink.method, 'POST');
  assert.deepEqual(JSON.parse(unlink.body), {issuer: 'https://accounts.google.com'});
  assert.equal(ids['linked-providers'].children.length, 0);
  assert.ok(ids.account.buttons.every(button => button.disabled));
});

test('deletion submits explicit email confirmation and handles a stale session without claiming success', async () => {
  const rejected = accountPage({lifecycle: true, fail: '/account/delete'});
  await settle();
  await rejected.ids['account-delete'].fire('submit');
  assert.equal(rejected.ids.status.textContent, 'Sign in again');
  assert.equal(rejected.ids['account-delete'].button.disabled, false);
  assert.equal(rejected.ids['account-delete'].elements.email.value, 'new@example.com');
  const {ids, calls} = accountPage({lifecycle: true});
  await settle();
  await ids['account-delete'].fire('submit');
  assert.equal(ids.status.textContent, 'Your account has been deleted.');
  assert.ok(ids.account.buttons.every(button => button.disabled));
  const deletion = calls.find(call => call.url.endsWith('/account/delete'));
  assert.equal(deletion.method, 'POST');
  assert.deepEqual(JSON.parse(deletion.body), {email: 'new@example.com'});
});

test('device accounts list, switch and sign-out reload into the remaining account', async () => {
  const ids = Object.fromEntries(['account', 'status', 'sessions', 'refresh-sessions', 'logout', 'logout-all', 'device-accounts'].map(id => [id, new Element()]));
  ids.account.dataset.api = '/api/auth';
  ids.account.buttons = [ids.logout, ids['logout-all']];
  const calls = []; let reloads = 0;
  run({
    document: {getElementById: id => ids[id] || null, createElement: () => new Element()},
    location: {search: '', reload: () => { reloads += 1; }},
    fetch: async (url, options) => {
      calls.push({url, ...options});
      if (url.endsWith('/sessions/accounts')) return {status: 200, ok: true, json: async () => [
        {id: 'digest-ada', current: true, user: {email: 'ada@example.com'}},
        {id: 'digest-bob', current: false, user: {email: 'bob@example.com'}},
      ]};
      if (url.endsWith('/sessions') || url.endsWith('/passkeys') || url.endsWith('/mfa/devices')) return {status: 200, ok: true, json: async () => []};
      if (url.endsWith('/sessions/switch')) return {status: 200, ok: true, json: async () => ({email: 'bob@example.com'})};
      return {status: 204, ok: true, json: () => { throw Error('no body'); }};
    },
  });
  await settle();
  const [ada, bob] = ids['device-accounts'].children;
  assert.match(ada.textContent, /ada@example.com \(current\)/);
  assert.equal(ada.children.length, 0);
  assert.match(bob.textContent, /bob@example.com/);
  await bob.children[0].fire('click');
  assert.deepEqual(JSON.parse(calls.find(c => c.url.endsWith('/sessions/switch')).body), {id: 'digest-bob'});
  assert.equal(reloads, 1);
  // Another account remains, so signing out reloads into it...
  await ids.logout.fire('click');
  assert.deepEqual(JSON.parse(calls.at(-1).body), {});
  assert.equal(reloads, 2);
  // ...while signing out of all accounts ends on a signed-out page.
  await ids['logout-all'].fire('click');
  assert.deepEqual(JSON.parse(calls.at(-1).body), {all: true});
  assert.equal(reloads, 2);
  assert.match(ids.status.textContent, /signed out/);
  assert.equal(ids['device-accounts'].children.length, 0);
});

function passkeyPage({ cancelled = false, mfa = true } = {}) {
  const ids = Object.fromEntries(['status', 'passkey-login', 'mfa-login', 'mfa-verify', 'mfa-send'].map(id => [id, new Element()]));
  ids['passkey-login'].dataset.api = '/api/auth';
  ids['mfa-login'].hidden = true;
  ids['mfa-verify'].button = new Element();
  ids['mfa-verify'].elements = {method: {value: 'recovery'}, code: {value: ' BACKUP '}, remember: {checked: true}};
  const calls = [], ceremonies = [];
  run({
    document: {getElementById: id => ids[id] || null, createElement: () => new Element()},
    location: {search: '?group=team'}, URLSearchParams, atob, btoa,
    navigator: {credentials: {get: async options => {
      ceremonies.push(options);
      return cancelled ? null : {id: 'AQI', rawId: new Uint8Array([1,2]).buffer, type: 'public-key', response: {
        clientDataJSON: new Uint8Array([3]).buffer, authenticatorData: new Uint8Array([4]).buffer,
        signature: new Uint8Array([5]).buffer, userHandle: new Uint8Array([6]).buffer,
      }};
    }}},
    fetch: async (url, options) => {
      calls.push({url, ...options});
      const body = url.endsWith('/passkeys/login') ? {challenge: 'opaque', options: {challenge: 'AQI', rpId: 'example.test', userVerification: 'required'}}
        : url.endsWith('/passkeys/session') ? {mfa_required: mfa} : {id: 'user'};
      return {status: 200, ok: true, json: async () => body};
    },
  });
  return {ids, calls, ceremonies};
}

test('passkey login serializes the assertion and waits for MFA before reporting success', async () => {
  const {ids, calls, ceremonies} = passkeyPage();
  await ids['passkey-login'].fire('click');
  assert.deepEqual([...ceremonies[0].publicKey.challenge], [1,2]);
  assert.equal(ceremonies[0].publicKey.userVerification, 'required');
  assert.deepEqual(JSON.parse(calls[0].body), {group: 'team'});
  const posted = JSON.parse(calls[1].body);
  assert.equal(posted.challenge, 'opaque');
  assert.equal(JSON.parse(posted.credential).response.userHandle, 'Bg');
  assert.equal(ids['mfa-login'].hidden, false);
  assert.match(ids.status.textContent, /Verify your second factor/);
  await ids['mfa-verify'].fire('submit');
  assert.deepEqual(JSON.parse(calls.at(-1).body), {method: 'recovery', code: 'BACKUP', remember: true});
  assert.equal(ids['mfa-login'].hidden, true);
  assert.match(ids.status.textContent, /You are signed in/);
});

test('cancelled passkey prompt does not submit a credential or claim success', async () => {
  const {ids, calls} = passkeyPage({cancelled: true});
  await ids['passkey-login'].fire('click');
  assert.equal(calls.length, 1);
  assert.match(ids.status.textContent, /cancelled/);
  assert.equal(ids['passkey-login'].disabled, false);
});

function autofillPage({ available = true } = {}) {
  const ids = Object.fromEntries(['status', 'request', 'passkey-login', 'mfa-login'].map(id => [id, new Element()]));
  ids.request.dataset.api = '/api/auth';
  const calls = [], ceremonies = [], timers = [];
  let choose;
  run({
    document: {getElementById: id => ids[id] || null, createElement: () => new Element()},
    location: {search: ''}, URLSearchParams, atob, btoa, AbortController,
    setInterval: (callback, delay) => timers.push({callback, delay}),
    PublicKeyCredential: {isConditionalMediationAvailable: async () => available},
    navigator: {credentials: {get: options => {
      ceremonies.push(options);
      if (!options.mediation) return Promise.resolve(null);
      // A conditional request stays pending until the user picks a passkey.
      return new Promise((resolve, reject) => {
        choose = resolve;
        options.signal.addEventListener('abort', () => reject(Object.assign(Error('aborted'), {name: 'AbortError'})));
      });
    }}},
    fetch: async (url, options) => {
      calls.push({url, ...options});
      const body = url.endsWith('/passkeys/login') ? {challenge: 'opaque-' + calls.length, options: {challenge: 'AQI', rpId: 'example.test'}} : {id: 'user'};
      return {status: 200, ok: true, json: async () => body};
    },
  });
  return {ids, calls, ceremonies, timers, choose: credential => choose(credential)};
}

const assertion = {id: 'AQI', rawId: new Uint8Array([1,2]).buffer, type: 'public-key', response: {
  clientDataJSON: new Uint8Array([3]).buffer, authenticatorData: new Uint8Array([4]).buffer,
  signature: new Uint8Array([5]).buffer, userHandle: new Uint8Array([6]).buffer,
}};

test('passkey autofill arms a conditional request, refreshes it and signs in when chosen', async () => {
  const {ids, calls, ceremonies, timers, choose} = autofillPage();
  await settle();
  assert.equal(ceremonies.length, 1);
  assert.equal(ceremonies[0].mediation, 'conditional');
  assert.equal(ids.status.textContent, undefined);
  // Before the five-minute challenge lapses the page swaps in a fresh one,
  // cancelling the pending request without telling the user anything.
  assert.equal(timers.length, 1);
  assert.ok(timers[0].delay < 300000);
  timers[0].callback();
  await settle();
  assert.equal(ceremonies[0].signal.aborted, true);
  assert.equal(ceremonies.length, 2);
  assert.equal(ids.status.textContent, undefined);
  choose(assertion);
  await settle();
  const posted = JSON.parse(calls.at(-1).body);
  assert.ok(calls.at(-1).url.endsWith('/passkeys/session'));
  assert.equal(posted.challenge, 'opaque-2');
  assert.match(ids.status.textContent, /signed in/i);
});

test('the passkey button cancels pending autofill, and autofill stays off where unsupported', async () => {
  const {ids, ceremonies} = autofillPage();
  await settle();
  await ids['passkey-login'].fire('click');
  assert.equal(ceremonies[0].signal.aborted, true);
  assert.equal(ceremonies[1].mediation, undefined);
  assert.match(ids.status.textContent, /cancelled/);
  const unsupported = autofillPage({available: false});
  await settle();
  assert.equal(unsupported.ceremonies.length, 0);
  assert.equal(unsupported.calls.length, 0);
});

test('passkey signup creates the credential before asking for the emailed token', async () => {
  const ids = Object.fromEntries(['status', 'request', 'exchange', 'passkey-signup'].map(id => [id, new Element()]));
  ids.request.dataset.api = '/api/auth';
  ids.exchange.elements.token = {focus() { this.focused = true; }};
  ids['passkey-signup'].button = new Element();
  ids['passkey-signup'].elements = {email: {value: 'ada@example.com'}, name: {value: 'Laptop'}};
  const calls = [];
  run({
    document: {getElementById: id => ids[id] || null, createElement: () => new Element()},
    location: {search: '?group=team'}, URLSearchParams, atob, btoa,
    navigator: {credentials: {create: async options => {
      assert.deepEqual([...options.publicKey.user.id], [7]);
      return {id: 'AQI', rawId: new Uint8Array([1,2]).buffer, type: 'public-key', response: {
        clientDataJSON: new Uint8Array([3]).buffer, attestationObject: new Uint8Array([4]).buffer, getTransports: () => ['internal'],
      }};
    }}},
    fetch: async (url, options) => {
      calls.push({url, ...options});
      const body = url.endsWith('/passkeys/signup')
        ? {challenge: 'opaque', options: {challenge: 'AQI', rp: {id: 'example.test'}, user: {id: 'Bw', name: 'ada@example.com'}, pubKeyCredParams: []}}
        : {message: 'Check your email'};
      return {status: url.endsWith('/confirm') ? 202 : 200, ok: true, json: async () => body};
    },
  });
  await ids['passkey-signup'].fire('submit');
  assert.deepEqual(JSON.parse(calls[0].body), {email: 'ada@example.com', name: 'Laptop', group: 'team'});
  assert.ok(calls[1].url.endsWith('/passkeys/signup/confirm'));
  assert.equal(JSON.parse(calls[1].body).challenge, 'opaque');
  assert.match(ids.status.textContent, /Check your email/);
  assert.equal(ids.exchange.elements.token.focused, true);
});

test('recovery codes render on separate lines and enrollment secrets are cleared', () => {
  const ids = Object.fromEntries(['status', 'sessions', 'recovery-codes', 'mfa-setup-key'].map(id => [id, new Element()]));
  const context = {document: withWords({getElementById: id => ids[id] || null}), URLSearchParams, location: {search: '', hash: ''}};
  vm.createContext(context);
  vm.runInContext(script, context);
  vm.runInContext("signedOut = message => { document.getElementById('status').textContent = message; }", context);
  vm.runInContext("showRecovery({recovery_codes: ['ONE', 'TWO']}, words.mfa_enabled)", context);
  assert.equal(ids['recovery-codes'].textContent, 'ONE\nTWO');
  assert.equal(ids['mfa-setup-key'].textContent, '');
  assert.match(ids.status.textContent, /Save your recovery codes/);
});

function emailLoginPage(hash = '') {
  const ids = Object.fromEntries(['status', 'request', 'exchange'].map(id => [id, new Element()]));
  ids.request.dataset.api = '/api/auth';
  ids.request.elements.email = {value: '', focus() { this.focused = true; }};
  ids.exchange.button = {focus() { this.focused = true; }, disabled: false};
  ids.exchange.elements.token = {value: '', focus() {}};
  const calls = [], replaced = [];
  run({
    document: {getElementById: id => ids[id] || null},
    location: {search: '?group=team', hash, pathname: '/auth/login'},
    history: {replaceState: (_, __, url) => replaced.push(url)},
    fetch: async (url, options) => {
      calls.push({url, ...options});
      return {status: 200, ok: true, json: async () => ({id: 'user'})};
    },
  });
  return {ids, calls, replaced};
}

test('an emailed link fills in its token, drops it from the address and waits for a click', async () => {
  const {ids, calls, replaced} = emailLoginPage('#token=emailed-token');
  assert.equal(ids.exchange.elements.token.value, 'emailed-token');
  assert.deepEqual(replaced, ['/auth/login?group=team']);
  assert.equal(ids.exchange.button.focused, true);
  assert.equal(calls.length, 0);
  await ids.exchange.fire('submit');
  assert.deepEqual(JSON.parse(calls[0].body), {token: 'emailed-token'});
});

test('a six-digit code is sent with the address it was emailed to', async () => {
  const {ids, calls, replaced} = emailLoginPage();
  assert.deepEqual(replaced, []);
  ids.exchange.elements.token.value = ' 012345 ';
  await ids.exchange.fire('submit');
  assert.equal(calls.length, 0);
  assert.match(ids.status.textContent, /email address/);
  assert.equal(ids.request.elements.email.focused, true);
  ids.request.elements.email.value = 'ada@example.com';
  await ids.exchange.fire('submit');
  assert.ok(calls[0].url.endsWith('/session'));
  assert.deepEqual(JSON.parse(calls[0].body), {email: 'ada@example.com', code: '012345', group: 'team'});
});

test('an emailed email-change link opens and fills in its confirmation form', () => {
  const ids = Object.fromEntries(['account', 'status', 'sessions', 'refresh-sessions', 'logout', 'email-confirm'].map(id => [id, new Element()]));
  ids.account.dataset.api = '/api/auth';
  ids['email-confirm'].hidden = true;
  ids['email-confirm'].button = {focus() { this.focused = true; }};
  ids['email-confirm'].elements.token = {value: ''};
  run({
    document: {getElementById: id => ids[id] || null, createElement: () => new Element()},
    location: {hash: '#email-confirm=confirmation-token', pathname: '/auth/account'},
    fetch: async () => ({status: 200, ok: true, json: async () => []}),
  });
  assert.equal(ids['email-confirm'].hidden, false);
  assert.equal(ids['email-confirm'].elements.token.value, 'confirmation-token');
  assert.equal(ids['email-confirm'].button.focused, true);
  assert.match(ids.status.textContent, /Confirm new email/);
});
