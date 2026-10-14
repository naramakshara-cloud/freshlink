const kpiDeliveries  = document.getElementById('kpiDeliveries');
const kpiKg          = document.getElementById('kpiKg');
const kpiRescueRate  = document.getElementById('kpiRescueRate');
const kpiExpired     = document.getElementById('kpiExpired');
const equivCO2       = document.getElementById('equivCO2');
const equivMeals     = document.getElementById('equivMeals');
const chartContainer = document.getElementById('chartContainer');
const impactBody     = document.getElementById('impactBody');
const hkBtn          = document.getElementById('hkBtn');
const resetBtn       = document.getElementById('resetBtn');
const hkResult       = document.getElementById('hkResult');
const TYPE_EMOJI = {
  other:      '📦',
  hostel:     '🏠',
  canteen:    '🍽️',
  household:  '👨‍👩‍👧',
  restaurant: '🍴',
  event:      '🎉',
};
async function loadImpact() {
  try {
    const data = await getImpact();
    renderKPIs(data.totals);
    renderEquivalents(data.totals);
    renderChart(data.by_donor_type);
    renderTable(data.by_donor_type);
  } catch (e) {
    showToast(e.message, 'error');
    impactBody.innerHTML = `<tr><td colspan="5" class="loading-row">❌ ${e.message}</td></tr>`;
  }
}
function renderKPIs(totals) {
  const deliveries = parseInt(totals.total_deliveries ?? 0);
  const kgSaved    = parseFloat(totals.total_kg_saved ?? 0);
  const expired    = parseInt(totals.total_expired    ?? 0);
  const total      = parseInt(totals.total_listings   ?? 0);
  const rate       = total > 0 ? ((deliveries / total) * 100).toFixed(1) : 0;
  animateCount(kpiDeliveries, deliveries);
  animateCount(kpiKg,         kgSaved, true);
  kpiRescueRate.textContent = `${rate}%`;
  animateCount(kpiExpired, expired);
}
function animateCount(el, target, isFloat = false) {
  const duration = 1000;
  const start    = performance.now();
  function step(now) {
    const t = Math.min((now - start) / duration, 1);
    const v = t * target;
    el.textContent = isFloat ? v.toFixed(1) : Math.round(v).toString();
    if (t < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}
function renderEquivalents(totals) {
  const kg = parseFloat(totals.total_kg_saved ?? 0);
  equivCO2.textContent   = (kg * 2.5).toFixed(1);
  equivMeals.textContent = Math.round(kg / 0.4).toLocaleString();
}
function renderChart(rows) {
  if (!rows || rows.length === 0) {
    chartContainer.innerHTML =
      '<p style="color:var(--gray-400);font-size:.9rem">No data yet — complete some deliveries!</p>';
    return;
  }
  chartContainer.innerHTML = rows.map(r => {
    const pct   = parseFloat(r.rescue_rate_pct ?? 0);
    const emoji = TYPE_EMOJI[r.donor_type] ?? '📦';
    const colour = pct >= 70 ? 'var(--green)' : pct >= 40 ? 'var(--yellow)' : 'var(--red)';
    return `
      <div class="bar-row">
        <span class="bar-label">${emoji} ${escapeHTML(r.donor_type)}</span>
        <div class="bar-track">
          <div class="bar-fill" style="width:${pct}%;background:${colour}"></div>
        </div>
        <span class="bar-pct">${pct ?? 0}%</span>
      </div>`;
  }).join('');
}
function renderTable(rows) {
  if (!rows || rows.length === 0) {
    impactBody.innerHTML = '<tr><td colspan="5" class="loading-row">No data yet</td></tr>';
    return;
  }
  impactBody.innerHTML = rows.map(r => {
    const rate  = parseFloat(r.rescue_rate_pct ?? 0);
    const band  = rate >= 70 ? 'GREEN' : rate >= 40 ? 'YELLOW' : 'RED';
    const emoji = TYPE_EMOJI[r.donor_type] ?? '📦';
    return `
      <tr>
        <td>${emoji} ${escapeHTML(r.donor_type)}</td>
        <td>${r.deliveries ?? 0}</td>
        <td><strong>${parseFloat(r.kg_saved ?? 0).toFixed(1)} kg</strong></td>
        <td>${r.expired ?? 0}</td>
        <td>${badgeHTML(band)} ${rate}%</td>
      </tr>`;
  }).join('');
}
hkBtn.addEventListener('click', async () => {
  hkBtn.disabled    = true;
  hkBtn.textContent = '⏳ Running…';
  try {
    const res = await expireStale();
    hkResult.textContent =
      `✅ ${res.expired_listings} listing(s) expired, ${res.cancelled_matches} match(es) cancelled`;
    await loadImpact();
  } catch (e) {
    hkResult.textContent = `❌ ${e.message}`;
  } finally {
    hkBtn.disabled    = false;
    hkBtn.textContent = '🧹 Expire Stale Listings';
  }
});
resetBtn.addEventListener('click', async () => {
  const confirmed = confirm(
    '⚠️ This will delete ALL data (matches, listings, etc.) and reload the sample data.\n\nAre you sure?'
  );
  if (!confirmed) return;
  resetBtn.disabled    = true;
  resetBtn.textContent = '⏳ Resetting…';
  hkResult.textContent = '';
  try {
    const res = await apiFetch('/admin/reset', { method: 'POST' });
    hkResult.textContent = `✅ ${res.message}`;
    showToast('🔄 Demo data reset — fresh start!');
    await loadImpact();
  } catch (e) {
    hkResult.textContent = `❌ ${e.message}`;
    showToast(e.message, 'error');
  } finally {
    resetBtn.disabled    = false;
    resetBtn.textContent = '🔄 Reset Demo Data';
  }
});
async function start() {
  const session = await initPage();
  if (session.me && session.me.role === 'admin') {
    document.getElementById('adminTools').style.display = '';
  }
  loadImpact();
}
start();
