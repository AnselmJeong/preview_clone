/* Folio chat transcript renderer: Markdown (markdown-it) + math (KaTeX) + [p.N] page links. */
(function () {
  "use strict";

  const md = window.markdownit({ html: false, linkify: true, breaks: true, typographer: false });
  const container = document.getElementById("messages");
  const post = (msg) => window.webkit.messageHandlers.folio.postMessage(msg);

  function escapeHTML(s) {
    return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function renderMath(tex, display) {
    try {
      return window.katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "html" });
    } catch (e) {
      return escapeHTML(display ? "$$" + tex + "$$" : "$" + tex + "$");
    }
  }

  /** Markdown with math: protect code, pull math out, render markdown, put rendered math back. */
  function renderMarkdown(src) {
    const codes = [];
    let s = src.replace(/```[\s\S]*?(?:```|$)|`[^`\n]+`/g, (m) => {
      codes.push(m);
      return "\u0000C" + (codes.length - 1) + "\u0000";
    });

    const maths = [];
    const stash = (tex, display) => {
      maths.push({ tex, display });
      return "@@MATH" + (maths.length - 1) + "@@";
    };
    s = s.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => stash(t, true));
    s = s.replace(/\\\[([\s\S]+?)\\\]/g, (_, t) => stash(t, true));
    s = s.replace(/\\\(([\s\S]+?)\\\)/g, (_, t) => stash(t, false));
    s = s.replace(/(^|[^\\$\w])\$(?!\s)([^\n$]+?)(?<!\s)\$(?!\w)/g, (_, pre, t) => pre + stash(t, false));

    s = s.replace(/\u0000C(\d+)\u0000/g, (_, i) => codes[+i]);

    // Page citations: [p.12], [p. 12], [pp.3-4] → links to the first page.
    s = s.replace(/\[(pp?)\.\s?(\d+)((?:\s?[-–,]\s?\d+)*)\]/g, (m, pp, n, rest) => "[" + pp + "." + n + rest + "](folio-page:" + n + ")");

    let html = md.render(s);
    html = html.replace(/@@MATH(\d+)@@/g, (_, i) => renderMath(maths[+i].tex, maths[+i].display));
    html = html.replace(/<a href="folio-page:(\d+)">/g, '<a class="page-ref" href="folio-page:$1" data-page="$1">');
    return html;
  }

  function buildMessage(m) {
    const el = document.createElement("div");
    el.id = "m-" + m.id;
    fill(el, m);
    return el;
  }

  function fill(el, m) {
    el.className = "msg " + m.role + (m.error ? " error" : "");
    let html = "";
    if (m.role === "user" && m.page) html += '<div class="meta">p.' + m.page + "</div>";
    if (m.quoted) html += '<div class="quote">' + escapeHTML(m.quoted) + "</div>";
    if (m.images && m.images.length) {
      html += '<div class="images">' + m.images.map((i) => '<img src="' + i.src + '">').join("") + "</div>";
    }
    let body;
    if (m.role === "user") {
      body = escapeHTML(m.content);
    } else if (!m.content && m.streaming) {
      body = '<span class="thinking">생각하는 중</span>';
    } else {
      body = renderMarkdown(m.content);
    }
    html += '<div class="body' + (m.streaming ? " cursor" : "") + '">' + body + "</div>";
    if (!m.streaming && (m.content || m.quoted)) {
      html += '<div class="actions"><button class="copy" data-id="' + m.id + '">복사</button></div>';
    }
    el.innerHTML = html;
  }

  function nearBottom() {
    const doc = document.scrollingElement;
    return doc.scrollHeight - doc.scrollTop - window.innerHeight < 80;
  }

  function scrollToBottom() {
    const doc = document.scrollingElement;
    doc.scrollTop = doc.scrollHeight;
  }

  window.folio = {
    setMessages(list) {
      container.innerHTML = "";
      for (const m of list) container.appendChild(buildMessage(m));
      scrollToBottom();
    },
    update(m) {
      const stick = nearBottom();
      const el = document.getElementById("m-" + m.id);
      if (el) fill(el, m);
      else container.appendChild(buildMessage(m));
      if (stick) scrollToBottom();
    },
  };

  document.addEventListener("click", (e) => {
    const copy = e.target.closest("button.copy");
    if (copy) {
      post({ action: "copy", id: copy.dataset.id });
      copy.textContent = "복사됨";
      setTimeout(() => (copy.textContent = "복사"), 1200);
      e.preventDefault();
      return;
    }
    const ref = e.target.closest("a[data-page]");
    if (ref) {
      post({ action: "page", page: parseInt(ref.dataset.page, 10) });
      e.preventDefault();
    }
  });

  post({ action: "ready" });
})();
