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
})();

// OP#1674: Board-Widget des ADA-Dashboards. Karten per Drag & Drop über die Move-Route verschieben; nach Erfolg wandert die
// Karte ohne Neuladen in die Spalte, die der Server meldet (der Chat bleibt stehen).
(function () {
  var board = document.getElementById("fp-board");
  if (!board) return;
  var widget = board.closest("[data-fp-widget]");
  var alertBox = document.getElementById("fp-board-alert");
  var dragged = false;

  function showMessage(text) {
    if (!alertBox) return;
    alertBox.hidden = false;
    alertBox.textContent = text;
  }

  function setCount(column, delta) {
    var count = Math.max(0, Number(column.dataset.count || 0) + delta);
    column.dataset.count = String(count);
    var badge = column.querySelector("[data-fp-group-count]");
    if (badge) badge.setAttribute("data-fp-total", String(count));
    var empty = column.querySelector(".fp-empty");
    var cards = column.querySelectorAll("[data-fp-board-card]").length;
    if (empty) empty.hidden = cards > 0;
  }

  function place(card, from, to) {
    var list = to.querySelector(".fp-column-cards");
    if (!list) return;
    list.insertBefore(card, list.firstChild);
    card.dataset.column = to.dataset.column;
    card.dataset.status = to.dataset.status;
    setCount(from, -1);
    setCount(to, 1);
    if (widget) widget.dispatchEvent(new CustomEvent("fp:refilter"));
  }

  board.addEventListener("click", function (event) {
    var card = event.target.closest("[data-fp-board-card]");
    if (!card) return;
    if (dragged) {
      dragged = false;
      return;
    }
    if (event.target.closest("a, button")) return;
    window.dispatchEvent(new CustomEvent("fp:card-selected", {
      detail: {
        id: Number(card.dataset.id),
        project: card.dataset.project,
        subject: card.dataset.subject,
        status: card.dataset.status,
        labels: fpParseList(card.dataset.labels),
        url: card.dataset.url
      }
    }));
  });

  board.addEventListener("dragstart", function (event) {
    var card = event.target.closest && event.target.closest("[data-fp-board-card]");
    if (!card) return;
    dragged = true;
    event.dataTransfer.setData("text/plain", card.dataset.id);
    event.dataTransfer.effectAllowed = "move";
  });

  board.querySelectorAll(".fp-column").forEach(function (column) {
    column.addEventListener("dragover", function (event) {
      if (column.dataset.drop === "off") return;
      event.preventDefault();
      column.classList.add("is-drop");
    });
    column.addEventListener("dragleave", function () {
      column.classList.remove("is-drop");
    });
    column.addEventListener("drop", function (event) {
      event.preventDefault();
      column.classList.remove("is-drop");
      dragged = false;
      var id = event.dataTransfer.getData("text/plain");
      var card = board.querySelector('[data-fp-board-card][data-id="' + String(id).replace(/\D/g, "") + '"]');
      if (!card || card.dataset.column === column.dataset.column) return;
      if (column.dataset.drop === "off") {
        showMessage(board.dataset.fpDropOffText || "");
        return;
      }
      var from = card.closest(".fp-column");
      var body = new URLSearchParams();
      body.set("id", card.dataset.id);
      body.set("column", column.dataset.column);
      body.set("lock_version", card.dataset.lockVersion);
      fetch(board.dataset.moveUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": board.dataset.csrf,
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded"
        },
        body: body.toString()
      }).then(function (response) {
        return response.json().catch(function () { return {}; }).then(function (payload) {
          if (!response.ok || !payload.ok) {
            showMessage(payload.error || board.dataset.fpFailedText || "");
            return;
          }
          if (alertBox) alertBox.hidden = true;
          if (payload.lock_version !== undefined) card.dataset.lockVersion = String(payload.lock_version);
          var target = board.querySelector('.fp-column[data-column="' + (payload.column || column.dataset.column) + '"]') || column;
          place(card, from, target);
        });
      }).catch(function () {
        showMessage(board.dataset.fpFailedText || "");
      });
    });
  });

  if (!widget) return;
  var wikiLink = widget.querySelector("[data-fp-board-wiki]");
  var wikis = {};
  try {
    wikis = JSON.parse((widget.querySelector("[data-fp-board-wikis]") || {}).textContent || "{}");
  } catch (error) {
    wikis = {};
  }
  var scope = widget.querySelector("[data-fp-filter='scope']");

  // Wiki-Link nur, wenn genau ein Projekt gewählt ist und es ein Wiki hat (OP#1670 D7).
  function updateWiki() {
    if (!wikiLink || !scope) return;
    var value = scope.value || "";
    var entry = value.indexOf("project:") === 0 ? wikis[value.slice(8)] : null;
    wikiLink.hidden = !entry;
    if (entry) {
      wikiLink.textContent = entry.label;
      wikiLink.setAttribute("href", entry.href);
    }
  }

  if (scope) {
    scope.addEventListener("change", updateWiki);
    updateWiki();
  }

  widget.querySelectorAll("[data-fp-board-bereich]").forEach(function (button) {
    button.addEventListener("click", function () {
      if (!scope) return;
      var value = "bereich:" + button.getAttribute("data-fp-board-bereich");
      scope.value = scope.value === value ? "" : value;
      scope.dispatchEvent(new Event("change", { bubbles: true }));
    });
  });
})();

