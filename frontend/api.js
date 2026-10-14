const API = '';
async function apiFetch(path, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  let res;
  try {
    res = await fetch(`${API}${path}`, { credentials: 'include', ...options, headers });
  } catch (e) {
    throw new Error('Cannot reach the server. Make sure the backend is running.');
  }
  if (!res.ok) {
    const err = await res.json().catch(() => ({ detail: res.statusText }));
    throw new Error(typeof err.detail === 'string' ? err.detail : 'Please check the form and try again.');
  }
  return res.status === 204 ? null : res.json();
}
const getDonors     = () => apiFetch('/donors');
const getCategories = () => apiFetch('/categories');
const getAvailableListings = () => apiFetch('/listings/available');
const getMyListings = () => apiFetch('/listings/my');
const createListing = (data) => apiFetch('/listings', { method: 'POST', body: JSON.stringify(data) });
const getNGOs          = ()       => apiFetch('/receivers');
const getNearbyListings= (ngoId)  => apiFetch(`/receivers/${ngoId}/listings`);
const getNGOCapacity   = ()       => apiFetch('/receivers/capacity');
const setReceiverStatus = (id, status) => apiFetch(`/receivers/${id}/approval`, { method: 'PATCH', body: JSON.stringify({ verification_status: status }) });
const runMatcher    = ()          => apiFetch('/matches/run', { method: 'POST' });
const getMatches    = ()          => apiFetch('/matches');
const updateMatch   = (id, action, pickupCode = null)=> apiFetch(`/matches/${id}`, {
  method: 'PATCH',
  body: JSON.stringify({ action, pickup_code: pickupCode }),
});
const getImpact     = ()          => apiFetch('/impact');
const expireStale   = ()          => apiFetch('/housekeeping/expire', { method: 'POST' });
function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function showToast(msg, type = 'success') {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = msg;
  t.className = `toast ${type}`;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => { t.className = 'toast hidden'; }, 3500);
}
function formatDatetime(iso) {
  if (!iso) return '–';
  return new Date(iso).toLocaleString('en-IN', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: true,
  });
}
function countdown(isoExpiry) {
  const ms = new Date(isoExpiry) - Date.now();
  if (ms <= 0) return '⛔ Expired';
  const h = Math.floor(ms / 36e5);
  const m = Math.floor((ms % 36e5) / 6e4);
  const s = Math.floor((ms % 6e4) / 1000);
  if (h >= 24) return `${Math.floor(h/24)}d ${h%24}h left`;
  if (h > 0)   return `${h}h ${m}m left`;
  return `${m}m ${s}s left`;
}
function clientFreshness(preparedAt, decayRate) {
  const hours = (Date.now() - new Date(preparedAt)) / 36e5;
  const score = Math.max(0, Math.min(100, 100 * Math.exp(-decayRate * Math.max(0, hours))));
  return Math.round(score * 100) / 100;
}
function bandFromScore(score) {
  if (score >= 70) return 'GREEN';
  if (score >= 40) return 'YELLOW';
  return 'RED';
}
function badgeHTML(band) {
  return `<span class="badge badge-${band}">${band}</span>`;
}
