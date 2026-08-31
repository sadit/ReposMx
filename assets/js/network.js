/* ReposMx — grafo de coautoría/citas con D3 (force layout, drag, zoom) */

let networkSimulation = null;
let networkResizeHandler = null;

async function loadNetworkView(query) {
  const wrap = document.getElementById('network-svg-wrap');
  wrap.innerHTML = '<div class="empty-state">Cargando red...</div>';

  const data = await API.get('search', `/api/authors/network?q=${encodeURIComponent(query)}`);
  if (!data) return;
  if (data.error) {
    wrap.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }
  if (!data.nodes || data.nodes.length <= 1) {
    wrap.innerHTML = '<div class="empty-state">No se encontró red de coautoría/citas para este autor.</div>';
    return;
  }
  renderNetwork(wrap, data);
}

function renderNetwork(wrap, graph) {
  if (networkSimulation) networkSimulation.stop();
  if (networkResizeHandler) window.removeEventListener('resize', networkResizeHandler);
  wrap.innerHTML = '';

  const width = wrap.clientWidth || 800;
  const height = wrap.clientHeight || 520;

  const style = getComputedStyle(document.documentElement);
  const colorTarget = style.getPropertyValue('--accent').trim();
  const colorCoauthor = style.getPropertyValue('--chart-3').trim();
  const colorCiter = style.getPropertyValue('--chart-2').trim();
  const gridColor = style.getPropertyValue('--gridline').trim();

  const nodeColor = (d) => d.kind === 'target' ? colorTarget : (d.kind === 'coauthor' ? colorCoauthor : colorCiter);

  const svg = d3.select(wrap).append('svg').attr('viewBox', [0, 0, width, height]);
  const g = svg.append('g');

  svg.call(d3.zoom().scaleExtent([0.3, 4]).on('zoom', (event) => {
    g.attr('transform', event.transform);
  }));

  const nodes = graph.nodes.map(d => ({ ...d }));
  const edges = graph.edges.map(d => ({ ...d }));

  const simulation = d3.forceSimulation(nodes)
    .force('link', d3.forceLink(edges).id(d => d.id).distance(d => 100 - Math.min(d.weight || 1, 8) * 6).strength(0.5))
    .force('charge', d3.forceManyBody().strength(-220))
    .force('center', d3.forceCenter(width / 2, height / 2))
    .force('collide', d3.forceCollide(28));

  const link = g.append('g')
    .selectAll('line')
    .data(edges)
    .join('line')
    .attr('stroke', d => d.kind === 'coauthor' ? colorCoauthor : colorCiter)
    .attr('stroke-width', d => Math.min(1 + Math.log2((d.weight || 1) + 1), 6))
    .attr('stroke-opacity', 0.55);

  const node = g.append('g')
    .selectAll('circle')
    .data(nodes)
    .join('circle')
    .attr('r', d => d.kind === 'target' ? 14 : 9)
    .attr('fill', nodeColor)
    .attr('stroke', gridColor)
    .attr('stroke-width', 1.5)
    .style('cursor', 'pointer')
    .call(d3.drag()
      .on('start', (event, d) => {
        if (!event.active) simulation.alphaTarget(0.3).restart();
        d.fx = d.x; d.fy = d.y;
      })
      .on('drag', (event, d) => { d.fx = event.x; d.fy = event.y; })
      .on('end', (event, d) => {
        if (!event.active) simulation.alphaTarget(0);
        d.fx = null; d.fy = null;
      }))
    .on('click', (event, d) => {
      if (d.kind !== 'target') {
        document.getElementById('query-input').value = d.name;
        loadNetworkView(d.name);
        syncURLState();
      }
    })
    .on('mouseenter', (event, d) => showChartTooltip(event, d.name + (d.kind === 'target' ? ' (consultado)' : '')))
    .on('mousemove', moveChartTooltip)
    .on('mouseleave', hideChartTooltip);

  const label = g.append('g')
    .selectAll('text')
    .data(nodes)
    .join('text')
    .attr('class', 'network-node-label')
    .attr('dx', 14)
    .attr('dy', 4)
    .text(d => d.name);

  simulation.on('tick', () => {
    link
      .attr('x1', d => d.source.x)
      .attr('y1', d => d.source.y)
      .attr('x2', d => d.target.x)
      .attr('y2', d => d.target.y);
    node
      .attr('cx', d => d.x)
      .attr('cy', d => d.y);
    label
      .attr('x', d => d.x)
      .attr('y', d => d.y);
  });

  networkSimulation = simulation;

  networkResizeHandler = debounce(() => {
    if (!wrap.isConnected) return;
    const w = wrap.clientWidth || width;
    const h = wrap.clientHeight || height;
    svg.attr('viewBox', [0, 0, w, h]);
    simulation.force('center', d3.forceCenter(w / 2, h / 2));
    simulation.alpha(0.3).restart();
  }, 300);
  window.addEventListener('resize', networkResizeHandler);
}
