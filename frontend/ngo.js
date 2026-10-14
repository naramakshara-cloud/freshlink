const ngoSelect        = document.getElementById('ngoSelect');
const filterBand       = document.getElementById('filterBand');
const matchBtn         = document.getElementById('matchBtn');
const refreshBtn       = document.getElementById('refreshBtn');
const listingsGrid     = document.getElementById('listingsGrid');
const myMatchesSection = document.getElementById('myMatchesSection');
const myMatchesGrid    = document.getElementById('myMatchesGrid');
const capacityBadge    = document.getElementById('capacityBadge');
const capRemaining     = document.getElementById('capRemaining');
let allListings    = [];
let ngoMatches     = [];
let countdownTimer = null;
let currentUser    = null;
function selectedNgoId() {
  return parseInt(ngoSelect.value) || null;
}
async function loadAll() {
  const ngoId = selectedNgoId();
  if (!ngoId) {
    listingsGrid.innerHTML = '<div class="empty-state">Choose a receiver above to see what they see.</div>';
    myMatchesSection.style.display = 'none';
    capacityBadge.style.display    = 'none';
    return;
  }
  listingsGrid.innerHTML = '<div class="empty-state">⏳ Loading…</div>';
  try {
    const [nearby, allAvailable, allMatches, caps] = await Promise.all([
      getNearbyListings(ngoId),
      getAvailableListings(),
      getMatches(),
      getNGOCapacity(),
    ]);
    const byId = Object.fromEntries(allAvailable.map(l => [l.listing_id, l]));
    allListings = nearby.map(n => ({ ...(byId[n.listing_id] ?? {}), ...n }));
    ngoMatches = allMatches.filter(m => m.receiver_id === ngoId);
    renderListings();
    renderMyMatches();
    const cap = caps.find(c => c.receiver_id === ngoId);
    if (cap) {
      capRemaining.textContent    = `${parseFloat(cap.remaining_kg).toFixed(1)} kg`;
      capacityBadge.style.display = 'flex';
    }
  } catch (e) {
    showToast(e.message, 'error');
    listingsGrid.innerHTML = `<div class="empty-state">❌ ${e.message}</div>`;
  }
}
function renderListings() {
  const band = filterBand.value;
  let list = allListings;
  if (band === 'RED')    list = list.filter(l => l.freshness_band === 'RED');
  if (band === 'YELLOW') list = list.filter(l => ['RED','YELLOW'].includes(l.freshness_band));
  if (band === 'GREEN')  list = list.filter(l => l.freshness_band === 'GREEN');
  if (list.length === 0) {
    listingsGrid.innerHTML = '<div class="empty-state">No food nearby right now 🎉</div>';
  } else {
    listingsGrid.innerHTML = list.map(l => foodCardHTML(l)).join('');
    listingsGrid.querySelectorAll('[data-match-action]').forEach(btn =>
      btn.addEventListener('click', () => handleAction(btn))
    );
  }
  if (countdownTimer) clearInterval(countdownTimer);
  countdownTimer = setInterval(tickCountdowns, 1000);
}
function foodCardHTML(l) {
  const band      = l.freshness_band ?? 'GREEN';
  const freshness = parseFloat(l.freshness    ?? 0);
  const priority  = parseFloat(l.priority     ?? 0);
  const distKm    = parseFloat(l.distance_km  ?? 0);
  const expiry    = l.effective_expiry;
  const match = ngoMatches.find(
    m => m.listing_id === l.listing_id &&
         ['pending','accepted','picked_up'].includes(m.status)
  );
  let actionRow;
  if (match) {
    if (match.status === 'pending') {
      actionRow = `
        <button class="btn btn-accept" data-match-action="accepted"  data-match="${match.match_id}">✅ Accept</button>
        <button class="btn btn-reject" data-match-action="rejected"  data-match="${match.match_id}">❌ Reject</button>`;
    } else if (match.status === 'accepted') {
      actionRow = `
        <span class="status-pill status-accepted" style="margin-right:.5rem">Accepted</span>
        <button class="btn btn-primary" data-match-action="picked_up" data-match="${match.match_id}">🚚 Mark Picked Up</button>`;
    } else if (match.status === 'picked_up') {
      actionRow = `
        <span class="status-pill status-picked_up" style="margin-right:.5rem">Picked Up</span>
        <button class="btn btn-primary" data-match-action="completed" data-match="${match.match_id}">✅ Mark Delivered</button>`;
    }
  } else {
    actionRow = `<span style="font-size:.8rem;color:var(--gray-400)">Not matched yet — the system assigns food automatically</span>`;
  }
  return `
    <div class="food-card band-${band}" id="card-${l.listing_id}">
      <div class="food-card-header">
        <span class="food-card-title">${escapeHTML(l.title)}</span>
        <span class="priority-chip">⬆ ${priority}</span>
      </div>
      <div class="food-card-body">
        <div class="food-card-meta">
          <span>⚖️ ${l.quantity_kg} kg</span>
          <span>📍 ${distKm} km away</span>
          <span>${l.is_veg ? '🌱 Veg' : '🍖 Non-Veg'}</span>
          ${l.suitable_for_animals ? '<span>🐾 Animal-Safe</span>' : ''}
          ${l.servings ? `<span>🍽️ ~${l.servings} servings</span>` : ''}
          ${l.requires_refrigeration ? '<span>❄️ Needs fridge</span>' : ''}
        </div>
        ${l.allergens ? `<div style="font-size:.78rem;color:var(--gray-600);margin-bottom:.4rem">⚠️ Allergens: ${escapeHTML(l.allergens)}</div>` : ''}
        ${l.pickup_instructions ? `<div style="font-size:.78rem;color:var(--gray-600);margin-bottom:.4rem">📌 ${escapeHTML(l.pickup_instructions)}</div>` : ''}
        <span class="countdown ${band}" data-expiry="${expiry}">
          ⏱ ${countdown(expiry)}
        </span>
        <div class="freshness-bar-wrap">
          <div class="freshness-bar-label">
            <span>Freshness ${badgeHTML(band)}</span>
            <span>${freshness}/100</span>
          </div>
          <div class="freshness-bar-bg">
            <div class="freshness-bar-fill fill-${band}" style="width:${freshness}%"></div>
          </div>
        </div>
      </div>
      <div class="food-card-actions">${actionRow}</div>
    </div>`;
}
function renderMyMatches() {
  if (ngoMatches.length === 0) {
    myMatchesSection.style.display = 'none';
    return;
  }
  myMatchesSection.style.display = 'block';
  myMatchesGrid.innerHTML = ngoMatches.map(m => matchCardHTML(m)).join('');
  myMatchesGrid.querySelectorAll('[data-match-action]').forEach(btn =>
    btn.addEventListener('click', () => handleAction(btn))
  );
}
function matchCardHTML(m) {
  let buttons = '';
  if (m.status === 'pending') {
    buttons = `
      <button class="btn btn-accept" data-match-action="accepted"  data-match="${m.match_id}">✅ Accept</button>
      <button class="btn btn-reject" data-match-action="rejected"  data-match="${m.match_id}">❌ Reject</button>`;
  } else if (m.status === 'accepted') {
    buttons = `
      <button class="btn btn-primary" data-match-action="picked_up" data-match="${m.match_id}">🚚 Mark Picked Up</button>`;
  } else if (m.status === 'picked_up') {
    buttons = `
      <button class="btn btn-primary" data-match-action="completed" data-match="${m.match_id}">✅ Mark Delivered</button>`;
  }
  const borderMap = {
    pending:   'var(--yellow)',
    accepted:  'var(--green)',
    picked_up: 'var(--blue)',
    completed: 'var(--gray-400)',
    rejected:  'var(--red)',
    cancelled: 'var(--gray-300)',
  };
  const border = borderMap[m.status] ?? 'var(--gray-200)';
  return `
    <div class="match-card" style="border-left:4px solid ${border}">
      <div class="match-card-header">
        <span class="match-card-title">${escapeHTML(m.title)}</span>
        <span class="status-pill status-${m.status}">${m.status.replace('_',' ')}</span>
      </div>
      <div class="match-card-meta">
        <span>⚖️ ${parseFloat(m.quantity_kg).toFixed(1)} kg</span>
        <span>📍 ${m.distance_km} km</span>
        <span>${m.is_veg ? '🌱 Veg' : '🍖 Non-Veg'}</span>
        ${m.suitable_for_animals ? '<span>🐾 Animal-Safe</span>' : ''}
        <span>⬆ Priority ${m.priority_score}</span>
        <span>💧 Freshness: ${m.freshness_at_match}</span>
        ${m.pickup_code ? `<span style="background:var(--gray-100);padding:.15rem .45rem;border-radius:4px;font-family:monospace;font-weight:700">🔑 Code: ${m.pickup_code}</span>` : ''}
      </div>
      ${m.pickup_instructions ? `<div style="font-size:.82rem;color:var(--gray-600)">📌 ${escapeHTML(m.pickup_instructions)}</div>` : ''}
      ${buttons ? `<div class="match-card-actions">${buttons}</div>` : ''}
    </div>`;
}
async function handleAction(btn) {
  const matchId = parseInt(btn.dataset.match);
  const action  = btn.dataset.matchAction;
  const originalText = btn.textContent;
  btn.disabled  = true;
  btn.textContent = '⏳…';
  let pickupCode = null;
  if (action === 'picked_up') {
    pickupCode = prompt('🔑 Enter the 4-digit Pickup Code provided by the donor:');
    if (!pickupCode || !pickupCode.trim()) {
      btn.disabled = false;
      btn.textContent = originalText;
      showToast('Pickup code is required to confirm collection.', 'error');
      return;
    }
    pickupCode = pickupCode.trim();
  }
  const toastMsg = {
    accepted:  '✅ Match accepted!',
    rejected:  '❌ Rejected — food returned to the pool',
    picked_up: '🚚 Marked as picked up!',
    completed: '🎉 Marked as delivered!',
  };
  try {
    await updateMatch(matchId, action, pickupCode);
    showToast(toastMsg[action] ?? 'Updated');
    await loadAll();
  } catch (e) {
    showToast(e.message, 'error');
    btn.disabled    = false;
    btn.textContent = originalText;
  }
}
function tickCountdowns() {
  document.querySelectorAll('[data-expiry]').forEach(el => {
    el.textContent = `⏱ ${countdown(el.dataset.expiry)}`;
  });
}
ngoSelect.addEventListener('change', loadAll);
filterBand.addEventListener('change', renderListings);
refreshBtn.addEventListener('click', loadAll);
matchBtn.addEventListener('click', async () => {
  matchBtn.disabled    = true;
  matchBtn.textContent = '⏳ Matching…';
  try {
    const res = await runMatcher();
    showToast(`⚡ ${res.matched} new match${res.matched !== 1 ? 'es' : ''} created!`);
    await loadAll();
  } catch (e) {
    showToast(e.message, 'error');
  } finally {
    matchBtn.disabled    = false;
    matchBtn.textContent = '⚡ Run Auto-Match';
  }
});
async function start() {
  const session = await initPage({ roles: ['receiver', 'admin'] });
  if (session.redirected) return;
  currentUser = session.me;
  if (currentUser.role === 'admin') {
    matchBtn.style.display = '';
    try {
      const receivers = await getNGOs();
      ngoSelect.innerHTML = '<option value="">— Select receiver —</option>' +
        receivers.map(r =>
          `<option value="${r.receiver_id}">${escapeHTML(r.name)} (${(r.receiver_type || 'ngo').replace(/_/g, ' ')}) [cap: ${r.daily_capacity_kg}kg]</option>`
        ).join('');
    } catch (e) {
      showToast(e.message, 'error');
    }
    listingsGrid.innerHTML = '<div class="empty-state">Choose a receiver above to see what they see.</div>';
    setInterval(loadAll, 30000);
    return;
  }
  if (!currentUser.receiver_id) {
    listingsGrid.innerHTML = '<div class="empty-state">No receiver profile is linked to this account.</div>';
    return;
  }
  ngoSelect.innerHTML = `<option value="${currentUser.receiver_id}">${escapeHTML(currentUser.receiver_name || currentUser.full_name)}</option>`;
  ngoSelect.disabled = true;
  if (currentUser.verification_status !== 'approved') {
    listingsGrid.innerHTML = '<div class="empty-state">⏳ Your account is waiting for admin approval. Nearby food will appear here once you are approved.</div>';
    return;
  }
  loadAll();
  setInterval(loadAll, 30000);
}
start();
