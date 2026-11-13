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
    // Page citations: [p.12], [p. 12], [pp.3-4], [p.1, p.3] → one pill per page reference.
    s = s.replace(/\[((?:(?:pp?\.|page|p)\s?\d+(?:\s?[-–]\s?\d+)?)(?:\s?[,;]\s?(?:(?:pp?\.|page|p)\s?)?\d+(?:\s?[-–]\s?\d+)?)*)\]/gi, (m, inner) =>
      inner.split(/\s?[,;]\s?/).map((part) => {
        const r = part.replace(/^(?:pp?\.|page|p)\s?/i, "").replace(/\s/g, "");
        return "[" + r + "](folio-page:" + parseInt(r, 10) + ")";
      }).join(" "));

    let html = md.render(s);
    // CommonMark won't close **…** next to punctuation in CJK text (e.g. **"강도"**는); finish those here.
    html = html.split(/(<code[\s\S]*?<\/code>)/).map((part, i) =>
      i % 2 ? part : part.replace(/\*\*([^*<>\n]{1,200}?)\*\*/g, "<strong>$1</strong>")).join("");
    html = html.replace(/@@MATH(\d+)@@/g, (_, i) => renderMath(maths[+i].tex, maths[+i].display));
    html = html.replace(/<a href="folio-page:(\d+)">/g, '<a class="page-ref" href="folio-page:$1" data-page="$1">');
    return html;
  }

  const ICONS = {
    copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>',
    check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    export: '<svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M5 19.5h14"/></svg>',
    regenerate: '<svg viewBox="0 0 24 24"><path d="M19.5 12a7.5 7.5 0 0 1-13.2 4.9"/><path d="M4.5 12a7.5 7.5 0 0 1 13.2-4.9"/><path d="M18 3.5v4h-4"/><path d="M6 20.5v-4h4"/></svg>',
    delete: '<svg viewBox="0 0 24 24"><path d="M4.5 7h15"/><path d="M9.5 7V5h5v2"/><path d="M6.5 7l.8 11.2A2 2 0 0 0 9.3 20h5.4a2 2 0 0 0 2-1.8L17.5 7"/><path d="M10.5 11v5M13.5 11v5"/></svg>',
  };
  const TITLES = { copy: "복사", export: "Markdown으로 저장", regenerate: "다시 생성", delete: "삭제" };

  let lastAssistantID = null;

  function actionRow(m) {
    const kinds = m.role === "user" ? ["copy", "delete"]
      : (m.id === lastAssistantID ? ["copy", "export", "regenerate", "delete"] : ["copy", "export", "delete"]);
    return '<div class="actions">' + kinds.map((k) =>
      '<button data-action="' + k + '" data-id="' + m.id + '" title="' + TITLES[k] + '">' + ICONS[k] + "</button>").join("") + "</div>";
  }

  function buildMessage(m) {
    const el = document.createElement("div");
    el.id = "m-" + m.id;
    fill(el, m);
    return el;
  }

  function fill(el, m) {
    el.className = "msg " + m.role + (m.error ? " error" : "");
    el.dataset.role = m.role;
    let inner = "";
    if (m.quoted) inner += '<div class="quote">' + escapeHTML(m.quoted) + "</div>";
    if (m.images && m.images.length) {
      inner += '<div class="images">' + m.images.map((i) => '<img src="' + i.src + '">').join("") + "</div>";
    }
    let body;
    if (m.role === "user") {
      body = escapeHTML(m.content);
    } else if (!m.content && m.streaming) {
      body = '<span class="thinking">생각하는 중</span>';
    } else {
      body = renderMarkdown(m.content);
    }
    inner += '<div class="body' + (m.streaming && m.content ? " cursor" : "") + '">' + body + "</div>";

    let html;
    if (m.role === "user") {
      html = (m.page ? '<div class="meta">p.' + m.page + "</div>" : "") + '<div class="bubble">' + inner + "</div>";
    } else {
      html = inner;
    }
    if (!m.streaming && (m.content || m.quoted)) html += actionRow(m);
    el.innerHTML = html;
  }

  function refreshLastAssistant(list) {
    const last = [...list].reverse().find((m) => m.role === "assistant");
    lastAssistantID = last ? last.id : null;
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
      refreshLastAssistant(list);
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
    const btn = e.target.closest("button[data-action]");
    if (btn) {
      const action = btn.dataset.action;
      post({ action, id: btn.dataset.id });
      if (action === "copy") {
        btn.innerHTML = ICONS.check;
        btn.classList.add("done");
        setTimeout(() => { btn.innerHTML = ICONS.copy; btn.classList.remove("done"); }, 1200);
      }
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
