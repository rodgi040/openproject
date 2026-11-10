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

// OP#1711 Welle 2: neue Ereignisse an die bekannten anfügen, ohne Dubletten. Die Id trägt den Inhalt (c12-ab12cd34,
// s12-3-4); der Teil vor dem "-" ist der Schlüssel der Zeile. Gleiche Id = Wiederholung; gleicher Schlüssel mit neuer
// Id (OP fasst Journale zusammen, z. B. zweiter Statuswechsel im selben Journal) ersetzt die ältere Zeile.
function fpMergeEvents(known, incoming) {
  var byKey = {};
  var order = [];
  (known || []).concat(incoming || []).forEach(function (event) {
    if (!event || !event.id) return;
    var key = String(event.id).split("-")[0];
    if (!(key in byKey)) order.push(key);
    byKey[key] = event;
  });
  var merged = order.map(function (key) { return byKey[key]; });
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
  var eventCursor = { journal: 0, journal_at: "", question: 0, question_at: "" };
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
      eventCursor = { journal: 0, journal_at: "", question: 0, question_at: "" };
    }
    eventsBusy = true;
    var query = "wp=" + id + (eventCursor.journal ? "&after=" + eventCursor.journal : "") +
      (eventCursor.journal_at ? "&after_at=" + encodeURIComponent(eventCursor.journal_at) : "") +
      (eventCursor.question ? "&after_question=" + eventCursor.question : "") +
      (eventCursor.question_at ? "&after_question_at=" + encodeURIComponent(eventCursor.question_at) : "");
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
        var before = JSON.stringify(eventList);
        eventList = fpMergeEvents(eventList, result.payload.events);
        var cursor = result.payload.cursor || {};
        eventCursor = {
          journal: Number(cursor.journal) || eventCursor.journal,
          journal_at: String(cursor.journal_at || eventCursor.journal_at || ""),
          question: Number(cursor.question) || eventCursor.question,
          question_at: String(cursor.question_at || eventCursor.question_at || "")
        };
        if (JSON.stringify(eventList) !== before || before === "[]") sendEvents();
      })
      .catch(function () {
        eventsBusy = false;
      });
  }

  // OP#1778: Auf der Startseite gehören Rückfragen nur zum gewählten Ticket in den Chat; ohne Ticket zeigt T3 nichts
  // Ticketbezogenes (beantwortet werden sie links im Widget „Rückfragen“).
  function frameQuestions() {
    if (!bar) return questions;
    var id = wp && Number(wp.id);
    return id ? questions.filter(function (item) { return Number(item.work_package_id) === id; }) : [];
  }

  // OP#1784: Thread, den T3 für das Ticket gemeldet hat; fp:context trägt ihn mit, T3 bindet den Kontext genau daran.
  var wpThread = null;

  function contextMessage() {
    var message = { type: "fp:context", wp: wp };
    if (wpThread && Number(wpThread.id) === Number(wp.id)) message.threadId = wpThread.thread;
    return message;
  }

  function sendState() {
    if (wp && wp.id) post(contextMessage());
    post({ type: "fp:questions", items: frameQuestions() });
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
    if (data.type === "fp:thread" && bar) {
      // OP#1778 Teil 2: T3 meldet den offenen Thread (Wechsel in der Thread-Leiste); links zieht die Markierung nach.
      // OP#1784: Die Ticketnummer hat T3 gegen die Server-Zuordnung geprüft; das Dashboard liefert den Kontext für genau
      // diesen Thread nach (fp:context mit threadId). Kennt es das Ticket nicht, bleibt die Kopfleiste in T3 weg.
      var shown = Number(data.ticketId) > 0 ? Number(data.ticketId) : 0;
      var thread = typeof data.threadId === "string" ? data.threadId : null;
      shownTicket = shown;
      if (shown) {
        if (!wp || Number(wp.id) !== shown) {
          var known = document.querySelector("[data-fp-chat-ticket='" + shown + "'], [data-fp-worklist-row][data-id='" + shown + "']");
          wp = { id: shown, subject: known ? known.dataset.subject : "" };
        }
        markActive(shown);
        loadContext(shown, thread);
      } else {
        wp = {};
        wpThread = null;
        markActive(null, !!thread);
        sendState();
      }
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
    // OP#1778: Zeilen der Arbeitsliste (reveal) holen den Chat dazu in den Blick.
    if (bar) {
      openTicket(detail.id, detail.subject, true);
      // OP#1784: im schmalen Fenster wechselt auch eine Board-Karte auf den Reiter „T3 Code“.
      window.dispatchEvent(new CustomEvent("fp:home-show-chat", { detail: { narrowOnly: !detail.reveal } }));
    } else {
      post({ type: "fp:context", wp: wp });
    }
  });

  // OP#1711/OP#1778: Ticketauswahl der Startseite (links im Dashboard, nicht mehr über dem iframe). Ein Klick lädt
  // /chat/embed/<id>?layout=full (T3 holt oder legt den Thread je Ticket an, idempotent, und zeigt ihn mit Seitenleiste);
  // "Neuer Chat" lädt /chat/?layout=full. Titel sind untrusted und gelangen nur per textContent in die Seite.
  var bar = root.id === "fp-home-chat" ? document.querySelector("[data-fp-chat-tickets]") : null;
  var layout = bar ? "?layout=full" : "";
  var recentKey = "fp-chat-recent-tickets";

  function readRecent() {
    try {
      var list = JSON.parse(window.localStorage.getItem(recentKey) || "[]");
      return Array.isArray(list) ? list.filter(function (item) { return item && Number(item.id) > 0; }).slice(0, 5) : [];
    } catch (error) {
      return [];
    }
  }

  function markActive(id, free) {
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
      var text = id ? "#" + Number(id) + (current && current.dataset.subject ? " " + current.dataset.subject : (wp && wp.subject ? " " + wp.subject : "")) : (free ? label.dataset.free : label.dataset.new);
      label.textContent = label.dataset.prefix + ": " + text;
    }
    // OP#1778: die Arbeitsliste markiert dieselbe Zeile (eine Stelle für den aktiven Stand).
    window.dispatchEvent(new CustomEvent("fp:chat-active", { detail: { id: id ? Number(id) : null } }));
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
      link.href = origin + "/chat/embed/" + Number(item.id) + layout;
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
  var loading = (bar || root).querySelector("[data-fp-chat-loading]");
  function showLoading(url) {
    if (!loading) return;
    var match = /\/embed\/(\d+)(?:\?|$)/.exec(url);
    if (!match) {
      loading.hidden = true;
      return;
    }
    loading.textContent = (loading.dataset.template || "").replace("__ID__", match[1]);
    loading.hidden = false;
  }
  if (frame && loading) frame.addEventListener("load", function () { loading.hidden = true; });

  // OP#1778: Ticket, das T3 zuletzt per fp:thread gemeldet hat (0 = ohne Ticket, null = keine Meldung). Nach einem
  // Wechsel in der T3-Thread-Leiste ist das src-Attribut veraltet; dann lädt dieselbe Adresse neu.
  var shownTicket = null;
  function loadFrame(url) {
    frame.dataset.src = url;
    // Chat nicht erreichbar (kein src): "Neu laden" lädt danach den gewählten Thread.
    if (!frame.getAttribute("src")) return;
    var wanted = /\/embed\/(\d+)/.exec(url);
    var stale = shownTicket !== null && shownTicket !== (wanted ? Number(wanted[1]) : 0);
    if (frame.getAttribute("src") === url && !stale) {
      sendState();
      return;
    }
    showLoading(url);
    frame.src = url;
  }

  function openTicket(id, subject, fromBoard) {
    if (!bar || !frame || !Number(id)) return;
    if (!fromBoard || !wp || Number(wp.id) !== Number(id)) wp = { id: Number(id), subject: subject };
    wpThread = null;
    markActive(id);
    rememberTicket(id, subject);
    loadFrame(origin + "/chat/embed/" + Number(id) + layout);
    loadContext(id, null);
    if (!fromBoard) window.dispatchEvent(new CustomEvent("fp:home-show-chat"));
  }

  // OP#1784: voller Kontext (Typ, Priorität, Zuweisung, Status wie links) für die Kopfleiste in T3. Nur offene,
  // sichtbare Tickets; sonst kommt kein fp:context.
  var contextSeq = 0;
  function loadContext(id, thread) {
    var seq = ++contextSeq;
    fetch("/flightplan/chat/context?wp=" + encodeURIComponent(Number(id)), {
      headers: { "Accept": "application/json" },
      credentials: "same-origin"
    }).then(function (response) {
      return response.ok ? response.json() : null;
    }).then(function (payload) {
      if (seq !== contextSeq || !payload || !payload.ok || !payload.wp) return;
      if (!wp || Number(wp.id) !== Number(id) || Number(payload.wp.id) !== Number(id)) return;
      wp = payload.wp;
      if (thread) wpThread = { id: Number(id), thread: thread };
      markStatus(wp);
      sendState();
    }).catch(function () {});
  }

  // OP#1784: die Zeile des aktiven Tickets links zeigt denselben Status wie die Kopfleiste in T3.
  function markStatus(context) {
    var label = context.status_label || context.status;
    if (!label) return;
    bar.querySelectorAll("[data-fp-chat-ticket='" + Number(context.id) + "']").forEach(function (node) {
      var pill = node.querySelector(".fp-chat-ticket-status");
      if (!pill) {
        pill = document.createElement("span");
        node.appendChild(pill);
      }
      pill.className = "fp-chat-ticket-status fp-chat-ticket-status-" + String(context.status_key || "other").replace(/[^a-z]/g, "");
      pill.textContent = label;
    });
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
        wpThread = null;
        contextSeq++;
        markActive(null);
        loadFrame(origin + "/chat/" + layout);
        window.dispatchEvent(new CustomEvent("fp:home-show-chat"));
      } else if (more) {
        var open = more.getAttribute("aria-expanded") !== "true";
        bar.querySelectorAll("li[data-fp-chat-more]").forEach(function (node) { node.hidden = !open; });
        more.setAttribute("aria-expanded", open ? "true" : "false");
        more.textContent = open ? more.dataset.less : more.dataset.label;
      }
    });
    // OP#1778 Teil 2: „Nächstes ▸“ (Taste .) nimmt das nächste Ticket der sichtbaren Liste: Arbeitsliste, sonst die
    // Ticketauswahl. Die Reihenfolge ist die angezeigte.
    function nextTicket() {
      var rows = Array.prototype.slice.call(document.querySelectorAll("[data-fp-left-view='worklist']:not([hidden]) [data-fp-wl-panel]:not([hidden]) [data-fp-worklist-row]:not([hidden])"));
      if (!rows.length) rows = Array.prototype.slice.call(bar.querySelectorAll("[data-fp-chat-ticket-list] [data-fp-chat-ticket]"));
      if (!rows.length) return;
      var ids = rows.map(function (node) { return Number(node.dataset.id || node.dataset.fpChatTicket); });
      var at = ids.indexOf(Number(wp && wp.id));
      var pick = rows[(at + 1) % rows.length];
      openTicket(ids[(at + 1) % rows.length], pick.dataset.subject);
    }
    var next = bar.querySelector("[data-fp-chat-next]");
    if (next) next.addEventListener("click", nextTicket);
    window.addEventListener("fp:chat-next", nextTicket);
    window.addEventListener("fp:chat-new", function () {
      var fresh = bar.querySelector("[data-fp-chat-new]");
      if (fresh) fresh.click();
    });
    var moreButton = bar.querySelector("[data-fp-chat-more-toggle]");
    if (moreButton) moreButton.dataset.label = moreButton.textContent.trim();
    renderRecent();
  }
}

