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
    ? '<tr><td colspan="6" class="loading-row">No one is waiting. New receivers will appear here after they sign up.</td></tr>'
    : pending.map(r => `
      <tr>
        <td><strong>${escapeHTML(r.name)}</strong></td>
        <td>${typeLabel(r.receiver_type)}</td>
        <td>${escapeHTML(r.address)}</td>
        <td>${r.daily_capacity_kg} kg</td>
        <td>${r.has_refrigeration ? 'Yes' : 'No'}</td>
        <td>${actionButtons(r)}</td>
      </tr>`).join('');
  allBody.innerHTML = receivers.map(r => `
    <tr>
      <td>${escapeHTML(r.name)}</td>
      <td>${typeLabel(r.receiver_type)}</td>
      <td><span class="status-pill status-${STATUS_PILL[r.verification_status] || 'cancelled'}">${escapeHTML(r.verification_status)}</span></td>
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
async function start() {
  const session = await initPage({ roles: ['admin'] });
  if (session.redirected) return;
  load();
}
start();
