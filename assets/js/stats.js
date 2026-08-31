/* ReposMx — pestaña de Estadísticas (/api/info): tablas + gráficas SVG/HTML a mano */

function chartTooltipEl() {
  return document.getElementById('chart-tooltip');
}

function showChartTooltip(evt, text) {
  const tip = chartTooltipEl();
  tip.textContent = text;
  tip.style.left = (evt.clientX + 12) + 'px';
  tip.style.top = (evt.clientY + 12) + 'px';
  tip.classList.add('visible');
}

function moveChartTooltip(evt) {
  const tip = chartTooltipEl();
  tip.style.left = (evt.clientX + 12) + 'px';
  tip.style.top = (evt.clientY + 12) + 'px';
}

function hideChartTooltip() {
  chartTooltipEl().classList.remove('visible');
}

/* Gráfica de barras horizontales (una sola serie -> un solo color, sin leyenda) */
function renderBarChart(container, items, opts) {
  const { labelKey, valueKey, colorVar, maxBars = 12 } = opts;
  const data = (items || []).slice(0, maxBars);
  if (data.length === 0) {
    container.innerHTML = '<div class="chart-empty">Sin datos suficientes.</div>';
    return;
  }
  const maxVal = Math.max(...data.map(d => d[valueKey])) || 1;
  const color = getComputedStyle(document.documentElement).getPropertyValue(colorVar).trim() || '#2a78d6';

  container.innerHTML = data.map(d => {
    const pct = Math.max((d[valueKey] / maxVal) * 100, 2);
    const label = String(d[labelKey]);
    const safeLabel = label.replace(/"/g, '&quot;');
    return `
      <div class="chart-row" data-label="${safeLabel}" data-value="${d[valueKey]}">
        <div class="chart-row-label" title="${safeLabel}">${label}</div>
        <div class="chart-row-track">
          <div class="chart-row-bar" style="width:${pct}%; background:${color};"></div>
        </div>
        <div class="chart-row-value">${d[valueKey].toLocaleString()}</div>
      </div>
    `;
  }).join('');

  container.querySelectorAll('.chart-row').forEach(row => {
    row.addEventListener('mouseenter', e => showChartTooltip(e, `${row.dataset.label}: ${Number(row.dataset.value).toLocaleString()}`));
    row.addEventListener('mousemove', moveChartTooltip);
    row.addEventListener('mouseleave', hideChartTooltip);
  });
}

/* Histograma/línea de tiempo por año (barras verticales) */
function renderTimeline(container, histogram) {
  if (!histogram || histogram.length === 0) {
    container.innerHTML = '<div class="chart-empty">Sin datos suficientes.</div>';
    return;
  }
  const maxCount = Math.max(...histogram.map(([, c]) => c)) || 1;
  const color = getComputedStyle(document.documentElement).getPropertyValue('--chart-3').trim() || '#1baf7a';
  const n = histogram.length;
  const labelStride = Math.max(1, Math.ceil(n / 15));

  container.innerHTML = histogram.map(([year, count], i) => {
    const pct = Math.max((count / maxCount) * 100, 2);
    const showLabel = (i % labelStride === 0) || i === n - 1;
    return `
      <div class="timeline-col" data-year="${year}" data-count="${count}">
        <div class="timeline-bar" style="height:${pct}%; background:${color};"></div>
        ${showLabel ? `<span class="timeline-year-label">${year}</span>` : ''}
      </div>
    `;
  }).join('');

  container.querySelectorAll('.timeline-col').forEach(col => {
    col.addEventListener('mouseenter', e => showChartTooltip(e, `${col.dataset.year}: ${Number(col.dataset.count).toLocaleString()} documentos`));
    col.addEventListener('mousemove', moveChartTooltip);
    col.addEventListener('mouseleave', hideChartTooltip);
  });

  container.scrollLeft = container.scrollWidth;
}

async function loadInfoView(repo) {
  const container = document.getElementById('info-content');
  showSkeleton(container, 4);

  const url = repo ? `/api/info?repo=${encodeURIComponent(repo)}` : '/api/info';
  const data = await API.get('info', url);
  if (!data) { container.innerHTML = '<div class="empty-state">Error al cargar estadísticas.</div>'; return; }
  if (data.error) { container.innerHTML = `<div class="empty-state">${data.error}</div>`; return; }

  container.innerHTML = `
    <div class="dashboard-grid">
      <div class="metric-card">
        <div class="metric-title">Publicaciones Indexadas</div>
        <div class="metric-value">${data.total_docs.toLocaleString()}</div>
        <div class="metric-sub">Rango: ${data.year_min || 'N/A'} — ${data.year_max || 'N/A'}</div>
      </div>
      <div class="metric-card">
        <div class="metric-title">Archivos PDFs</div>
        <div class="metric-value" style="color:var(--green);">${data.total_files.toLocaleString()}</div>
        <div class="metric-sub">${((data.total_files / data.total_docs) * 100).toFixed(1)}% de cobertura</div>
      </div>
      <div class="metric-card">
        <div class="metric-title">Texto Completo Extraído</div>
        <div class="metric-value" style="color:var(--amber);">${data.total_fulltext.toLocaleString()}</div>
        <div class="metric-sub">${((data.total_fulltext / data.total_docs) * 100).toFixed(1)}% de manuscritos</div>
      </div>
      <div class="metric-card">
        <div class="metric-title">Citas Bibliográficas</div>
        <div class="metric-value" style="color:var(--purple);">${data.total_references.toLocaleString()}</div>
        <div class="metric-sub">${(data.total_references / data.total_docs).toFixed(1)} citas por documento</div>
      </div>
    </div>

    <div class="stats-grid-2col" style="margin-bottom:1.5rem;">
      <div class="table-container">
        <div class="table-header">📚 Tipos de Publicación</div>
        <div id="chart-types"></div>
      </div>
      <div class="table-container">
        <div class="table-header">🏷️ Disciplinas y Áreas de Conocimiento</div>
        <div id="chart-disciplines"></div>
      </div>
    </div>

    <div class="table-container" style="margin-bottom:1.5rem;">
      <div class="table-header">📈 Publicaciones por Año</div>
      <div id="chart-years" class="timeline-chart"></div>
    </div>

    <div class="stats-grid-2col">
      <div class="table-container">
        <div class="table-header">📚 Tipos de Publicación (detalle)</div>
        <table class="data-table">
          <thead><tr><th>Tipo</th><th>Total</th></tr></thead>
          <tbody>
            ${(data.types_distribution || []).map(pt => `
              <tr><td>${pt.type}</td><td><strong>${pt.count.toLocaleString()}</strong></td></tr>
            `).join('')}
          </tbody>
        </table>
      </div>
      <div class="table-container">
        <div class="table-header">🏷️ Disciplinas (detalle)</div>
        <table class="data-table">
          <thead><tr><th>Disciplina</th><th>Obras</th></tr></thead>
          <tbody>
            ${(data.top_disciplines || []).slice(0, 10).map(td => `
              <tr><td>${td.discipline}</td><td><strong>${td.count.toLocaleString()}</strong></td></tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    </div>

    <div class="table-container" style="margin-top:1.5rem;">
      <div class="table-header">👤 Investigadores y Asesores Principales</div>
      <table class="data-table">
        <thead><tr><th>Investigador</th><th>Rol</th><th>Repositorio</th><th>Publicaciones</th></tr></thead>
        <tbody>
          ${(data.top_researchers || []).slice(0, 15).map(r => `
            <tr>
              <td><strong>${r.name}</strong></td>
              <td><span class="card-repo" style="font-size:0.7rem;">${r.role}</span></td>
              <td>${r.repo}</td>
              <td><strong>${r.count}</strong></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;

  renderBarChart(document.getElementById('chart-types'), data.types_distribution, { labelKey: 'type', valueKey: 'count', colorVar: '--chart-1' });
  renderBarChart(document.getElementById('chart-disciplines'), data.top_disciplines, { labelKey: 'discipline', valueKey: 'count', colorVar: '--chart-2' });
  renderTimeline(document.getElementById('chart-years'), data.years_histogram);
}
