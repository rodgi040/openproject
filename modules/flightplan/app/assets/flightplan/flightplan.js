(function () {
  var directoryNode = document.getElementById("fp-agent-directory");
  var agents = {};
  if (directoryNode) {
    try {
      JSON.parse(directoryNode.textContent).forEach(function (row) {
        agents[String(row.id)] = row;
      });
    } catch (error) {
      agents = {};
    }
  }

  function badge(row) {
    var span = document.createElement("span");
    span.className = "Label Label--secondary fp-agent-badge";
    span.textContent = "Agent · " + row.group;
    return span;
  }

  function mark(root) {
    root.querySelectorAll("a[href*='/users/']").forEach(function (link) {
      if (link.dataset.fpBadged) return;
      var match = (link.getAttribute("href") || "").match(/\/users\/(\d+)/);
      if (!match || !agents[match[1]]) return;
      link.dataset.fpBadged = "1";
      link.after(badge(agents[match[1]]));
    });
  }

  if (document.body) {
    mark(document);
    var observer = new MutationObserver(function () { mark(document); });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  var openNode = document.getElementById("fp-open-questions");
  var openQuestions = {};
  if (openNode) {
    try {
      JSON.parse(openNode.textContent).forEach(function (row) {
        openQuestions[String(row.work_package_id)] = row.href;
      });
    } catch (error) {
      openQuestions = {};
    }
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest(".op-ian-item--button")) return;
    var row = event.target.closest(".op-ian-item--row");
    if (!row) return;
    var idLink = row.querySelector(".op-ian-item--work-package-id-link");
    if (!idLink) return;
    var href = openQuestions[(idLink.textContent || "").replace(/\D/g, "")];
    if (!href) return;
    event.preventDefault();
    event.stopPropagation();
    window.location.assign(href);
  }, true);

  var cards = Array.prototype.slice.call(document.querySelectorAll("[data-fp-card]"));
  if (!cards.length) return;
  var index = 0;
  var hash = (window.location.hash || "").replace("#q-", "");
  cards.forEach(function (card, position) {
    if (card.getAttribute("data-fp-card") === hash) index = position;
  });

  function show(next) {
    index = (next + cards.length) % cards.length;
    cards.forEach(function (card, position) {
      card.classList.toggle("fp-card-current", position === index);
    });
    cards[index].scrollIntoView({ block: "nearest" });
  }

  show(index);
  document.addEventListener("keydown", function (event) {
    var tag = (event.target.tagName || "").toLowerCase();
    var typing = tag === "textarea" || tag === "input" || tag === "select";
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      var form = cards[index].querySelector("form");
      if (form) form.requestSubmit();
      event.preventDefault();
      return;
    }
    if (typing) return;
    if (event.key === "j") { show(index + 1); event.preventDefault(); }
    if (event.key === "k") { show(index - 1); event.preventDefault(); }
  });
})();

(function () {
  var board = document.getElementById("fp-board");
  if (!board) return;
  var alertBox = document.getElementById("fp-board-alert");
  var dragged = false;

  function showMessage(text) {
    if (!alertBox) return;
    alertBox.hidden = false;
    alertBox.textContent = text;
  }

  board.querySelectorAll("[data-fp-board-card]").forEach(function (card) {
    card.addEventListener("click", function (event) {
      if (dragged) {
        dragged = false;
        return;
      }
      if (event.target.closest("a")) return;
      var labels = [];
      try {
        labels = JSON.parse(card.dataset.labels || "[]");
      } catch (error) {
        labels = [];
      }
      window.dispatchEvent(new CustomEvent("fp:card-selected", {
        detail: {
          id: Number(card.dataset.id),
          project: card.dataset.project,
          subject: card.dataset.subject,
          status: card.dataset.status,
          labels: labels,
          url: card.dataset.url
        }
      }));
    });

    card.addEventListener("dragstart", function (event) {
      if (event.target.closest("a")) {
        event.preventDefault();
        return;
      }
      dragged = true;
      event.dataTransfer.setData("text/plain", card.dataset.id);
      event.dataTransfer.effectAllowed = "move";
    });
  });

  board.querySelectorAll(".fp-column").forEach(function (column) {
    column.addEventListener("dragover", function (event) {
      event.preventDefault();
      column.classList.add("is-drop");
    });
    column.addEventListener("dragleave", function () {
      column.classList.remove("is-drop");
    });
    column.addEventListener("drop", function (event) {
      event.preventDefault();
      column.classList.remove("is-drop");
      var id = event.dataTransfer.getData("text/plain");
      var card = board.querySelector('[data-fp-board-card][data-id="' + id + '"]');
      if (!card || card.dataset.column === column.dataset.column) return;
      var body = new URLSearchParams();
      body.set("id", id);
      body.set("column", column.dataset.column);
      body.set("lock_version", card.dataset.lockVersion);
      fetch(board.dataset.moveUrl, {
        method: "POST",
        headers: {
          "X-CSRF-Token": board.dataset.csrf,
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded"
        },
        body: body.toString()
      }).then(function (response) {
        return response.json().catch(function () { return {}; }).then(function (payload) {
          if (!response.ok || !payload.ok) {
            showMessage(payload.error || "Statuswechsel abgelehnt");
            return;
          }
          window.location.reload();
        });
      }).catch(function () {
        showMessage("Statuswechsel abgelehnt");
      });
    });
  });
})();

