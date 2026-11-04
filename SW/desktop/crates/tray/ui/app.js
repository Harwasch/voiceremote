'use strict';
const invoke = window.__TAURI__.core.invoke;
const $ = id => document.getElementById(id);
let initialized = false;
let qr = '';
let pending = false;
let expiresAt = 0;
async function operation(fn) {
  if (pending) return;
  pending = true;
  try { await fn(); } catch (error) { $('message').textContent = String(error); }
  finally { pending = false; }
}
$('pair-form').addEventListener('submit', event => {
  event.preventDefault();
  const provisioningSecret = $('provisioning-secret').value || null;
  $('provisioning-secret').value = '';
  operation(() => invoke('pair', { provisioningSecret, settings: { account: $('account').value.trim(), device: $('device').value.trim(), role: $('role').value, agents_config: $('agents-config').value.trim() || null, relay: $('relay').value.trim() || null } }));
});
$('confirm-form').addEventListener('submit', event => {
  event.preventDefault();
  operation(async () => { await invoke('confirm', { phrase: $('confirmation').value.trim() }); $('confirmation').value = ''; $('confirm-form').hidden = true; });
});
$('cancel').addEventListener('click', () => operation(() => invoke('cancel')));
$('toggle').addEventListener('click', () => operation(async () => { await invoke('toggle'); $('message').textContent = 'Phone confirmed the capture request'; }));
// Serialize physical edges, including when IPC delivery is delayed. No click
// synthesis: keyboard and pointer share the same monotonic timed adapter.
let gestureQueue = Promise.resolve();
let held = false;
let holdTimer;
function gestureEdge(event, milliseconds = Math.floor(performance.now())) {
  gestureQueue = gestureQueue.then(async () => {
    try { $('message').textContent = await invoke('gesture', { event, milliseconds }); }
    catch (error) { $('message').textContent = String(error); }
  });
}
function pressGesture() {
  if (held) return;
  held = true;
  gestureEdge('press');
  holdTimer = setTimeout(() => { if (held) gestureEdge('advance'); }, 300);
}
function releaseGesture(cancel = false) {
  if (!held) return;
  held = false; clearTimeout(holdTimer);
  gestureEdge(cancel ? 'cancel' : 'release');
}
$('gesture').addEventListener('pointerdown', event => {
  if (event.button !== 0) return;
  $('gesture').setPointerCapture(event.pointerId); pressGesture();
});
$('gesture').addEventListener('pointerup', () => releaseGesture());
$('gesture').addEventListener('pointercancel', () => releaseGesture(true));
$('gesture').addEventListener('lostpointercapture', () => releaseGesture(true));
$('gesture').addEventListener('keydown', event => {
  if ([' ', 'Enter'].includes(event.key)) { event.preventDefault(); pressGesture(); }
});
$('gesture').addEventListener('keyup', event => {
  if ([' ', 'Enter'].includes(event.key)) { event.preventDefault(); releaseGesture(); }
});
window.addEventListener('blur', () => { releaseGesture(true); gestureEdge('cancel'); });
$('autostart').addEventListener('change', () => operation(async () => {
  try { $('autostart').checked = await invoke('autostart', { enabled: $('autostart').checked }); }
  catch (error) { $('autostart').checked = !$('autostart').checked; throw error; }
}));
async function refresh() {
  try {
    const { view, status, devices, settings } = await invoke('snapshot');
    if (!initialized) {
      if (settings) {
        for (const key of ['account', 'device', 'role']) $(key).value = settings[key];
        $('relay').value = settings.relay || '';
        $('agents-config').value = settings.agents_config || '';
      }
      $('autostart').checked = await invoke('autostart', { enabled: null });
      initialized = true;
    }
    $('mode').textContent = status.mode === 'ai_control' ? 'AI Control' : status.mode === 'dictation' ? 'Dictation' : 'Mode unknown';
    $('capture').textContent = !status.connected ? 'Phone disconnected' : status.listening === false ? 'Not listening' : status.listening === true ? 'Listening' : 'Capture unknown';
    $('destination').textContent = status.destination || 'Waiting for phone';
    $('toggle').disabled = !status.connected || !status.capture || status.capture === 'off';
    $('gesture').disabled = !status.connected;
    $('pair').disabled = view.pairing;
    $('cancel').hidden = !view.pairing;
    $('qr-panel').hidden = !view.qr;
    if (view.qr) {
      if (qr !== view.qr.svg) { $('qr').innerHTML = view.qr.svg; qr = view.qr.svg; }
      $('invitation').value = view.qr.invitation;
      expiresAt = view.qr.expires_at;
      $('expiry').textContent = `Rotates in ${Math.max(0, Math.ceil((expiresAt - Date.now()) / 1000))} seconds`;
      // Never show an expired QR even if the backend is offline or stalled.
      if (Date.now() >= expiresAt) $('qr-panel').hidden = true;
    } else { $('qr').replaceChildren(); $('invitation').value = ''; qr = ''; }
    $('confirm-form').hidden = !view.phrase;
    $('phrase').textContent = view.phrase || '';
    if (!pending) $('message').textContent = view.message;
    $('devices').replaceChildren(...devices.map(device => {
      const row = document.createElement('li');
      const label = document.createElement('span');
      label.textContent = `${device.name} · ${device.role.replaceAll('_', ' ')}`;
      const button = document.createElement('button'); button.textContent = 'Revoke';
      button.addEventListener('click', () => operation(() => invoke('revoke', { id: device.id })));
      row.append(label, button); return row;
    }));
    if (!devices.length) { const row = document.createElement('li'); row.textContent = 'No paired devices'; $('devices').append(row); }
  } catch (error) { if (!pending) $('message').textContent = String(error); }
  setTimeout(refresh, 500);
}
setInterval(() => { if (expiresAt && Date.now() >= expiresAt) $('qr-panel').hidden = true; }, 200);
refresh();