// OP#1710: Rückmeldung an das Chat-iframe nach einer Antwort (postMessage fp:answered an die Chat-Origin).
function fpAnsweredMessage(id, response, payload) {
  var answer = (payload && payload.answer) || {};
  var ok = !!(response && response.ok && payload && payload.ok);
  return {
    type: "fp:answered",
    questionId: Number(id),
    ok: ok,
    status: ok ? String(answer.status || "") : "",
    answer: ok ? String(answer.option || answer.text || "") : "",
    error: ok ? "" : String((payload && payload.error) || (response ? "HTTP " + response.status : "Netzwerkfehler"))
  };
}

// OP#1711 Welle 2: Rückmeldung an den Chat nach einer Nachricht, die als Kommentar gespeichert wurde (fp:commented).
// "Gespeichert" heißt nicht "zugestellt": ein Agent sieht den Kommentar erst beim nächsten Lesen.
function fpCommentedMessage(wpId, clientId, response, payload) {
  var ok = !!(response && response.ok && payload && payload.ok);
  return {
    type: "fp:commented",
    wpId: Number(wpId),
    clientId: String(clientId || ""),
    ok: ok,
    eventId: ok ? String(payload.event_id || "") : "",
    message: ok ? String(payload.message || "") : "",
    error: ok ? "" : String((payload && payload.error) || (response ? "HTTP " + response.status : "Netzwerkfehler"))
  };
}

// OP#1711 Welle 2: neue Ereignisse (Id wie c12, s12, q3) an die bekannten anfügen, ohne Dubletten. Reihenfolge nach Zeit.
function fpMergeEvents(known, incoming) {
  var seen = {};
  var merged = [];
  (known || []).concat(incoming || []).forEach(function (event) {
    if (!event || !event.id || seen[event.id]) return;
    seen[event.id] = true;
    merged.push(event);
  });
  merged.sort(function (a, b) {
    return String(a.at).localeCompare(String(b.at)) || String(a.id).localeCompare(String(b.id), undefined, { numeric: true });
  });
  return merged.slice(-60);
}

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
        // OP#1710: Rückmeldung an den Chat (fp:answered), auch im Fehlerfall.
        post(fpAnsweredMessage(data.id, response, payload));
        if (!response.ok || !payload.ok) return;
        questions = payload.items || [];
        sendState();
      });
    }).catch(function () {
      post(fpAnsweredMessage(data.id, null, {}));
    });
  });

  setOpen(window.localStorage.getItem(openKey) === "1");
})();

