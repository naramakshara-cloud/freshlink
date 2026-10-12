/* ─────────────────────────────────────────────────────────
   donor.js – Post surplus food page logic
   ───────────────────────────────────────────────────────── */

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
const myListingsCard   = document.getElementById('myListingsCard');
const myListings       = document.getElementById('myListings');

// Session: track listings posted this session
let sessionListings = [];
// Categories with decay rates (for live preview)
let categoryData = [];

/* ── Seed defaults ─────────────────────────────────────── */
function setDefaultTimes() {
  const now = new Date();
  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
  prepInput.value = local(now);
  const exp = new Date(now.getTime() + 6 * 36e5);
  expInput.value = local(exp);
}

/* ── Load dropdowns ────────────────────────────────────── */
async function loadDropdowns() {
  try {
    const [donors, categories] = await Promise.all([getDonors(), getCategories()]);

    donorSel.innerHTML = '<option value="">— Select donor —</option>' +
      donors.map(d => `<option value="${d.donor_id}">${d.name} (${d.donor_type})</option>`).join('');

    categoryData = categories;
    categorySel.innerHTML = '<option value="">— Select category —</option>' +
      categories.map(c =>
        `<option value="${c.category_id}" data-refrig="${c.requires_refrigeration}">
          ${c.name}${c.requires_refrigeration ? ' ❄️' : ''}
        </option>`
      ).join('');
  } catch (e) {
    showToast(e.message, 'error');
  }
}

/* ── Live freshness preview ────────────────────────────── */
function updateFreshnessPreview() {
  const catId = parseInt(categorySel.value);
  const cat   = categoryData.find(c => c.category_id === catId);
  const prep  = prepInput.value;
  if (!cat || !prep) { freshnessPreview.style.display = 'none'; return; }

  // The decay_rate isn't returned from /categories — estimate from the known seeded values.
  // We'll use a rough client-side preview. The server enforces the real value.
  // For the demo we embed the typical decay rates:
  const DECAY = { 1: 0.15, 2: 0.08, 3: 0.12, 4: 0.03, 5: 0.005 };
  const k = DECAY[catId] ?? 0.1;
  const score = clientFreshness(new Date(prep), k);
  const band  = bandFromScore(score);

  freshnessPreview.style.display = 'flex';
  previewBadge.className = `badge badge-${band}`;
  previewBadge.textContent = band;
  previewScore.textContent = `${score}/100`;
}

categorySel.addEventListener('change', updateFreshnessPreview);
prepInput.addEventListener('input', updateFreshnessPreview);

/* ── Submit form ───────────────────────────────────────── */
form.addEventListener('submit', async (e) => {
  e.preventDefault();

  const donor_id    = parseInt(donorSel.value);
  const category_id = parseInt(categorySel.value);
  const title       = titleInput.value.trim();
  const quantity_kg = parseFloat(qtyInput.value);
  const servings    = parseInt(servInput.value) || null;
  const prepared_at = prepInput.value;
  const expires_at  = expInput.value;
  const description = descInput.value.trim() || null;

  if (!donor_id || !category_id || !title || !quantity_kg || !prepared_at || !expires_at) {
    showToast('Please fill in all required fields.', 'error');
    return;
  }

  if (new Date(expires_at) <= new Date(prepared_at)) {
    showToast('Expiry must be after preparation time.', 'error');
    return;
  }

  const is_veg               = document.getElementById('isVegSelect').value === 'true';
  const suitable_for_animals = document.getElementById('animalSelect').value === 'true';
  const allergens            = document.getElementById('allergensInput').value.trim() || null;
  const pickup_instructions  = document.getElementById('pickupInstInput').value.trim() || null;

  submitBtn.disabled = true;
  submitBtn.textContent = '⏳ Posting…';

  try {
    const result = await createListing({
      donor_id, category_id, title, description,
      quantity_kg, servings,
      prepared_at: new Date(prepared_at).toISOString(),
      expires_at:  new Date(expires_at).toISOString(),
      is_veg,
      suitable_for_animals,
      allergens,
      pickup_instructions
    });

    showToast(`✅ Listing #${result.listing_id} posted (Pickup Code: ${result.pickup_code || 'Generated'})!`);
    form.reset();
    setDefaultTimes();
    freshnessPreview.style.display = 'none';

    sessionListings.unshift({
      id: result.listing_id,
      title,
      quantity_kg,
      prepared_at,
      expires_at,
      pickup_code: result.pickup_code
    });
    renderSessionListings();
  } catch (err) {
    showToast(`❌ ${err.message}`, 'error');
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = '🚀 Post Listing';
  }
});

/* ── Recent listings ───────────────────────────────────── */
function renderSessionListings() {
  if (sessionListings.length === 0) { myListingsCard.style.display = 'none'; return; }
  myListingsCard.style.display = 'block';

  myListings.innerHTML = sessionListings.slice(0, 6).map(l => {
    const hoursLeft = ((new Date(l.expires_at) - Date.now()) / 36e5).toFixed(1);
    const band = hoursLeft < 2 ? 'RED' : hoursLeft < 6 ? 'YELLOW' : 'GREEN';
    return `
      <div class="food-card band-${band}">
        <div class="food-card-header">
          <span class="food-card-title">${l.title}</span>
          ${badgeHTML(band)}
        </div>
        <div class="food-card-body">
          <div class="food-card-meta">
            <span>⚖️ ${l.quantity_kg} kg</span>
            <span>🆔 Listing #${l.id}</span>
          </div>
          <span class="countdown ${band}" id="cd-${l.id}">
            ⏱ ${countdown(l.expires_at)}
          </span>
        </div>
      </div>`;
  }).join('');
}

// Tick countdowns every second
setInterval(() => {
  sessionListings.forEach(l => {
    const el = document.getElementById(`cd-${l.id}`);
    if (el) el.textContent = `⏱ ${countdown(l.expires_at)}`;
  });
}, 1000);

/* ── Init ──────────────────────────────────────────────── */
setDefaultTimes();
loadDropdowns();
