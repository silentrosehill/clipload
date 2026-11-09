// ==UserScript==
// @name         Stream Grabber
// @description  Spots the HLS/DASH stream (or direct file) a video player loads and sends it to Clipload for download. Hover a video and click the ⬇ button; Shift-click for audio only.
// @version      1.0.0
// @match        *://*/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

(() => {
  "use strict";

  // Must match Clipload's token (defaults read local.clipload token). With a wrong token
  // Clipload still works, it just asks for confirmation first.
  const TOKEN = "PASTE-YOUR-CLIPLOAD-TOKEN-HERE";

  // ---------- spotting stream manifests the page loads ----------

  const streams = []; // in the order the page requested them

  function isManifest(u) {
    return /\.(m3u8|mpd)(\?|#|$)/i.test(u) ||
      /[?&](format|type|ext)=(m3u8|hls|dash|mpd)\b/i.test(u) ||
      /\/manifest\(format=(m3u8|mpd)/i.test(u);
  }

  function note(raw) {
    let u;
    try { u = new URL(raw, location.href).href; } catch { return; }
    if (!/^https?:/i.test(u) || !isManifest(u) || streams.includes(u)) return;
    streams.push(u);
  }

  // Resource Timing lists every request the page made (fetch, XHR, media), even
  // cross-origin ones, so we don't need to hook the player's network code.
  try {
    new PerformanceObserver(list => list.getEntries().forEach(e => note(e.name)))
      .observe({ type: "resource", buffered: true });
  } catch {
    setInterval(() => performance.getEntriesByType("resource").forEach(e => note(e.name)), 2000);
  }

  // A master playlist lists every quality; variant playlists only one. Prefer the master.
  function bestStream() {
    if (!streams.length) return null;
    const master = streams.find(u => /master|playlist|manifest|index\.m3u8/i.test(u) && !/chunklist/i.test(u));
    return master || streams[0];
  }

  // What to send for a given <video>: a direct file/stream URL if the element has one,
  // otherwise the manifest we saw, otherwise the page itself (yt-dlp may know the site).
  function mediaFor(v) {
    const src = v.currentSrc || v.src || "";
    if (/^https?:/i.test(src)) return { url: src, kind: isManifest(src) ? "stream" : "file" };
    const s = bestStream();
    if (s) return { url: s, kind: "stream" };
    return { url: location.href, kind: "page" };
  }

  function pageTitle() {
    const og = document.querySelector('meta[property="og:title"]')?.content;
    return (og || document.title || location.hostname).trim();
  }

  function send(media, audio) {
    const params = { url: media.url, referer: location.href, title: pageTitle(), token: TOKEN };
    if (audio) params.audio = "1";
    const query = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    const a = document.createElement("a");
    a.href = `clipload://download?${query}`;
    a.style.display = "none";
    document.documentElement.appendChild(a);
    a.click();
    a.remove();
  }

  // ---------- hover button (sits left of PiP Anywhere's button) ----------

  function start() {
    let cache = [], cacheTime = 0;
    const collect = (root, out) => {
      root.querySelectorAll("video").forEach(v => out.push(v));
      root.querySelectorAll("*").forEach(el => el.shadowRoot && collect(el.shadowRoot, out));
      return out;
    };
    const videos = () => {
      if (Date.now() - cacheTime > 1000) { cache = collect(document, []); cacheTime = Date.now(); }
      return cache;
    };

    const host = document.createElement("div");
    host.style.cssText = "all:initial;position:fixed;z-index:2147483647;top:0;left:0;display:none;";
    const shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `
      <style>
        button {
          all: initial; box-sizing: border-box; cursor: pointer;
          height: 28px; padding: 0 8px; border-radius: 7px; gap: 4px;
          display: flex; align-items: center; justify-content: center;
          font: 600 11px -apple-system, system-ui, sans-serif;
          background: rgba(20,20,20,.72); color: #fff;
          backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
          box-shadow: 0 1px 4px rgba(0,0,0,.4);
          opacity: .85; transition: opacity .15s, background .15s;
        }
        button:hover { opacity: 1; background: rgba(0,0,0,.9); }
        button.sent { background: rgba(30,140,70,.9); }
        svg { width: 16px; height: 16px; flex: none; }
      </style>
      <button>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 4v11m0 0l-4.5-4.5M12 15l4.5-4.5M5 19.5h14"/>
        </svg>
        <span></span>
      </button>`;
    const button = shadow.querySelector("button");
    const label = shadow.querySelector("span");

    let target = null, hideTimer = null;
    const WIDTH = 72; // approx; label is short

    function refreshLabel() {
      const kind = target ? mediaFor(target).kind : "page";
      label.textContent = kind === "stream" ? "Stream" : kind === "file" ? "Video" : "Page";
      button.title = kind === "page"
        ? "No stream detected yet — sends the page link to Clipload. (Shift-click: audio only)"
        : `Download with Clipload (Shift-click: audio only)\n${mediaFor(target).url}`;
    }

    function place(v) {
      const r = v.getBoundingClientRect();
      // PiP Anywhere's button occupies the 36px + 10px margin at the right edge.
      host.style.left = `${Math.round(Math.min(r.right, innerWidth) - 46 - 6 - WIDTH)}px`;
      host.style.top = `${Math.round(Math.max(r.top, 0) + 10)}px`;
      host.style.display = "block";
    }

    function hide() { host.style.display = "none"; target = null; }

    function videoAt(x, y) {
      let best = null, bestArea = 0;
      for (const v of videos()) {
        const r = v.getBoundingClientRect();
        if (r.width < 160 || r.height < 90) continue;
        if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
        if (r.width * r.height > bestArea) { best = v; bestArea = r.width * r.height; }
      }
      return best;
    }

    document.addEventListener("mousemove", e => {
      if (document.fullscreenElement || document.webkitFullscreenElement) return hide();
      if (!host.isConnected) document.documentElement.appendChild(host);
      const v = videoAt(e.clientX, e.clientY);
      if (v) {
        if (v !== target) { target = v; refreshLabel(); }
        place(v);
        clearTimeout(hideTimer);
        hideTimer = setTimeout(hide, 2500);
      } else if (e.target !== host) {
        hide();
      }
    }, { passive: true, capture: true });

    addEventListener("scroll", () => target && place(target), { passive: true, capture: true });

    for (const type of ["mousedown", "pointerdown", "mouseup", "pointerup"]) {
      button.addEventListener(type, e => e.stopPropagation());
    }
    button.addEventListener("mouseenter", () => { clearTimeout(hideTimer); refreshLabel(); });
    button.addEventListener("click", e => {
      e.preventDefault();
      e.stopPropagation();
      if (!target) return;
      send(mediaFor(target), e.shiftKey);
      button.classList.add("sent");
      label.textContent = "Sent";
      setTimeout(() => { button.classList.remove("sent"); refreshLabel(); }, 1500);
    });
  }

  if (document.documentElement) start();
  else document.addEventListener("DOMContentLoaded", start, { once: true });
})();