// Chat iframe of the workplace (#fp-workplace) and of the home screen (#fp-home-chat, OP#1671).
function fpMountChat(root, frame) {
  var origin = "http://localhost:8092";
  var contextNode = document.getElementById("fp-workplace-context");
  var questionsNode = root.querySelector("[data-fp-chat-questions]") || document.getElementById("fp-workplace-questions");
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

  // OP#1711 Welle 2: Ereignisse des offenen Tickets (Kommentare, Statuswechsel, Rückfragen). Das Modul fragt etwa alle
  // 10 s nach und sendet den bekannten Stand als fp:events. Ereignisse sind nur Anzeige; die Id macht Wiederholungen
  // und Neuladen idempotent.
  var eventsFor = 0;
  var eventList = [];
  var eventCursor = { journal: 0, question: 0 };
  var eventsDisabled = false;
  var eventsBusy = false;

  function sendEvents() {
    if (!eventsFor) return;
    post({ type: "fp:events", wpId: eventsFor, events: eventList });
  }

  function pollEvents() {
    var id = wp && Number(wp.id);
    if (eventsDisabled || eventsBusy || !id || !frame || !frame.getAttribute("src")) return;
    if (id !== eventsFor) {
      eventsFor = id;
      eventList = [];
      eventCursor = { journal: 0, question: 0 };
    }
    eventsBusy = true;
    var query = "wp=" + id + (eventCursor.journal ? "&after=" + eventCursor.journal : "") +
      (eventCursor.question ? "&after_question=" + eventCursor.question : "");
    fetch("/flightplan/chat/events?" + query, { headers: { "Accept": "application/json" }, credentials: "same-origin" })
      .then(function (response) {
        if (response.status === 403) eventsDisabled = true;
        return response.json().catch(function () { return {}; }).then(function (payload) {
          return { ok: response.ok, payload: payload };
        });
      })
      .then(function (result) {
        eventsBusy = false;
        if (!result.ok || !result.payload.ok || Number(result.payload.work_package_id) !== eventsFor) return;
        var before = eventList.length;
        eventList = fpMergeEvents(eventList, result.payload.events);
        var cursor = result.payload.cursor || {};
        eventCursor = { journal: Number(cursor.journal) || eventCursor.journal, question: Number(cursor.question) || eventCursor.question };
        if (eventList.length !== before || before === 0) sendEvents();
      })
      .catch(function () {
        eventsBusy = false;
      });
  }

  function sendState() {
    if (wp && wp.id) post({ type: "fp:context", wp: wp });
    post({ type: "fp:questions", items: questions });
    sendEvents();
    if (wp && Number(wp.id) !== eventsFor) pollEvents();
  }

  window.setInterval(function () {
    if (document.hidden) return;
    pollEvents();
  }, 10000);

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
    // Der fp:hello-Timer läuft unabhängig vom Ergebnis des fetch; der fetch bricht nach 8 s ab.
    window.clearTimeout(helloTimer);
    helloTimer = window.setTimeout(function () {
      if (!helloSeen) showOffline();
    }, 15000);
    var controller = typeof AbortController === "function" ? new AbortController() : null;
    var abortTimer = controller ? window.setTimeout(function () { controller.abort(); }, 8000) : null;
    var options = { mode: "no-cors", cache: "no-store" };
    if (controller) options.signal = controller.signal;
    fetch(origin + "/chat/", options).then(function () {
      window.clearTimeout(abortTimer);
      frame.removeAttribute("src");
      frame.hidden = false;
      frame.src = frame.dataset.src;
    }).catch(function () {
      window.clearTimeout(abortTimer);
      showOffline();
    });
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
    if (data.type === "fp:comment") {
      // OP#1711 Welle 2: Nachricht aus dem Thread wird Kommentar im Namen des angemeldeten Menschen (Session, CSRF).
      var wpId = Number(data.wpId);
      if (!wpId || typeof data.text !== "string") return;
      fetch("/flightplan/chat/comments", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": root.dataset.csrf,
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded"
        },
        body: new URLSearchParams({ wp: String(wpId), text: data.text.slice(0, 4000) }).toString()
      }).then(function (response) {
        return response.json().catch(function () { return {}; }).then(function (payload) {
          post(fpCommentedMessage(wpId, data.clientId, response, payload));
          if (response.ok && payload.ok) pollEvents();
        });
      }).catch(function () {
        post(fpCommentedMessage(wpId, data.clientId, null, {}));
      });
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
        // OP#1710: Rückmeldung an den Chat (fp:answered), auch im Fehlerfall.
        post(fpAnsweredMessage(data.id, response, payload));
        if (!response.ok || !payload.ok) return;
        questions = payload.items || [];
        sendState();
        fpMarkAnswered(data.id, payload.answer && payload.answer.message, payload.answer && payload.answer.status);
      });
    }).catch(function () {
      post(fpAnsweredMessage(data.id, null, {}));
    });
  });

  window.addEventListener("fp:questions-changed", function (event) {
    questions = (event.detail && event.detail.items) || [];
    sendState();
  });

  // OP#1674: Klick auf eine Board-Karte im Dashboard gibt dem Chat das Ticket als Kontext.
  window.addEventListener("fp:card-selected", function (event) {
    var detail = event.detail || {};
    if (!detail.id) return;
    wp = { id: detail.id, subject: detail.subject, project: detail.project, status: detail.status,
           labels: detail.labels || [], url: detail.url };
    // OP#1711: Auf der Startseite (Ticketleiste) öffnet die Karte den Thread des Tickets, der Kontext folgt beim Laden.
    if (bar) openTicket(detail.id, detail.subject, true);
    else post({ type: "fp:context", wp: wp });
  });

  // OP#1711: Ticketleiste der Startseite. Ein Klick lädt /chat/embed/<id> (T3 holt oder legt den Thread je Ticket an,
  // idempotent); "Neuer Chat" lädt /chat/. Titel sind untrusted und gelangen nur per textContent in die Seite.
  var bar = root.querySelector("[data-fp-chat-tickets]");
  var recentKey = "fp-chat-recent-tickets";

  function readRecent() {
    try {
      var list = JSON.parse(window.localStorage.getItem(recentKey) || "[]");
      return Array.isArray(list) ? list.filter(function (item) { return item && Number(item.id) > 0; }).slice(0, 5) : [];
    } catch (error) {
      return [];
    }
  }

  function markActive(id) {
    var found = false;
    bar.querySelectorAll("[data-fp-chat-ticket], [data-fp-chat-new]").forEach(function (node) {
      var active = !found && (id ? node.dataset.fpChatTicket === String(id) : node.hasAttribute("data-fp-chat-new"));
      if (active) {
        found = true;
        node.setAttribute("aria-current", "true");
      } else {
        node.removeAttribute("aria-current");
      }
    });
    var label = bar.querySelector("[data-fp-chat-active]");
    if (label) {
      var current = id ? bar.querySelector("[data-fp-chat-ticket='" + String(Number(id)) + "']") : null;
      var text = id ? "#" + Number(id) + (current && current.dataset.subject ? " " + current.dataset.subject : (wp && wp.subject ? " " + wp.subject : "")) : label.dataset.new;
      label.textContent = label.dataset.prefix + ": " + text;
    }
  }

  function renderRecent() {
    var holder = bar.querySelector("[data-fp-chat-recent]");
    var list = bar.querySelector("[data-fp-chat-recent-list]");
    if (!holder || !list) return;
    var listed = {};
    bar.querySelectorAll("[data-fp-chat-ticket-list] [data-fp-chat-ticket]").forEach(function (node) {
      listed[node.dataset.fpChatTicket] = true;
    });
    var items = readRecent().filter(function (item) { return !listed[String(Number(item.id))]; });
    list.textContent = "";
    items.forEach(function (item) {
      var li = document.createElement("li");
      var link = document.createElement("a");
      var id = document.createElement("span");
      var title = document.createElement("span");
      link.className = "fp-chat-ticket";
      link.href = origin + "/chat/embed/" + Number(item.id);
      link.setAttribute("data-fp-chat-ticket", String(Number(item.id)));
      link.setAttribute("data-subject", String(item.subject || ""));
      id.className = "fp-chat-ticket-id";
      id.textContent = "#" + Number(item.id);
      title.className = "fp-chat-ticket-title";
      title.textContent = String(item.subject || "");
      link.appendChild(id);
      link.appendChild(title);
      li.appendChild(link);
      list.appendChild(li);
    });
    holder.hidden = items.length === 0;
    markActive(wp && wp.id);
  }

  function rememberTicket(id, subject) {
    var items = readRecent().filter(function (item) { return Number(item.id) !== Number(id); });
    items.unshift({ id: Number(id), subject: String(subject || "").slice(0, 70) });
    try {
      window.localStorage.setItem(recentKey, JSON.stringify(items.slice(0, 5)));
    } catch (error) {
      // localStorage nicht verfügbar: die Leiste funktioniert ohne Verlauf weiter.
    }
    renderRecent();
  }

  // Live-Prüfung fp.20: nach einem Klick bleibt der Rahmen einige Sekunden leer; der Hinweis steht bis zum Laden.
  var loading = root.querySelector("[data-fp-chat-loading]");
  function showLoading(url) {
    if (!loading) return;
    var match = /\/embed\/(\d+)$/.exec(url);
    if (!match) {
      loading.hidden = true;
      return;
    }
    loading.textContent = (loading.dataset.template || "").replace("__ID__", match[1]);
    loading.hidden = false;
  }
  if (frame && loading) frame.addEventListener("load", function () { loading.hidden = true; });

  function loadFrame(url) {
    frame.dataset.src = url;
    // Chat nicht erreichbar (kein src): "Neu laden" lädt danach den gewählten Thread.
    if (!frame.getAttribute("src")) return;
    if (frame.getAttribute("src") === url) {
      sendState();
      return;
    }
    showLoading(url);
    frame.src = url;
  }

  function openTicket(id, subject, fromBoard) {
    if (!bar || !frame || !Number(id)) return;
    if (!fromBoard || !wp || Number(wp.id) !== Number(id)) wp = { id: Number(id), subject: subject };
    markActive(id);
    rememberTicket(id, subject);
    loadFrame(origin + "/chat/embed/" + Number(id));
  }

  if (bar && frame) {
    wp = {};
    bar.addEventListener("click", function (event) {
      var link = event.target.closest("[data-fp-chat-ticket]");
      var fresh = event.target.closest("[data-fp-chat-new]");
      var more = event.target.closest("[data-fp-chat-more-toggle]");
      if (link) {
        event.preventDefault();
        openTicket(link.dataset.fpChatTicket, link.dataset.subject);
      } else if (fresh) {
        wp = {};
        markActive(null);
        loadFrame(origin + "/chat/");
      } else if (more) {
        var open = more.getAttribute("aria-expanded") !== "true";
        bar.querySelectorAll("li[data-fp-chat-more]").forEach(function (node) { node.hidden = !open; });
        more.setAttribute("aria-expanded", open ? "true" : "false");
        more.textContent = open ? "−" : more.dataset.label;
      }
    });
    var head = bar.querySelector("[data-fp-chat-tickets-toggle]");
    var body = bar.querySelector("[data-fp-chat-tickets-body]");
    var openKey = "fp-chat-tickets-open";
    function setBarOpen(open, persist) {
      body.hidden = !open;
      head.setAttribute("aria-expanded", open ? "true" : "false");
      head.querySelector("[data-fp-chat-tickets-arrow]").textContent = open ? "\u25B4" : "\u25BE";
      if (persist) {
        try { window.localStorage.setItem(openKey, open ? "1" : "0"); } catch (error) { /* ohne Speicher */ }
      }
    }
    if (head && body) {
      var stored = null;
      try { stored = window.localStorage.getItem(openKey); } catch (error) { stored = null; }
      var small = typeof window.matchMedia === "function" && window.matchMedia("(max-height: 700px)").matches;
      setBarOpen(stored === null ? !small : stored === "1", false);
      head.addEventListener("click", function () {
        setBarOpen(head.getAttribute("aria-expanded") !== "true", true);
      });
    }
    var moreButton = bar.querySelector("[data-fp-chat-more-toggle]");
    if (moreButton) moreButton.dataset.label = moreButton.textContent.trim();
    renderRecent();
  }
}

