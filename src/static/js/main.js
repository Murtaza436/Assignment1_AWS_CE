/* ── UniEvent · main.js ──────────────────────────────────────────── */

document.addEventListener("DOMContentLoaded", () => {
  updateApiBadge(true);
  initUpload();
  initDragDrop();
});

/* ── Event Refresh ──────────────────────────────────────────────── */
async function refreshEvents() {
  const grid  = document.getElementById("events-grid");
  const badge = document.getElementById("api-badge");

  badge.innerHTML = '<span class="spinner"></span> Fetching…';
  badge.style.color = "var(--accent)";

  try {
    const res  = await fetch("/api/events");
    const data = await res.json();

    if (data.status === "success") {
      renderEvents(data.events, grid);
      badge.textContent = `✅ ${data.count} events fetched from Ticketmaster API`;
      badge.style.color = "var(--green)";
      document.getElementById("stat-count").textContent = data.count;
    } else {
      badge.textContent = "⚠️ Using S3-cached events";
      badge.style.color = "var(--accent2)";
    }
  } catch (err) {
    badge.textContent = "❌ API unavailable — showing cached events";
    badge.style.color = "#fc8181";
    console.error("Refresh error:", err);
  }
}

function renderEvents(events, container) {
  container.innerHTML = events.map((ev, i) => `
    <article class="event-card" style="--i:${i}">
      <div class="card-image">
        <img src="${ev.image_url}" alt="${escHtml(ev.title)}"
             onerror="this.src='/static/images/default_event.png'" />
        <span class="category-tag">${escHtml(ev.category)}</span>
      </div>
      <div class="card-body">
        <time>📅 ${ev.date}${ev.time !== "TBA" ? " · " + ev.time.slice(0,5) : ""}</time>
        <h3>${escHtml(ev.title)}</h3>
        <p class="venue">📍 ${escHtml(ev.venue)}${ev.city ? ", " + escHtml(ev.city) : ""}</p>
        <p class="desc">${escHtml(ev.description.slice(0, 140))}${ev.description.length > 140 ? "…" : ""}</p>
        <a href="${ev.ticket_url}" class="btn-card" target="_blank">View Details →</a>
      </div>
    </article>
  `).join("");
}

function updateApiBadge(initial = false) {
  const badge = document.getElementById("api-badge");
  if (initial) {
    badge.textContent = "✅ Events loaded from Ticketmaster API (S3-cached fallback enabled)";
    badge.style.color = "var(--green)";
  }
}

/* ── File Upload ─────────────────────────────────────────────────── */
function initUpload() {
  const input  = document.getElementById("file-input");
  const result = document.getElementById("upload-result");

  input.addEventListener("change", () => {
    if (input.files.length > 0) uploadFile(input.files[0], result);
  });
}

async function uploadFile(file, resultEl) {
  if (!file.type.startsWith("image/")) {
    showResult(resultEl, "error", "❌ Only image files are supported.");
    return;
  }
  if (file.size > 10 * 1024 * 1024) {
    showResult(resultEl, "error", "❌ File exceeds 10 MB limit.");
    return;
  }

  showResult(resultEl, "", '<span class="spinner"></span> Uploading to S3…');
  resultEl.classList.remove("hidden", "success", "error");

  const formData = new FormData();
  formData.append("file", file);

  try {
    const res  = await fetch("/api/upload", { method: "POST", body: formData });
    const data = await res.json();

    if (data.status === "success") {
      showResult(resultEl, "success",
        `✅ Uploaded successfully!<br/><small style="word-break:break-all">${data.url}</small>`);
    } else {
      showResult(resultEl, "error", "❌ Upload failed. Check S3 configuration.");
    }
  } catch (err) {
    showResult(resultEl, "error", "❌ Network error during upload.");
    console.error(err);
  }
}

function showResult(el, type, html) {
  el.classList.remove("hidden", "success", "error");
  if (type) el.classList.add(type);
  el.innerHTML = html;
}

/* ── Drag & Drop ─────────────────────────────────────────────────── */
function initDragDrop() {
  const zone   = document.getElementById("upload-zone");
  const result = document.getElementById("upload-result");
  const input  = document.getElementById("file-input");

  zone.addEventListener("dragover", e => {
    e.preventDefault();
    zone.style.borderColor = "var(--accent)";
  });

  zone.addEventListener("dragleave", () => {
    zone.style.borderColor = "";
  });

  zone.addEventListener("drop", e => {
    e.preventDefault();
    zone.style.borderColor = "";
    const file = e.dataTransfer.files[0];
    if (file) {
      input.files = e.dataTransfer.files;
      uploadFile(file, result);
    }
  });
}

/* ── Utility ─────────────────────────────────────────────────────── */
function escHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}
