/* ─────────────────────────────────────────────────────────
   ngo.js – NGO dashboard logic
   ───────────────────────────────────────────────────────── */

const ngoSelect        = document.getElementById('ngoSelect');
const filterBand       = document.getElementById('filterBand');
const matchBtn         = document.getElementById('matchBtn');
const refreshBtn       = document.getElementById('refreshBtn');
const listingsGrid     = document.getElementById('listingsGrid');
const myMatchesSection = document.getElementById('myMatchesSection');
const myMatchesGrid    = document.getElementById('myMatchesGrid');
const capacityBadge    = document.getElementById('capacityBadge');
const capRemaining     = document.getElementById('capRemaining');

let allListings   = [];   // nearby listings for selected NGO (merged with full data)
let ngoMatches    = [];   // matches belonging to the selected NGO
let countdownTimer = null;

// ── Helper: currently selected NGO id ─────────────────────
function selectedNgoId() {
  return parseInt(ngoSelect.value) || null;
}

/* ═══════════════════════════════════════════════════════════
   LOAD  –  fetch everything needed then render
   ═══════════════════════════════════════════════════════════ */
async function loadAll() {
  const ngoId = selectedNgoId();
  if (!ngoId) {
    listingsGrid.innerHTML = '<div class="empty-state">Select an NGO above to see nearby food</div>';
    myMatchesSection.style.display = 'none';
    capacityBadge.style.display    = 'none';
    return;
  }

  listingsGrid.innerHTML = '<div class="empty-state">⏳ Loading…</div>';

  try {
    // Fetch all three in parallel for speed
    const [nearby, allAvailable, allMatches, caps] = await Promise.all([
      getNearbyListings(ngoId),
      getAvailableListings(),
      getMatches(),
      getNGOCapacity(),
    ]);

    // ── 1. Build listing cards ──────────────────────────
    // nearby_listings_for_ngo gives priority + distance
    // v_available_listings gives freshness_band, expiry, meta
    const byId = Object.fromEntries(allAvailable.map(l => [l.listing_id, l]));
    allListings = nearby.map(n => ({ ...(byId[n.listing_id] ?? {}), ...n }));

    // ── 2. Filter matches to this NGO ──────────────────
    ngoMatches = allMatches.filter(m => m.ngo_id === ngoId);

    // ── 3. Render ──────────────────────────────────────
    renderListings();
    renderMyMatches();

    // ── 4. Capacity badge ──────────────────────────────
    const cap = caps.find(c => c.ngo_id === ngoId);
    if (cap) {
      capRemaining.textContent    = `${parseFloat(cap.remaining_kg).toFixed(1)} kg`;
      capacityBadge.style.display = 'flex';
    }

  } catch (e) {
    showToast(e.message, 'error');
    listingsGrid.innerHTML = `<div class="empty-state">❌ ${e.message}</div>`;
  }
}

/* ═══════════════════════════════════════════════════════════
   LISTINGS GRID  –  available food cards
   ═══════════════════════════════════════════════════════════ */
function renderListings() {
  const band = filterBand.value;
  let list = allListings;

  if (band === 'RED')    list = list.filter(l => l.freshness_band === 'RED');
  if (band === 'YELLOW') list = list.filter(l => ['RED','YELLOW'].includes(l.freshness_band));
  if (band === 'GREEN')  list = list.filter(l => l.freshness_band === 'GREEN');

  if (list.length === 0) {
    listingsGrid.innerHTML = '<div class="empty-state">No food matches the current filter 🎉</div>';
  } else {
    // Pass ngoMatches so each card can show its match status / buttons
    listingsGrid.innerHTML = list.map(l => foodCardHTML(l)).join('');
    listingsGrid.querySelectorAll('[data-match-action]').forEach(btn =>
      btn.addEventListener('click', () => handleAction(btn))
    );
  }

  // Restart countdown ticker
  if (countdownTimer) clearInterval(countdownTimer);
  countdownTimer = setInterval(tickCountdowns, 1000);
}