// OP#1778: Split-Screen der Startseite. Ansicht (Dashboard groß / geteilt / T3 Code groß), Breite der linken Fläche,
// Reiter im schmalen Fenster und das OpenProject-Menü als Symbolleiste. Zustand nur im localStorage dieses Browsers.
function fpHomeSplit(home) {
  var KEYS = { view: "fp-home-view", tab: "fp-home-tab", split: "fp-home-split", menu: "fp-home-menu" };
  var VIEWS = ["dashboard", "split", "chat"];
  var NARROW_BELOW = 1300;
  var RAIL_BELOW = 1700;
  var MIN_LEFT = 288;
  var MIN_RIGHT = 384;
  var handle = home.querySelector("[data-fp-split-handle]");
  var hint = home.querySelector("[data-fp-view-hint]");
  var views = home.querySelector("[data-fp-views]");
  var tabs = home.querySelector("[data-fp-tabs]");
  var mainMenu = document.getElementById("main");

  function read(key) {
    try { return window.localStorage.getItem(key); } catch (error) { return null; }
  }
  function write(key, value) {
    try {
      if (value === null) window.localStorage.removeItem(key);
      else window.localStorage.setItem(key, value);
    } catch (error) { /* ohne Speicher gilt der Standard */ }
  }

  var state = {
    view: VIEWS.indexOf(read(KEYS.view)) === -1 ? "split" : read(KEYS.view),
    tab: read(KEYS.tab) === "chat" ? "chat" : "dashboard",
    split: Number(read(KEYS.split)) > 0 && Number(read(KEYS.split)) < 1 ? Number(read(KEYS.split)) : 0.5,
    narrow: false
  };

  function width() {
    return home.getBoundingClientRect().width || 1;
  }
  function clampSplit(value) {
    var total = width();
    var min = Math.min(0.5, MIN_LEFT / total);
    var max = Math.max(0.5, 1 - MIN_RIGHT / total);
    return Math.min(max, Math.max(min, value));
  }

  function railWanted() {
    if (!mainMenu || mainMenu.classList.contains("hidden-navigation") || window.innerWidth < 1012) return false;
    if (read(KEYS.menu) === "open") return false;
    if (window.innerWidth >= RAIL_BELOW && !state.narrow) return false;
    return state.narrow ? true : state.view !== "dashboard";
  }

  // OpenProject merkt sich Breite und Zustand seines Menüs im localStorage und misst beim ersten Start die aktuelle
  // Breite. Die Symbolleiste darf diesen Wert nie werden: ohne gemerkten Wert gilt der OpenProject-Standard 280 px.
  var OP_WIDTH = "openProject-mainMenuWidth";
  var OP_COLLAPSED = "openProject-mainMenuCollapsed";
  var opMenu = { width: read(OP_WIDTH), collapsed: read(OP_COLLAPSED) };
  if (!(Number(opMenu.width) >= 120)) {
    opMenu.width = "280";
    write(OP_WIDTH, opMenu.width);
  }
  function keepOpMenu() {
    if (Number(read(OP_WIDTH)) < 120 && opMenu.width) write(OP_WIDTH, opMenu.width);
    if (opMenu.collapsed !== null && read(OP_COLLAPSED) !== opMenu.collapsed) write(OP_COLLAPSED, opMenu.collapsed);
  }
  window.addEventListener("pagehide", keepOpMenu);

  var menuToggle = null;
  function syncMenu() {
    if (!mainMenu) return;
    var rail = railWanted();
    keepOpMenu();
    mainMenu.classList.toggle("fp-menu-rail", rail);
    var top = mainMenu.querySelector(".main-menu--top-container");
    if (!top) return;
    if (!menuToggle) {
      menuToggle = document.createElement("button");
      menuToggle.type = "button";
      menuToggle.className = "fp-menu-toggle";
      menuToggle.setAttribute("data-fp-menu-toggle", "1");
      menuToggle.innerHTML = '<svg aria-hidden="true" viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M2 3.75A1.75 1.75 0 0 1 3.75 2h8.5A1.75 1.75 0 0 1 14 3.75v8.5A1.75 1.75 0 0 1 12.25 14h-8.5A1.75 1.75 0 0 1 2 12.25Zm1.75-.25a.25.25 0 0 0-.25.25v8.5c0 .138.112.25.25.25H6v-9Zm3.75 0v9h4.75a.25.25 0 0 0 .25-.25v-8.5a.25.25 0 0 0-.25-.25Z"/></svg>';
      menuToggle.addEventListener("click", function () {
        write(KEYS.menu, mainMenu.classList.contains("fp-menu-rail") ? "open" : null);
        syncMenu();
      });
      top.insertBefore(menuToggle, top.firstChild);
    }
    var label = rail ? home.dataset.menuRail : home.dataset.menuUnrail;
    menuToggle.setAttribute("aria-label", label);
    menuToggle.title = label;
    menuToggle.hidden = !rail && read(KEYS.menu) !== "open";
  }

  function apply() {
    state.narrow = window.innerWidth < NARROW_BELOW;
    home.dataset.fpNarrow = state.narrow ? "1" : "0";
    home.dataset.fpView = state.view;
    home.dataset.fpTab = state.tab;
    if (views) {
      views.hidden = state.narrow;
      views.querySelectorAll("[data-fp-view-set]").forEach(function (button) {
        button.setAttribute("aria-pressed", button.dataset.fpViewSet === state.view ? "true" : "false");
      });
    }
    if (tabs) {
      tabs.hidden = !state.narrow;
      tabs.querySelectorAll("[data-fp-tab]").forEach(function (button) {
        var on = button.dataset.fpTab === state.tab;
        button.setAttribute("aria-selected", on ? "true" : "false");
        button.tabIndex = on ? 0 : -1;
      });
    }
    if (hint) hint.textContent = state.narrow ? hint.dataset.narrow : hint.dataset.split;
    var value = clampSplit(state.split);
    home.style.setProperty("--fp-split", (value * 100).toFixed(2) + "%");
    if (handle) {
      var percent = Math.round(value * 100);
      handle.setAttribute("aria-valuenow", String(percent));
      handle.setAttribute("aria-valuetext", "Dashboard " + percent + " %, T3 Code " + (100 - percent) + " %");
    }
    syncMenu();
  }

  function setView(view) {
    if (VIEWS.indexOf(view) === -1) return;
    state.view = view;
    write(KEYS.view, view);
    apply();
  }
  function setTab(tab) {
    state.tab = tab === "chat" ? "chat" : "dashboard";
    write(KEYS.tab, state.tab);
    apply();
  }
  function setSplit(value, persist) {
    state.split = clampSplit(value);
    if (persist) write(KEYS.split, state.split.toFixed(4));
    apply();
  }

  if (views) {
    views.addEventListener("click", function (event) {
      var button = event.target.closest("[data-fp-view-set]");
      if (button) setView(button.dataset.fpViewSet);
    });
  }
  if (tabs) {
    tabs.addEventListener("click", function (event) {
      var button = event.target.closest("[data-fp-tab]");
      if (button) setTab(button.dataset.fpTab);
    });
    tabs.addEventListener("keydown", function (event) {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      setTab(state.tab === "chat" ? "dashboard" : "chat");
      var current = tabs.querySelector("[aria-selected='true']");
      if (current) current.focus();
    });
  }
  home.querySelectorAll("[data-fp-strip]").forEach(function (strip) {
    strip.addEventListener("click", function () { setView("split"); });
  });

  if (handle) {
    handle.addEventListener("pointerdown", function (event) {
      if (event.button !== 0) return;
      event.preventDefault();
      handle.setPointerCapture(event.pointerId);
      home.classList.add("is-dragging");
      var left = home.getBoundingClientRect().left;
      function move(next) {
        setSplit((next.clientX - left) / width(), false);
      }
      function up() {
        handle.removeEventListener("pointermove", move);
        handle.removeEventListener("pointerup", up);
        handle.removeEventListener("pointercancel", up);
        home.classList.remove("is-dragging");
        write(KEYS.split, state.split.toFixed(4));
      }
      handle.addEventListener("pointermove", move);
      handle.addEventListener("pointerup", up);
      handle.addEventListener("pointercancel", up);
    });
    handle.addEventListener("dblclick", function () {
      write(KEYS.split, null);
      setSplit(0.5, false);
    });
    handle.addEventListener("keydown", function (event) {
      var step = event.shiftKey ? 0.1 : 0.02;
      var next = null;
      if (event.key === "ArrowLeft") next = state.split - step;
      else if (event.key === "ArrowRight") next = state.split + step;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = 1;
      else if (event.key === "Enter") next = 0.5;
      if (next === null) return;
      event.preventDefault();
      setSplit(next, true);
    });
  }

  document.addEventListener("keydown", function (event) {
    if (!event.altKey || event.ctrlKey || event.metaKey) return;
    var view = { "1": "dashboard", "2": "split", "3": "chat" }[event.key];
    if (!view) return;
    event.preventDefault();
    if (state.narrow) setTab(view === "chat" ? "chat" : "dashboard");
    else setView(view);
  });

  // Auswahl eines Tickets oder „Neuer Chat“ links: der Chat wird sichtbar, falls er gerade eingeklappt ist.
  window.addEventListener("fp:home-show-chat", function (event) {
    var narrowOnly = !!(event.detail && event.detail.narrowOnly);
    if (state.narrow) setTab("chat");
    else if (!narrowOnly && state.view === "dashboard") setView("split");
  });

  var resizeTimer = null;
  window.addEventListener("resize", function () {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(apply, 80);
  });
  if (mainMenu && typeof MutationObserver === "function") {
    new MutationObserver(function () {
      var rail = railWanted();
      if (mainMenu.classList.contains("fp-menu-rail") !== rail) syncMenu();
    }).observe(mainMenu, { attributes: true, attributeFilter: ["class"] });
  }
  apply();
}