(function () {
  var workplace = document.getElementById("fp-workplace");
  if (workplace) fpMountChat(workplace, workplace.querySelector("[data-fp-workplace-frame]"));
  var home = document.getElementById("fp-home-chat");
  if (home) fpMountChat(home, home.querySelector("[data-fp-home-frame]"));
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

// OP#1672: Suche und Filter je Dashboard-Widget, im Browser über die gerenderten Einträge ([data-fp-item]).
function fpParseList(value) {
  try {
    var list = JSON.parse(value || "[]");
    return Array.isArray(list) ? list.map(String) : [];
  } catch (error) {
    return [];
  }
}

function fpNormalize(text) {
  return String(text || "").toLocaleLowerCase("de").replace(/\s+/g, " ").trim();
}

// Label-Filter: je Fieldset eine Gruppe. Innerhalb einer Gruppe genügt ein Label (ODER), über Gruppen hinweg müssen alle
// Gruppen mit Auswahl passen (UND). Heute gibt es eine Gruppe; Kategorien aus OP#1670 brauchen hier keine Änderung.
function fpLabelFilter(box) {
  if (!box) {
    return { active: function () { return false; }, match: function () { return true; }, reset: function () {} };
  }
  var groups = Array.prototype.slice.call(box.querySelectorAll("[data-fp-label-group]"));
  var counter = box.querySelector("[data-fp-labels-count]");
  // OP#1706: gewählte Labels als kleine Chips mit Entfernen-Möglichkeit neben dem Aufklappfeld.
  var chips = box.parentNode && box.parentNode.querySelector("[data-fp-active-labels]");

  function renderChips() {
    if (!chips) return;
    chips.textContent = "";
    box.querySelectorAll("input[type='checkbox']:checked").forEach(function (input) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "fp-active-label";
      chip.textContent = input.value + " \u00d7";
      chip.title = input.value;
      chip.addEventListener("click", function () {
        input.checked = false;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      chips.appendChild(chip);
    });
  }

  function selected() {
    return groups.map(function (group) {
      return Array.prototype.slice.call(group.querySelectorAll("input[type='checkbox']:checked")).map(function (input) {
        return input.value;
      });
    }).filter(function (names) { return names.length; });
  }

  return {
    active: function () {
      var count = selected().reduce(function (sum, names) { return sum + names.length; }, 0);
      if (counter) counter.textContent = count ? "(" + count + ")" : "";
      renderChips();
      return count > 0;
    },
    match: function (labels) {
      return selected().every(function (names) {
        return names.some(function (name) { return labels.indexOf(name) !== -1; });
      });
    },
    reset: function () {
      box.querySelectorAll("input[type='checkbox']").forEach(function (input) { input.checked = false; });
      box.open = false;
    }
  };
}

function fpWidgetFilters(widget) {
  var tools = widget.querySelector("[data-fp-widget-tools]");
  if (!tools) return;
  var items = Array.prototype.slice.call(widget.querySelectorAll("[data-fp-item]"));
  var groups = Array.prototype.slice.call(widget.querySelectorAll("[data-fp-group]"));
  var text = tools.querySelector("[data-fp-filter='text']");
  var scope = tools.querySelector("[data-fp-filter='scope']");
  var status = tools.querySelector("[data-fp-filter='status']");
  var labels = fpLabelFilter(tools.querySelector("[data-fp-filter='labels']"));
  var attrs = Array.prototype.slice.call(tools.querySelectorAll("select[data-fp-filter-attr]"));
  var options = Array.prototype.slice.call(tools.querySelectorAll("[data-fp-filter='labels'] input[type='checkbox']"));
  var reset = tools.querySelector("[data-fp-filter-reset]");
  var count = widget.querySelector("[data-fp-widget-count]");
  var none = widget.querySelector("[data-fp-widget-none]");

  // OP#1674: data-fp-total trägt die Zahl vom Server, wenn nicht alle Einträge gerendert sind (Board: 200 je Spalte).
  function totalOf(node, fallback) {
    var total = node && node.getAttribute("data-fp-total");
    return total !== null && total !== undefined && total !== "" ? total : String(fallback);
  }

  function matchAttrs(item) {
    return attrs.every(function (select) {
      if (!select.value) return true;
      return fpParseList(item.getAttribute("data-fp-" + select.getAttribute("data-fp-filter-attr"))).indexOf(select.value) !== -1;
    });
  }

  // OP#1674: Angeboten werden nur Labels, die ein offener Eintrag im übrigen Filter trägt; gewählte bleiben stehen.
  function narrowLabels(passing) {
    if (!options.length) return;
    var present = {};
    passing.forEach(function (item) {
      if (item.getAttribute("data-fp-open") === "0") return;
      fpParseList(item.getAttribute("data-fp-labels")).forEach(function (name) { present[name] = true; });
    });
    options.forEach(function (input) {
      var holder = input.closest("label") || input;
      holder.hidden = !input.checked && !present[input.value];
    });
    tools.querySelectorAll("[data-fp-filter='labels'] [data-fp-label-group]").forEach(function (group) {
      group.hidden = !group.querySelector("label:not([hidden]) input, input:checked");
    });
  }

  function matchScope(item, value) {
    var split = value.indexOf(":");
    var kind = value.slice(0, split);
    var key = value.slice(split + 1);
    if (kind === "bereich") return item.getAttribute("data-fp-area") === key;
    return fpParseList(item.getAttribute("data-fp-projects")).indexOf(key) !== -1;
  }

  function apply() {
    var words = fpNormalize(text && text.value).split(" ").filter(Boolean);
    var scopeValue = scope ? scope.value : "";
    var statusValue = status ? status.value : "";
    var labelsOn = labels.active();
    var attrsOn = attrs.some(function (select) { return !!select.value; });
    var active = words.length > 0 || !!scopeValue || !!statusValue || labelsOn || attrsOn;
    var shown = 0;
    var passing = [];
    items.forEach(function (item) {
      var itemLabels = fpParseList(item.getAttribute("data-fp-labels"));
      var ok = true;
      if (words.length) {
        var haystack = fpNormalize(item.textContent + " " + itemLabels.join(" "));
        ok = words.every(function (word) { return haystack.indexOf(word) !== -1; });
      }
      if (ok && scopeValue) ok = matchScope(item, scopeValue);
      if (ok && statusValue) ok = fpParseList(item.getAttribute("data-fp-statuses")).indexOf(statusValue) !== -1;
      if (ok && attrsOn) ok = matchAttrs(item);
      if (ok) passing.push(item);
      if (ok && labelsOn) ok = labels.match(itemLabels);
      item.hidden = !ok;
      // Ausgeblendete Zeilen dürfen nicht unbemerkt mit der Sammelfreigabe abgeschickt werden.
      item.querySelectorAll("input[type='checkbox']").forEach(function (input) { input.disabled = !ok; });
      if (ok) shown += 1;
    });
    groups.forEach(function (group) {
      var all = group.querySelectorAll("[data-fp-item]").length;
      var visible = group.querySelectorAll("[data-fp-item]:not([hidden])").length;
      group.hidden = active && all > 0 && visible === 0;
      var badge = group.querySelector("[data-fp-group-count]");
      if (badge) badge.textContent = active ? visible + " / " + all : totalOf(badge, all);
    });
    if (count) count.textContent = active ? shown + " / " + items.length : totalOf(count, items.length);
    narrowLabels(passing);
    if (none) none.hidden = !(active && shown === 0);
    if (reset) reset.hidden = !active;
    widget.classList.toggle("is-filtered", active);
  }

  tools.addEventListener("input", apply);
  tools.addEventListener("change", apply);
  tools.addEventListener("submit", function (event) { event.preventDefault(); });
  if (text) {
    text.addEventListener("keydown", function (event) {
      if (event.key === "Enter") event.preventDefault();
    });
  }
  if (reset) {
    reset.addEventListener("click", function () {
      if (text) text.value = "";
      if (scope) scope.value = "";
      if (status) status.value = "";
      attrs.forEach(function (select) { select.value = ""; });
      labels.reset();
      apply();
      if (text) text.focus();
    });
  }
  widget.addEventListener("fp:refilter", apply);
  // OP#1674: Klick auf einen Label-Chip einer Karte setzt diesen Label-Filter (statt zu einem Wiki zu springen).
  widget.addEventListener("click", function (event) {
    var pick = event.target.closest && event.target.closest("[data-fp-label-pick]");
    if (!pick) return;
    event.preventDefault();
    var name = pick.getAttribute("data-fp-label-pick");
    var input = options.filter(function (box) { return box.value === name; })[0];
    if (!input) return;
    input.checked = !input.checked;
    apply();
  });
  var labelBox = tools.querySelector("details[data-fp-filter='labels']");
  if (labelBox) {
    document.addEventListener("click", function (event) {
      if (labelBox.open && !labelBox.contains(event.target)) labelBox.open = false;
    });
    // Das Aufklappfeld klappt nach links, wenn es rechts aus der scrollenden Hauptspalte ragen würde.
    labelBox.addEventListener("toggle", function () {
      labelBox.classList.remove("is-flipped");
      if (!labelBox.open) return;
      var pop = labelBox.querySelector(".fp-widget-labels-pop");
      var frame = widget.closest(".fp-home-main") || document.documentElement;
      if (pop && pop.getBoundingClientRect().right > frame.getBoundingClientRect().right) labelBox.classList.add("is-flipped");
    });
  }
  apply();
}

(function () {
  document.querySelectorAll("[data-fp-widget]").forEach(fpWidgetFilters);
})();

// OP#1674: Einklappbare Widgets (Board). Der Zustand bleibt je Widget im Browser gespeichert.
(function () {
  document.querySelectorAll("[data-fp-widget-toggle]").forEach(function (button) {
    var widget = button.closest("[data-fp-widget]");
    if (!widget) return;
    var key = "fp-widget-collapsed-" + widget.getAttribute("data-fp-widget");
    function set(collapsed) {
      widget.classList.toggle("is-collapsed", collapsed);
      button.setAttribute("aria-expanded", collapsed ? "false" : "true");
      button.title = button.getAttribute(collapsed ? "data-fp-label-closed" : "data-fp-label-open") || "";
      try { window.localStorage.setItem(key, collapsed ? "1" : "0"); } catch (error) { /* privat */ }
    }
    var stored = null;
    try { stored = window.localStorage.getItem(key); } catch (error) { stored = null; }
    // OP#1722: Widgets mit data-fp-collapsed-default (Übersicht) starten eingeklappt, bis der Nutzer anders wählt.
    var byDefault = widget.hasAttribute("data-fp-collapsed-default");
    if (stored === "1" || (stored === null && byDefault)) set(true);
    else if (stored === "0") set(false);
    button.addEventListener("click", function () {
      set(!widget.classList.contains("is-collapsed"));
    });
  });
})();

// OP#1673: Antwort im Widget „Rückfragen“ ohne Neuladen. Ohne Skript schickt das Formular normal ab und die Seite kommt
// zurück. Nach der Antwort bekommt der Chat die neue Liste (fp:questions).
function fpMarkAnswered(id, message, status) {
  document.querySelectorAll("[data-fp-question='" + String(id).replace(/\D/g, "") + "']").forEach(function (item) {
    item.classList.add("is-answered");
    var form = item.querySelector("form[data-fp-question-form]");
    if (form) form.remove();
    var note = item.querySelector("[data-fp-question-note]");
    if (note) {
      note.classList.remove("is-error");
      note.classList.add("is-done");
      note.setAttribute("role", "status");
      note.textContent = message || item.getAttribute("data-fp-answered-text") || "";
      note.hidden = false;
      if (typeof note.scrollIntoView === "function") note.scrollIntoView({ block: "nearest" });
    }
    // Live-Prüfung fp.20: die Zeile in „Aufmerksamkeit“ zeigt nach der Antwort den neuen Status und nicht mehr „offene
    // Rückfrage“, sobald keine weitere Frage in der Zeile offen ist.
    var row = item.closest("tr[data-wp]");
    if (!row) return;
    var badge = row.querySelector(".fp-badge[data-fp-status]");
    if (badge && status) {
      badge.textContent = status;
      badge.setAttribute("data-fp-status", status);
    }
    if (!row.querySelector("[data-fp-question]:not(.is-answered)")) {
      row.querySelectorAll(".fp-dash-reason[data-reason='question']").forEach(function (chip) { chip.remove(); });
    }
  });
}

// OP#1722: Ein Sprung auf ein Ziel in der eingeklappten Statusleiste (#fp-tile-agents) klappt die Kachel auf.
(function () {
  function openFold() {
    var id = window.location.hash.slice(1);
    var target = id && document.getElementById(id);
    var fold = target && target.closest("details[data-fp-widget-fold]");
    if (fold) fold.open = true;
  }
  document.addEventListener("click", function (event) {
    var link = event.target.closest && event.target.closest("a[href^='#fp-tile-']");
    var target = link && document.getElementById(link.getAttribute("href").slice(1));
    var fold = target && target.closest("details[data-fp-widget-fold]");
    if (fold) fold.open = true;
  });
  window.addEventListener("hashchange", openFold);
  openFold();
})();

// OP#1708: Das Antwortformular steht im Widget „Rückfragen“ (Leser-Ansicht) und in den Zeilen von „Aufmerksamkeit“ (Admin);
// die Behandlung hängt deshalb am Dokument und greift auf jedes form[data-fp-question-form].
(function () {
  var widget = document.querySelector("[data-fp-widget='questions']");
  // Erst nach dem Laden der Stylesheets: vorher ist .fp-home-main noch kein Scrollbereich.
  if (widget && !window.location.hash && /[?&]rueckfragen=/.test(window.location.search)) {
    var reveal = function () { widget.scrollIntoView({ block: "start" }); };
    if (document.readyState === "complete") reveal();
    else window.addEventListener("load", reveal);
  }
  if (!document.querySelector("form[data-fp-question-form]")) return;
  if (typeof fetch !== "function" || typeof FormData !== "function") return;

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" || !(event.ctrlKey || event.metaKey)) return;
    var form = event.target.closest && event.target.closest("form[data-fp-question-form]");
    if (!form) return;
    event.preventDefault();
    form.requestSubmit(form.querySelector(".fp-q-send"));
  });

  document.addEventListener("submit", function (event) {
    var form = event.target.closest && event.target.closest("form[data-fp-question-form]");
    if (!form) return;
    event.preventDefault();
    var item = form.closest("[data-fp-question]");
    var note = item && item.querySelector("[data-fp-question-note]");
    var body = new FormData(form);
    var submitter = event.submitter;
    if (submitter && submitter.name) body.set(submitter.name, submitter.value);
    var buttons = form.querySelectorAll("button");
    buttons.forEach(function (button) { button.disabled = true; });
    // OP#1710: der gedrückte Knopf zeigt „Wird gesendet …“.
    var originalLabel = submitter ? submitter.textContent : null;
    if (submitter && item) submitter.textContent = item.getAttribute("data-fp-sending-text") || originalLabel;
    if (note) {
      note.classList.remove("is-error");
      note.setAttribute("role", "status");
      note.textContent = item.getAttribute("data-fp-sending-text") || "";
      note.hidden = false;
    }
    var token = form.querySelector("input[name='authenticity_token']");
    fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Accept": "application/json", "X-CSRF-Token": token ? token.value : "" },
      body: body
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (payload) {
        if (!response.ok || !payload.ok) throw { fpMessage: payload.error };
        fpMarkAnswered(form.getAttribute("data-fp-question-form"), payload.answer && payload.answer.message, payload.answer && payload.answer.status);
        window.dispatchEvent(new CustomEvent("fp:questions-changed", { detail: { items: payload.items || [] } }));
      });
    }).catch(function (error) {
      buttons.forEach(function (button) { button.disabled = false; });
      if (submitter && originalLabel !== null) submitter.textContent = originalLabel;
      if (!note) return;
      note.textContent = (error && error.fpMessage) || item.getAttribute("data-fp-failed-text") || "";
      note.classList.add("is-error");
      note.setAttribute("role", "alert");
      note.hidden = false;
    });
  });
})();
