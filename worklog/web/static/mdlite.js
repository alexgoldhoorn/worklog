/* mdlite: render the little Markdown Todoist puts in task text as safe DOM.
   Links [text](http…) become <a>; **bold** and __bold__ markers are dropped; everything else
   is plain text. Only http(s) hrefs are allowed; the URL is never interpreted otherwise. */
(() => {
  // link text may hold one level of [brackets] ("[[Feedback] …](https://…)" is a real Todoist title)
  const LINK = /\[((?:[^\[\]]|\[[^\[\]]*\]){1,200})\]\((https?:\/\/[^\s)]{1,500})\)/g;
  const strip = (s) => String(s ?? "").replace(/\*\*(.+?)\*\*/g, "$1").replace(/__(.+?)__/g, "$1").replace(/`(.+?)`/g, "$1");

  function toNodes(text) {
    const frag = document.createDocumentFragment();
    const s = strip(text);
    let last = 0, m;
    LINK.lastIndex = 0;
    while ((m = LINK.exec(s)) !== null) {
      if (m.index > last) frag.appendChild(document.createTextNode(s.slice(last, m.index)));
      const a = document.createElement("a");
      a.href = m[2]; a.textContent = m[1]; a.target = "_blank"; a.rel = "noopener noreferrer";
      frag.appendChild(a);
      last = m.index + m[0].length;
    }
    if (last < s.length) frag.appendChild(document.createTextNode(s.slice(last)));
    return frag;
  }

  function toHtml(text) {
    const d = document.createElement("span");
    d.appendChild(toNodes(text));
    return d.innerHTML;
  }

  window.mdlite = { toNodes, toHtml, strip };
})();
