const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Carregamento inicial: some quando a página carrega (no máximo 2,5 s)
// contador 0→100 que acompanha o carregamento; mínimo 1,6 s para a animação respirar
const ld = document.querySelector(".loader"), ldN = ld.querySelector(".loader__n");
let n = 0, loaded = false, t0 = performance.now();
const ready = () => document.body.classList.remove("is-loading");
addEventListener("load", () => (loaded = true));
setTimeout(() => (loaded = true), 3500);
(function tick() {
  const alvo = loaded && performance.now() - t0 > 1600 ? 100 : Math.min(90, (performance.now() - t0) / 20);
  n += (alvo - n) * 0.12;
  if (alvo === 100 && n > 99.5) n = 100;
  ldN.textContent = Math.round(n);
  ld.style.setProperty("--ld", n / 100);
  if (n < 100 && !reduce) requestAnimationFrame(tick); else setTimeout(ready, reduce ? 0 : 250);
})();

// Hero: a mídia sai da coluna e se estica até a borda conforme rola
const heroImg = document.querySelector(".hero__img");
const stretch = () => {
  const p = reduce ? 1 : Math.min(1, Math.max(0, 1 - heroImg.getBoundingClientRect().top / (innerHeight * 0.6)));
  heroImg.style.setProperty("--p", p.toFixed(3));
};
addEventListener("scroll", () => requestAnimationFrame(stretch), { passive: true });
stretch();

// Assinatura: o perfil aberto no acordeão troca a foto ao lado
const shots = $$(".how .shot");
$$(".acc details").forEach((d) => d.addEventListener("toggle", () => {
  if (d.open) shots.forEach((s) => s.classList.toggle("is-on", s.dataset.i === d.dataset.i));
}));

// Cobertura: mapa real (base clara da Esri, sem chave) com as rotas por rodovia do rotas.json
const rotas = JSON.parse(document.getElementById("rotas").textContent);
const tabs = $$(".map__tabs button");
const mapa = L.map("mapa", { zoomControl: false, scrollWheelZoom: false, dragging: !matchMedia("(pointer: coarse)").matches });
["Base", "Reference"].forEach((n) => L.tileLayer(`https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_${n}/MapServer/tile/{z}/{y}/{x}`, {
  attribution: n === "Base" ? "Tiles &copy; Esri &mdash; Esri, HERE, Garmin, &copy; OpenStreetMap" : "", maxZoom: 12,
}).addTo(mapa));
rotas.forEach((r) => L.polyline(r.line, { className: "map__ghost", weight: 2 }).addTo(mapa));
let linha, pontos = [];
const show = (i) => {
  const r = rotas[i].line;
  linha?.remove(); pontos.forEach((m) => m.remove());
  linha = L.polyline(r, { className: "map__route", weight: 4 }).addTo(mapa);
  pontos = [r[0], r.at(-1)].map((ll, k) => L.circleMarker(ll, { radius: 6, weight: 2, className: k ? "map__to" : "map__from" }).addTo(mapa));
  mapa.flyToBounds(linha.getBounds(), { padding: [56, 56], duration: reduce ? 0 : 0.8 });
  const el = linha.getElement();
  el.setAttribute("pathLength", 1); // comprimento normalizado: não quebra quando o zoom redesenha a linha
  el.style.strokeDasharray = 1; el.style.strokeDashoffset = reduce ? 0 : 1;
  requestAnimationFrame(() => requestAnimationFrame(() => (el.style.strokeDashoffset = 0)));
  tabs.forEach((t, k) => t.setAttribute("aria-pressed", k === i));
};
mapa.fitBounds(rotas.flatMap((x) => x.line), { padding: [40, 40] });
tabs.forEach((t) => t.addEventListener("click", () => show(+t.dataset.i)));
// só traça quando o mapa entra na tela
new IntersectionObserver((es, o) => { if (es[0].isIntersecting) { show(0); o.disconnect(); } }, { threshold: 0.3 }).observe(document.getElementById("mapa"));

// Entrada ao rolar
const io = new IntersectionObserver((es) => es.forEach((e) => {
  if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}), { rootMargin: "0px 0px -10% 0px" });
$$(".rise").forEach((el) => io.observe(el));

// Cabeçalho: esconde a faixa-piloto e ganha filete ao rolar
const header = document.querySelector(".top");
addEventListener("scroll", () => header.classList.toggle("is-scrolled", scrollY > 40), { passive: true });

// Formulário (web3forms) sem sair da página
const form = document.querySelector(".form");
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = form.querySelector(".form__msg"), bt = form.querySelector("button");
  bt.disabled = true;
  try {
    const r = await fetch(form.action, { method: "POST", headers: { Accept: "application/json" }, body: new FormData(form) });
    if (!(await r.json()).success) throw 0;
    msg.textContent = form.dataset.ok;
    form.reset();
  } catch {
    msg.textContent = form.dataset.err;
  }
  bt.disabled = false;
});