(function () {
  var panel = document.getElementById("fp-chat-panel");
  var toggle = panel && panel.querySelector("[data-fp-chat-toggle]");
  if (!panel || !toggle) return;

  var origin = "http://localhost:8092";
  var body = panel.querySelector("[data-fp-chat-body]");
  var frame = panel.querySelector("[data-fp-chat-frame]");
  var offline = panel.querySelector("[data-fp-chat-offline]");
  var handle = panel.querySelector("[data-fp-chat-resize]");
  var questionsNode = document.getElementById("fp-chat-questions");
  var openKey = "fp-chat-open";
  var widthKey = "fp-chat-width";
  var questions = [];
  try {
    questions = JSON.parse(questionsNode ? questionsNode.textContent : "[]");
  } catch (error) {
    questions = [];
  }

  function width() {
    var stored = Number(window.localStorage.getItem(widthKey));
    if (!stored || stored < 280) return 360;
    if (stored > 720) return 720;
    return stored;
  }

  function post(message) {
    if (!frame || !frame.contentWindow || frame.hidden) return;
    frame.contentWindow.postMessage(message, origin);
  }

  function sendState() {
    post({
      type: "fp:questions",
      items: questions
    });
  }

  function setOpen(open) {
    panel.classList.toggle("is-open", open);
    panel.setAttribute("aria-expanded", open ? "true" : "false");
    body.hidden = !open;
    panel.style.setProperty("--fp-chat-width", width() + "px");
    window.localStorage.setItem(openKey, open ? "1" : "0");
    if (!open) return;
    if (frame.getAttribute("src")) {
      sendState();
      return;
    }
    fetch(origin + "/chat/", { mode: "no-cors", cache: "no-store" }).then(function () {
      offline.hidden = true;
      frame.hidden = false;
      frame.src = origin + "/chat/";
    }).catch(function () {
      frame.hidden = true;
      frame.removeAttribute("src");
      offline.hidden = false;
    });
  }

  toggle.addEventListener("click", function () {
    setOpen(!panel.classList.contains("is-open"));
  });

  if (handle) {
    handle.addEventListener("pointerdown", function (event) {
      event.preventDefault();
      var startX = event.clientX;
      var startWidth = width();
      function move(next) {
        var value = Math.min(720, Math.max(280, startWidth + (next.clientX - startX)));
        panel.style.setProperty("--fp-chat-width", value + "px");
        window.localStorage.setItem(widthKey, String(Math.round(value)));
      }
      function up() {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
      }
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
    });
  }

  frame.addEventListener("load", sendState);

  window.addEventListener("fp:card-selected", function (event) {
    var detail = event.detail || {};
    post({
      type: "fp:context",
      wp: {
        id: detail.id,
        subject: detail.subject,
        project: detail.project,
        status: detail.status,
        labels: detail.labels || [],
        url: detail.url
      }
    });
  });

  window.addEventListener("message", function (event) {
    if (event.origin !== origin) return;
    if (!frame.contentWindow || event.source !== frame.contentWindow) return;
    var data = event.data || {};
    if (data.type !== "fp:answer" || !data.id) return;
    var bodyParams = new URLSearchParams();
    if (data.option) bodyParams.set("option", data.option);
    if (data.text) bodyParams.set("text", data.text);
    fetch("/flightplan/questions/" + encodeURIComponent(data.id) + "/answer", {
      method: "POST",
      headers: {
        "X-CSRF-Token": panel.dataset.csrf,
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: bodyParams.toString()
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        if (!response.ok || !payload.ok) return;
        questions = payload.items || [];
        sendState();
      });
    }).catch(function () {});
  });

  setOpen(window.localStorage.getItem(openKey) === "1");
})();

