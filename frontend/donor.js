const form        = document.getElementById('donorForm');
const donorSel    = document.getElementById('donorSelect');
const categorySel = document.getElementById('categorySelect');
const titleInput  = document.getElementById('titleInput');
const descInput   = document.getElementById('descInput');
const qtyInput    = document.getElementById('quantityInput');
const servInput   = document.getElementById('servingsInput');
const prepInput   = document.getElementById('preparedAt');
const expInput    = document.getElementById('expiresAt');
const submitBtn   = document.getElementById('submitBtn');
const freshnessPreview = document.getElementById('freshnessPreview');
const previewBadge     = document.getElementById('previewBadge');
const previewScore     = document.getElementById('previewScore');
const myListings       = document.getElementById('myListings');
let categoryData = [];
let myListingData = [];
let me = null;
function setDefaultTimes() {
  const now = new Date();
  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  prepInput.value = local(now);
  expInput.value = local(new Date(now.getTime() + 6 * 36e5));
}
async function loadCategories() {
  try {
    categoryData = await getCategories();
    categorySel.innerHTML = '<option value="">— Select category —</option>' +
      categoryData.map(c =>
        `<option value="${c.category_id}">${escapeHTML(c.name)}${c.requires_refrigeration ? ' ❄️' : ''}</option>`
      ).join('');
  } catch (e) {
    showToast(e.message, 'error');
  }
}
function updateFreshnessPreview() {
  const catId = parseInt(categorySel.value);
  const cat   = categoryData.find(c => c.category_id === catId);
  const prep  = prepInput.value;
  if (!cat || !prep) { freshnessPreview.style.display = 'none'; return; }
  const score = clientFreshness(new Date(prep), parseFloat(cat.decay_rate ?? 0.1));
  const band  = bandFromScore(score);
  freshnessPreview.style.display = 'flex';
  previewBadge.className = `badge badge-${band}`;
  previewBadge.textContent = band;
  previewScore.textContent = `${score}/100`;
}
categorySel.addEventListener('change', updateFreshnessPreview);
prepInput.addEventListener('input', updateFreshnessPreview);
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const category_id = parseInt(categorySel.value);
  const title       = titleInput.value.trim();
  const quantity_kg = parseFloat(qtyInput.value);
  const servings    = parseInt(servInput.value) || null;
  const prepared_at = prepInput.value;
  const expires_at  = expInput.value;
  const description = descInput.value.trim() || null;
  if (!category_id || !title || !quantity_kg || !prepared_at || !expires_at) {
    showToast('Fill in the category, title, quantity and both times.', 'error');
    return;
  }
  if (new Date(expires_at) <= new Date(prepared_at)) {
    showToast('Expiry time must be after the time it was prepared.', 'error');
    return;
  }
  submitBtn.disabled = true;
  submitBtn.textContent = '⏳ Posting…';
  try {
    const result = await createListing({
      category_id, title, description, quantity_kg, servings,
      prepared_at: new Date(prepared_at).toISOString(),
      expires_at:  new Date(expires_at).toISOString(),
      is_veg: document.getElementById('isVegSelect').value === 'true',
      suitable_for_animals: document.getElementById('animalSelect').value === 'true',
      allergens: document.getElementById('allergensInput').value.trim() || null,
      pickup_instructions: document.getElementById('pickupInstInput').value.trim() || null,
    });
    showToast(result.matched_to ? `✅ Posted and matched to ${result.matched_to}` : '✅ Posted. Waiting for a nearby receiver.');
    form.reset();
    setDefaultTimes();
    freshnessPreview.style.display = 'none';
    await loadMyListings();
  } catch (err) {
    showToast(`❌ ${err.message}`, 'error');
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = '🚀 Post Listing';
  }
});
function listingStatus(l) {
  const who = escapeHTML(l.receiver_name || 'a receiver');
  if (l.status === 'available') return { pill: 'pending', text: 'Waiting for a match' };
  if (l.status === 'matched' && l.match_status === 'accepted') return { pill: 'accepted', text: `Accepted by ${who}` };
  if (l.status === 'matched') return { pill: 'pending', text: `Matched to ${who}, waiting for them to accept` };
  if (l.status === 'picked_up') return { pill: 'picked_up', text: `Picked up by ${who} ✓` };
  if (l.status === 'delivered') return { pill: 'completed', text: `Delivered by ${who} ✓` };
  if (l.status === 'expired') return { pill: 'rejected', text: 'Expired' };
  return { pill: 'cancelled', text: 'Cancelled' };
}
function showsCode(l) {
  return l.status === 'available' || l.status === 'matched';
}
function listingCardHTML(l) {
  const st = listingStatus(l);
  const active = showsCode(l);
  const hoursLeft = (new Date(l.effective_expiry) - Date.now()) / 36e5;
  const band = hoursLeft < 2 ? 'RED' : hoursLeft < 6 ? 'YELLOW' : 'GREEN';
  return `
    <div class="food-card ${active ? `band-${band}` : 'food-card-done'}">
      <div class="food-card-header">
        <span class="food-card-title">${escapeHTML(l.title)}</span>
        <span class="status-pill status-${st.pill}">${st.text}</span>
      </div>
      <div class="food-card-body">
        <div class="food-card-meta">
          <span>⚖️ ${l.quantity_kg} kg</span>
          <span>🏷️ ${escapeHTML(l.category)}</span>
          <span>🆔 #${l.listing_id}</span>
        </div>
        ${active ? `
          <div class="pickup-code-box">
            <span class="pickup-code-label">Pickup code</span>
            <span class="pickup-code">${escapeHTML(l.pickup_code)}</span>
          </div>
          <span class="countdown ${band}" data-expiry="${l.effective_expiry}">⏱ ${countdown(l.effective_expiry)}</span>` : ''}
      </div>
    </div>`;
}
function renderMyListings() {
  if (myListingData.length === 0) {
    myListings.innerHTML = '<div class="empty-state">You haven\'t posted any food yet. Your listings and pickup codes will appear here.</div>';
    return;
  }
  const order = l => (showsCode(l) ? 0 : 1);
  const sorted = [...myListingData].sort((a, b) => order(a) - order(b));
  myListings.innerHTML = sorted.slice(0, 12).map(listingCardHTML).join('');
}
async function loadMyListings() {
  try {
    myListingData = await getMyListings();
    renderMyListings();
  } catch (e) {
    showToast(e.message, 'error');
  }
}
setInterval(() => {
  document.querySelectorAll('#myListings [data-expiry]').forEach(el => {
    el.textContent = `⏱ ${countdown(el.dataset.expiry)}`;
  });
}, 1000);
async function start() {
  const session = await initPage({ roles: ['donor'] });
  if (session.redirected) return;
  me = session.me;
  const name = me.donor_name || me.full_name;
  donorSel.innerHTML = `<option value="${me.donor_id}">${escapeHTML(name)}</option>`;
  donorSel.disabled = true;
  setDefaultTimes();
  await loadCategories();
  await loadMyListings();
  setInterval(loadMyListings, 30000);
}
start();