/* ── Single food card HTML ─────────────────────────────── */
function foodCardHTML(l) {
  const band      = l.freshness_band ?? 'GREEN';
  const freshness = parseFloat(l.freshness    ?? 0);
  const priority  = parseFloat(l.priority     ?? 0);
  const distKm    = parseFloat(l.distance_km  ?? 0);
  const expiry    = l.effective_expiry;

  // Find an active match for this listing that belongs to this NGO
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
    actionRow = `<span style="font-size:.8rem;color:var(--gray-400)">No active match — run Auto-Match</span>`;
  }

  return `
    <div class="food-card band-${band}" id="card-${l.listing_id}">
      <div class="food-card-header">
        <span class="food-card-title">${l.title}</span>
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
        ${l.allergens ? `<div style="font-size:.78rem;color:var(--gray-600);margin-bottom:.4rem">⚠️ Allergens: ${l.allergens}</div>` : ''}
        ${l.pickup_instructions ? `<div style="font-size:.78rem;color:var(--gray-600);margin-bottom:.4rem">📌 ${l.pickup_instructions}</div>` : ''}
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

/* ═══════════════════════════════════════════════════════════
   MY MATCHES SECTION  –  full lifecycle cards per match
   ═══════════════════════════════════════════════════════════ */
function renderMyMatches() {
  // Show all matches for this NGO (active and historical)
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

/* ── Single match card HTML ────────────────────────────── */
function matchCardHTML(m) {
  // Decide which action buttons to show based on status
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

  // Status border colour
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
        <span class="match-card-title">${m.title}</span>
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
      ${m.pickup_instructions ? `<div style="font-size:.82rem;color:var(--gray-600)">📌 ${m.pickup_instructions}</div>` : ''}
      ${buttons ? `<div class="match-card-actions">${buttons}</div>` : ''}
    </div>`;
}

/* ═══════════════════════════════════════════════════════════
   ACTION HANDLER  –  shared by food cards + match cards
   ═══════════════════════════════════════════════════════════ */
async function handleAction(btn) {
  const matchId = parseInt(btn.dataset.match);
  const action  = btn.dataset.matchAction;
  btn.disabled  = true;
  btn.textContent = '⏳…';

  let pickupCode = null;
  if (action === 'picked_up') {
    pickupCode = prompt('🔑 Enter the 4-digit Pickup Code provided by the donor:');
    if (!pickupCode || !pickupCode.trim()) {
      btn.disabled = false;
      btn.textContent = '🚚 Mark Picked Up';
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
    await loadAll();          // full refresh keeps everything in sync
  } catch (e) {
    showToast(e.message, 'error');
    btn.disabled    = false;
    btn.textContent = action;
  }
}

/* ── Countdown ticks ───────────────────────────────────── */
function tickCountdowns() {
  document.querySelectorAll('[data-expiry]').forEach(el => {
    el.textContent = `⏱ ${countdown(el.dataset.expiry)}`;
  });
}

/* ═══════════════════════════════════════════════════════════
   EVENT LISTENERS
   ═══════════════════════════════════════════════════════════ */

// NGO dropdown → reload everything
ngoSelect.addEventListener('change', loadAll);

// Filter dropdown → re-render food cards only (matches unchanged)
filterBand.addEventListener('change', renderListings);

// Refresh button
refreshBtn.addEventListener('click', loadAll);

// Auto-Match button
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

// Auto-refresh every 30 s
setInterval(loadAll, 30_000);

/* ── Load NGO dropdown on page load ───────────────────── */
async function loadNGOs() {
  try {
    const ngos = await getNGOs();
    ngoSelect.innerHTML =
      '<option value="">— Select Receiver / NGO —</option>' +
      ngos.map(n =>
        `<option value="${n.ngo_id}">${n.name} (${(n.receiver_type || 'ngo').replace(/_/g, ' ')}) [cap: ${n.daily_capacity_kg}kg]</option>`
      ).join('');
  } catch (e) {
    showToast(e.message, 'error');
  }
}

loadNGOs();