(function () {
  var root = document.getElementById("fp-workplace");
  if (!root) return;
  var origin = "http://localhost:8092";
  var frame = root.querySelector("[data-fp-workplace-frame]");
  var contextNode = document.getElementById("fp-workplace-context");
  var questionsNode = document.getElementById("fp-workplace-questions");
  var wp = {};
  var questions = [];
  try {
    wp = JSON.parse(contextNode ? contextNode.textContent : "{}");
  } catch (error) {
    wp = {};
  }
  try {
    questions = JSON.parse(questionsNode ? questionsNode.textContent : "[]");
  } catch (error) {
    questions = [];
  }

  function post(message) {
    if (!frame || !frame.getAttribute("src") || !frame.contentWindow) return;
    frame.contentWindow.postMessage(message, origin);
  }

  function sendState() {
    post({ type: "fp:context", wp: wp });
    post({ type: "fp:questions", items: questions });
  }

  var offline = root.querySelector("[data-fp-chat-offline]");
  var reload = root.querySelector("[data-fp-chat-reload]");
  var helloSeen = false;
  var helloTimer = null;

  function showOffline() {
    window.clearTimeout(helloTimer);
    frame.hidden = true;
    frame.removeAttribute("src");
    if (offline) offline.hidden = false;
  }

  // Erreichbarkeit vor dem Laden (no-cors: nur ein Verbindungsfehler ist sichtbar, kein Statuscode). Eine 502-Seite
  // des Proxys meldet sich nicht mit fp:hello; bleibt es aus, zeigt die Seite denselben Hinweis.
  function start() {
    helloSeen = false;
    window.clearTimeout(helloTimer);
    if (offline) offline.hidden = true;
    fetch(origin + "/chat/", { mode: "no-cors", cache: "no-store" }).then(function () {
      frame.removeAttribute("src");
      frame.hidden = false;
      frame.src = frame.dataset.src;
      helloTimer = window.setTimeout(function () {
        if (!helloSeen) showOffline();
      }, 15000);
    }).catch(showOffline);
  }

  if (frame) {
    frame.addEventListener("load", sendState);
    // The iframe's listener starts with its module, after the load event. Repeat until it answers.
    [800, 2000, 5000, 10000].forEach(function (delay) {
      window.setTimeout(sendState, delay);
    });
    if (reload) reload.addEventListener("click", start);
    start();
  }

  window.addEventListener("message", function (event) {
    if (event.origin !== origin) return;
    if (!frame || !frame.contentWindow || event.source !== frame.contentWindow) return;
    var data = event.data || {};
    if (data.type === "fp:hello") {
      helloSeen = true;
      window.clearTimeout(helloTimer);
      if (offline) offline.hidden = true;
      frame.hidden = false;
      sendState();
      return;
    }
    if (data.type !== "fp:answer" || !data.id) return;
    var bodyParams = new URLSearchParams();
    if (data.option) bodyParams.set("option", data.option);
    if (data.text) bodyParams.set("text", data.text);
    fetch("/flightplan/questions/" + encodeURIComponent(data.id) + "/answer", {
      method: "POST",
      headers: {
        "X-CSRF-Token": root.dataset.csrf,
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: bodyParams.toString()
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        if (!response.ok || !payload.ok) return;
        questions = payload.items || [];
        sendState();
      });
    }).catch(function () {});
  });
})();

(function () {
  var match = window.location.pathname.match(/\/work_packages\/(\d+)(?:\/|$)/);
  if (!match || window.location.pathname.indexOf("/flightplan/") !== -1) return;
  var href = "/flightplan/work_packages/" + match[1];
  function insert() {
    if (document.querySelector("[data-fp-workplace-tab]")) return;
    var list = document.querySelector("[role='tablist']");
    if (!list) return;
    var link = document.createElement("a");
    link.href = href;
    link.textContent = "Arbeitsplatz";
    link.setAttribute("data-fp-workplace-tab", "1");
    link.setAttribute("role", "tab");
    list.appendChild(link);
  }
  if (document.body) {
    insert();
    new MutationObserver(insert).observe(document.body, { childList: true, subtree: true });
  }
})();
