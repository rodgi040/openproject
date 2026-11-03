(function () {
  var directoryNode = document.getElementById("fp-agent-directory");
  var agents = {};
  if (directoryNode) {
    JSON.parse(directoryNode.textContent).forEach(function (row) {
      agents[String(row.id)] = row;
    });
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
    JSON.parse(openNode.textContent).forEach(function (row) {
      openQuestions[String(row.work_package_id)] = row.href;
    });
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
      window.dispatchEvent(new CustomEvent("fp:card-selected", {
        detail: {
          id: Number(card.dataset.id),
          project: card.dataset.project,
          subject: card.dataset.subject
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
