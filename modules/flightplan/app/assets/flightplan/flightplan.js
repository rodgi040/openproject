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

// Chat iframe of the workplace (#fp-workplace) and of the home screen (#fp-home-chat, OP#1671).
function fpMountChat(root, frame) {
  var origin = "http://localhost:8092";
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
    if (wp && wp.id) post({ type: "fp:context", wp: wp });
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
  var reset = tools.querySelector("[data-fp-filter-reset]");
  var count = widget.querySelector("[data-fp-widget-count]");
  var none = widget.querySelector("[data-fp-widget-none]");

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
    var active = words.length > 0 || !!scopeValue || !!statusValue || labelsOn;
    var shown = 0;
    items.forEach(function (item) {
      var itemLabels = fpParseList(item.getAttribute("data-fp-labels"));
      var ok = true;
      if (words.length) {
        var haystack = fpNormalize(item.textContent + " " + itemLabels.join(" "));
        ok = words.every(function (word) { return haystack.indexOf(word) !== -1; });
      }
      if (ok && scopeValue) ok = matchScope(item, scopeValue);
      if (ok && statusValue) ok = fpParseList(item.getAttribute("data-fp-statuses")).indexOf(statusValue) !== -1;
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
      if (badge) badge.textContent = active ? visible + " / " + all : String(all);
    });
    if (count) count.textContent = active ? shown + " / " + items.length : String(items.length);
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
      labels.reset();
      apply();
      if (text) text.focus();
    });
  }
  var labelBox = tools.querySelector("[data-fp-filter='labels']");
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
