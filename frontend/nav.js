const DASHBOARD = { donor: 'donor.html', receiver: 'ngo.html', admin: 'admin.html' };
const NAV_ITEMS = {
  guest:    [['index.html', 'Home'], ['impact.html', 'Impact'], ['login.html', 'Log in'], ['signup.html', 'Sign up']],
  donor:    [['donor.html', 'My dashboard'], ['impact.html', 'Impact']],
  receiver: [['ngo.html', 'My dashboard'], ['impact.html', 'Impact']],
  admin:    [['admin.html', 'Admin panel'], ['ngo.html', 'Receivers'], ['impact.html', 'Impact']],
};
function currentPage() {
  return location.pathname.split('/').pop() || 'index.html';
}
function displayName(me) {
  return me.donor_name || me.receiver_name || me.full_name;
}
async function getMe() {
  try { return await apiFetch('/auth/me'); } catch (e) { return null; }
}
async function signOut() {
  try { await apiFetch('/auth/logout', { method: 'POST' }); } catch (e) {}
  location.href = 'login.html';
}
function renderNav(me) {
  const nav = document.getElementById('navbar');
  if (!nav) return;
  const role = me ? me.role : 'guest';
  const page = currentPage();
  const links = (NAV_ITEMS[role] || NAV_ITEMS.guest)
    .map(([href, label]) => `<a href="${href}"${href === page ? ' class="active"' : ''}>${label}</a>`)
    .join('');
  const user = me
    ? `<span class="nav-user" title="${escapeHTML(me.email)}">${escapeHTML(displayName(me))}</span>
       <button type="button" class="nav-signout" id="signOutBtn">Sign out</button>`
    : '';
  nav.innerHTML = `<a class="logo" href="${me ? DASHBOARD[role] : 'index.html'}">🌿 FreshLink</a>
    <div class="nav-links">${links}${user}</div>`;
  const btn = document.getElementById('signOutBtn');
  if (btn) btn.addEventListener('click', signOut);
}
async function initPage({ roles = null, guestOnly = false } = {}) {
  const me = await getMe();
  if (guestOnly && me) {
    location.replace(DASHBOARD[me.role] || 'impact.html');
    return { redirected: true, me };
  }
  if (roles && !me) {
    location.replace('login.html');
    return { redirected: true, me: null };
  }
  if (roles && !roles.includes(me.role)) {
    location.replace(DASHBOARD[me.role] || 'index.html');
    return { redirected: true, me };
  }
  renderNav(me);
  document.body.classList.add('ready');
  return { redirected: false, me };
}