// OP#1778 Teil 2: Arbeitsliste (zweite Ansicht der linken Fläche) und Umschalter Board | Arbeitsliste. Zeilen sind
// Karten des Boards; ein Klick oder ↵ nimmt das Ticket in den Chat (fp:card-selected), die Nummer oder o öffnet den
// Arbeitsplatz. Filter und Suche wirken auf die geladenen Zeilen (wie das Board, 200 je Spalte).
function fpWorklist(main) {
  var views = main.querySelector("[data-fp-left-views]");
  var list = main.querySelector("[data-fp-worklist]");
  if (!views || !list) return;
  var KEY = "fp-home-left";
  var tabs = Array.prototype.slice.call(list.querySelectorAll("[data-fp-wl-tab]"));
  var search = list.querySelector("[data-fp-wl-search]");
  var project = list.querySelector("[data-fp-wl-project]");
  var nohit = list.querySelector("[data-fp-wl-nohit]");

  function stored() {
    try { return window.localStorage.getItem(KEY); } catch (error) { return null; }
  }
  function setLeft(view, persist) {
    var on = view === "worklist" ? "worklist" : "board";
    main.querySelectorAll("[data-fp-left-view]").forEach(function (node) { node.hidden = node.dataset.fpLeftView !== on; });
    views.querySelectorAll("[data-fp-left-set]").forEach(function (button) {
      button.setAttribute("aria-pressed", button.dataset.fpLeftSet === on ? "true" : "false");
    });
    main.dataset.fpLeft = on;
    if (persist) {
      try { window.localStorage.setItem(KEY, on); } catch (error) { /* ohne Speicher gilt Board */ }
    }
  }
  views.addEventListener("click", function (event) {
    var button = event.target.closest("[data-fp-left-set]");
    if (button) setLeft(button.dataset.fpLeftSet, true);
  });

  function panel() {
    return list.querySelector("[data-fp-wl-panel]:not([hidden])");
  }
  function setTab(name) {
    tabs.forEach(function (tab) {
      var on = tab.dataset.fpWlTab === name;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
    });
    list.querySelectorAll("[data-fp-wl-panel]").forEach(function (node) { node.hidden = node.dataset.fpWlPanel !== name; });
    applyFilter();
  }
  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () { setTab(tab.dataset.fpWlTab); });
  });

  function filtering() {
    return !!((search && search.value.trim()) || (project && project.value));
  }
  function applyFilter() {
    var text = search ? search.value.trim().toLowerCase() : "";
    var scope = project ? project.value : "";
    var hits = 0;
    list.querySelectorAll("[data-fp-wl-group]").forEach(function (group) {
      var expanded = group.querySelector("[data-fp-wl-all][aria-expanded='true']");
      group.querySelectorAll("[data-fp-worklist-row]").forEach(function (row) {
        var match = (!text || row.dataset.search.indexOf(text) !== -1) && (!scope || row.dataset.project === scope);
        var limited = row.hasAttribute("data-fp-wl-more") && !expanded && !filtering();
        row.hidden = !match || limited;
        if (match && group.closest("[data-fp-wl-panel]") === panel()) hits += 1;
      });
    });
    if (nohit) nohit.hidden = !filtering() || hits > 0 || !panel() || panel().dataset.fpWlPanel === "projekte";
  }
  if (search) search.addEventListener("input", applyFilter);
  if (project) project.addEventListener("change", applyFilter);

  list.addEventListener("click", function (event) {
    var all = event.target.closest("[data-fp-wl-all]");
    if (all) {
      var open = all.getAttribute("aria-expanded") !== "true";
      all.setAttribute("aria-expanded", open ? "true" : "false");
      all.textContent = open ? all.dataset.less : all.dataset.more;
      applyFilter();
      return;
    }
    var pick = event.target.closest("[data-fp-wl-pick-project]");
    if (pick) {
      if (project) project.value = pick.dataset.fpWlPickProject;
      setTab("fuer_dich");
      return;
    }
    var row = event.target.closest("[data-fp-worklist-row]");
    if (!row || event.target.closest("a, button")) return;
    openRow(row);
  });

  function openRow(row) {
    row.focus();
    window.dispatchEvent(new CustomEvent("fp:card-selected", {
      detail: {
        id: Number(row.dataset.id),
        subject: row.dataset.subject,
        project: row.dataset.project,
        status: row.dataset.status,
        labels: fpParseList(row.dataset.labels),
        url: row.dataset.url,
        reveal: true
      }
    }));
  }

  function rows() {
    var current = panel();
    return current ? Array.prototype.slice.call(current.querySelectorAll("[data-fp-worklist-row]:not([hidden])")) : [];
  }
  function move(step) {
    var all = rows();
    if (!all.length) return;
    var at = all.indexOf(document.activeElement);
    var next = all[Math.min(all.length - 1, Math.max(0, at === -1 ? 0 : at + step))];
    next.focus();
    next.scrollIntoView({ block: "nearest" });
  }

  document.addEventListener("keydown", function (event) {
    if (list.closest("[hidden]") || event.altKey || event.ctrlKey || event.metaKey) return;
    var target = event.target;
    var typing = target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
    if (typing) {
      if (event.key === "Escape" && target === search) {
        search.value = "";
        applyFilter();
        search.blur();
      }
      return;
    }
    var row = target && target.closest ? target.closest("[data-fp-worklist-row]") : null;
    var key = event.key;
    if (key === "j" || key === "ArrowDown") move(1);
    else if (key === "k" || key === "ArrowUp") move(-1);
    else if (key === "Enter" && row) openRow(row);
    else if (key === "o" && row) window.location.href = row.querySelector(".fp-wl-id").href;
    else if (key === ".") window.dispatchEvent(new CustomEvent("fp:chat-next"));
    else if (key === "c") window.dispatchEvent(new CustomEvent("fp:chat-new"));
    else if (key === "/" && search) search.focus();
    else if (/^[1-4]$/.test(key) && tabs[Number(key) - 1]) setTab(tabs[Number(key) - 1].dataset.fpWlTab);
    else return;
    event.preventDefault();
  });

  window.addEventListener("fp:chat-active", function (event) {
    var id = event.detail && event.detail.id;
    list.querySelectorAll("[data-fp-worklist-row]").forEach(function (row) {
      if (id && Number(row.dataset.id) === Number(id)) row.setAttribute("aria-current", "true");
      else row.removeAttribute("aria-current");
    });
  });

  setLeft(stored() === "worklist" ? "worklist" : "board", false);
  applyFilter();
}

(function () {
  var workplace = document.getElementById("fp-workplace");
  if (workplace) fpMountChat(workplace, workplace.querySelector("[data-fp-workplace-frame]"));
  var home = document.getElementById("fp-home-chat");
  if (home) fpMountChat(home, home.querySelector("[data-fp-home-frame]"));
  var split = document.querySelector("#fp-home[data-fp-chat='1']");
  if (split) fpHomeSplit(split);
  var main = document.querySelector("#fp-home[data-fp-chat='1'] > .fp-home-main");
  if (main) fpWorklist(main);
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
