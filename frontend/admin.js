const pendingBody = document.getElementById('pendingBody');
const allBody = document.getElementById('allBody');
const STATUS_PILL = { approved: 'accepted', pending: 'pending', rejected: 'rejected' };
function typeLabel(t) {
  return escapeHTML((t || '').replace(/_/g, ' '));
}
function actionButtons(r) {
  const approve = r.verification_status !== 'approved'
    ? `<button class="btn btn-accept" data-id="${r.receiver_id}" data-status="approved">Approve</button>` : '';
  const reject = r.verification_status !== 'rejected'
    ? `<button class="btn btn-reject" data-id="${r.receiver_id}" data-status="rejected">Reject</button>` : '';
  return `<div class="admin-actions">${approve}${reject}</div>`;
}
function render(receivers) {
  const pending = receivers.filter(r => r.verification_status === 'pending');
  pendingBody.innerHTML = pending.length === 0
    ? '<tr><td colspan="7" class="loading-row">No one is waiting. New receivers will appear here after they sign up.</td></tr>'
    : pending.map(r => `
      <tr>
        <td><strong>${escapeHTML(r.name)}</strong></td>
        <td>${typeLabel(r.receiver_type)}</td>
        <td>${escapeHTML(r.address)}</td>
        <td>${parseFloat(r.service_radius_km)} km</td>
        <td>${r.daily_capacity_kg} kg</td>
        <td>${r.has_refrigeration ? 'Yes' : 'No'}</td>
        <td>${actionButtons(r)}</td>
      </tr>`).join('');
  allBody.innerHTML = receivers.map(r => `
    <tr>
      <td>${escapeHTML(r.name)}</td>
      <td>${typeLabel(r.receiver_type)}</td>
      <td><span class="status-pill status-${STATUS_PILL[r.verification_status] || 'cancelled'}">${escapeHTML(r.verification_status)}</span></td>
      <td>${parseFloat(r.service_radius_km)} km</td>
      <td>${r.daily_capacity_kg} kg</td>
      <td>${r.has_refrigeration ? 'Yes' : 'No'}</td>
      <td>${actionButtons(r)}</td>
    </tr>`).join('');
  document.querySelectorAll('[data-status]').forEach(btn =>
    btn.addEventListener('click', () => changeStatus(btn))
  );
}
async function changeStatus(btn) {
  btn.disabled = true;
  try {
    await setReceiverStatus(btn.dataset.id, btn.dataset.status);
    showToast(btn.dataset.status === 'approved' ? '✅ Receiver approved' : 'Receiver rejected');
    await load();
  } catch (e) {
    showToast(e.message, 'error');
    btn.disabled = false;
  }
}
async function load() {
  try {
    render(await getNGOs());
  } catch (e) {
    showToast(e.message, 'error');
  }
}
const categoriesBody = document.getElementById('categoriesBody');
const categoryForm = document.getElementById('categoryForm');
const catName = document.getElementById('catName');
const catHours = document.getElementById('catHours');
const catDescription = document.getElementById('catDescription');
const catFridge = document.getElementById('catFridge');
const catSaveBtn = document.getElementById('catSaveBtn');
const addCategoryBtn = document.getElementById('addCategoryBtn');
let categories = [];
let editingId = null;
function formatHours(h) {
  const n = parseFloat(h);
  if (n >= 48 && n % 24 === 0) return `${n / 24} days`;
  return `${n} h`;
}
function renderCategories() {
  categoriesBody.innerHTML = categories.map(c => `
    <tr class="${c.is_active ? '' : 'row-muted'}">
      <td><strong>${escapeHTML(c.name)}</strong></td>
      <td class="cell-wrap">${escapeHTML(c.description || '—')}</td>
      <td>${formatHours(c.max_safe_hours)}</td>
      <td>${c.requires_refrigeration ? 'Yes' : 'No'}</td>
      <td><span class="status-pill status-${c.is_active ? 'accepted' : 'cancelled'}">${c.is_active ? 'Shown' : 'Hidden'}</span></td>
      <td>${c.listing_count}</td>
      <td>
        <div class="admin-actions">
          <button class="btn btn-secondary" data-edit="${c.category_id}">Edit</button>
          <button class="btn ${c.is_active ? 'btn-reject' : 'btn-accept'}" data-toggle="${c.category_id}">${c.is_active ? 'Hide' : 'Show'}</button>
        </div>
      </td>
    </tr>`).join('');
  categoriesBody.querySelectorAll('[data-edit]').forEach(b => b.addEventListener('click', () => openForm(parseInt(b.dataset.edit))));
  categoriesBody.querySelectorAll('[data-toggle]').forEach(b => b.addEventListener('click', () => toggleCategory(b)));
}
function openForm(id = null) {
  editingId = id;
  const c = categories.find(x => x.category_id === id);
  document.getElementById('categoryFormTitle').textContent = c ? `Edit ${c.name}` : 'Add food type';
  catSaveBtn.textContent = c ? 'Save changes' : 'Add food type';
  catName.value = c ? c.name : '';
  catHours.value = c ? parseFloat(c.max_safe_hours) : '';
  catDescription.value = c ? (c.description || '') : '';
  catFridge.value = c && c.requires_refrigeration ? 'true' : 'false';
  categoryForm.hidden = false;
  addCategoryBtn.hidden = true;
  catName.focus();
}
function closeForm() {
  categoryForm.hidden = true;
  addCategoryBtn.hidden = false;
  editingId = null;
}
async function loadCategories() {
  try {
    categories = await getAdminCategories();
    renderCategories();
  } catch (e) {
    showToast(e.message, 'error');
  }
}
async function toggleCategory(btn) {
  const id = parseInt(btn.dataset.toggle);
  const c = categories.find(x => x.category_id === id);
  if (c.is_active && !confirm(`Hide "${c.name}"? Donors won't be able to pick it. Food already posted is not affected.`)) return;
  btn.disabled = true;
  try {
    await updateCategory(id, { is_active: !c.is_active });
    showToast(c.is_active ? `${c.name} hidden` : `${c.name} shown`);
    await loadCategories();
  } catch (e) {
    showToast(e.message, 'error');
    btn.disabled = false;
  }
}
categoryForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const data = {
    name: catName.value.trim(),
    description: catDescription.value.trim(),
    max_safe_hours: parseFloat(catHours.value),
    requires_refrigeration: catFridge.value === 'true',
  };
  if (!data.name || !data.max_safe_hours) {
    showToast('Fill in the name and how many hours the food stays safe.', 'error');
    return;
  }
  catSaveBtn.disabled = true;
  try {
    if (editingId) {
      await updateCategory(editingId, data);
      showToast(`${data.name} updated`);
    } else {
      await createCategory(data);
      showToast(`${data.name} added`);
    }
    closeForm();
    await loadCategories();
  } catch (err) {
    showToast(err.message, 'error');
  } finally {
    catSaveBtn.disabled = false;
  }
});
addCategoryBtn.addEventListener('click', () => openForm());
document.getElementById('catCancelBtn').addEventListener('click', closeForm);
async function start() {
  const session = await initPage({ roles: ['admin'] });
  if (session.redirected) return;
  load();
  loadCategories();
}
start();
