// OP#1842: Logik für fp:requests, fp:respond, fp:responded, den Schatten-Körper und die Enter-Regel, ohne Browser.
// Aufruf: node modules/flightplan/spec/javascripts/requests_logic_test.js
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(path.join(__dirname, "../../app/assets/flightplan/flightplan.js"), "utf8");
const ticketFn = source.match(/function fpTicketNumber[\s\S]*?\n}\n/)[0];
const block = source.match(/\/\/ FP-REQUESTS-BEGIN[\s\S]*?\/\/ FP-REQUESTS-END/)[0];
const ctx = {};
vm.createContext(ctx);
const activityFn = source.match(/function fpParseActivity[\s\S]*?\n}\n/)[0];
const priority = source.match(/var FP_RUN_PRIORITY = .*;/)[0];
vm.runInContext(`${ticketFn}\n${priority}\n${block}\n${activityFn}\nthis.api = { fpParseRequests, fpRespondMessage, fpParseResponded, fpShadowBody, fpEnterOption, fpVisibleDetail, fpParseActivity, fpRespondedAction };`, ctx);
const { fpParseRequests, fpRespondMessage, fpParseResponded, fpShadowBody, fpEnterOption, fpVisibleDetail, fpParseActivity, fpRespondedAction } = ctx.api;

const question = (extra = {}) => ({
  requestId: "r1", kind: "question", createdAt: "2026-11-11T10:00:00Z", answerable: true,
  question: { text: "Weiter?", multiSelect: false, options: [
    { label: "Ja (Recommended)", description: null, recommended: true }, { label: "Nein", description: "stop", recommended: false }] },
  ...extra,
});
const approval = (extra = {}) => ({
  requestId: "r2", kind: "approval", createdAt: "2026-11-11T10:00:00Z", answerable: true,
  approval: { detail: "rm -rf /tmp/x && echo '<b>hi</b>'", reason: "Aufräumen", tool: "bash" }, ...extra,
});
const parse = (items, extra = {}) => fpParseRequests({ type: "fp:requests", ticket: 12, threadId: "t-1", items, ...extra });

// fp:requests
let parsed = parse([question(), approval()]);
assert.strictEqual(parsed.ticket, 12);
assert.strictEqual(parsed.items.length, 2);
assert.strictEqual(parsed.items[0].question.options[0].recommended, true);
assert.strictEqual(parsed.items[1].approval.detail, "rm -rf /tmp/x && echo '<b>hi</b>'");
assert.strictEqual(fpParseRequests({ ticket: "x", items: [] }), null);
assert.strictEqual(fpParseRequests({ ticket: 12, items: "nope" }), null);
assert.strictEqual(parse([]).items.length, 0);
assert.strictEqual(parse([{ ...question(), kind: "plan" }]).items.length, 0, "unknown kind is ignored");
assert.strictEqual(parse([question({ requestId: "" }), question({ requestId: 5 }), question({ requestId: "x".repeat(1025) })]).items.length, 0);
const longId = "r".repeat(321);
assert.strictEqual(parse([question({ requestId: longId })]).items[0].requestId, longId, "real 321-character ids are accepted");
assert.strictEqual(parse([question({ requestId: "r".repeat(1024) })]).items.length, 1);
assert.strictEqual(parse([question()], { threadId: "t".repeat(300) }).threadId, "t".repeat(300));
assert.strictEqual(fpParseResponded({ ticket: 1, requestId: longId, result: "ok" }).requestId, longId);
assert.strictEqual(fpParseResponded({ ticket: 1, requestId: "r".repeat(1025), result: "ok" }), null);
assert.strictEqual(parse([question({ question: { text: "", options: [] } })]).items.length, 0);
assert.strictEqual(parse([approval({ approval: { detail: "  " } })]).items.length, 0);
assert.strictEqual(parse([question()], { threadId: 7 }).threadId, null);
assert.strictEqual(parse([question({ answerable: false })]).items[0].answerable, false);
assert.strictEqual(parse([question({ question: { ...question().question, multiSelect: true } })]).items[0].answerable, false);
assert.strictEqual(parse([approval({ approval: { detail: "x".repeat(20001), reason: null, tool: null } })]).items[0].answerable, false);
assert.strictEqual(parse(Array.from({ length: 30 }, (_, i) => question({ requestId: `r${i}` }))).items.length, 20);

// fp:activity v2 (live seit Phase 2a): threadIds bis 1024 Zeichen bleiben unverkürzt (früher auf 200 gekürzt)
for (const length of [36, 206, 1024]) {
  const id = "t".repeat(length);
  assert.strictEqual(fpParseActivity({ states: [{ ticket: 5, threadId: id, state: "approval" }] })[5].thread, id, `threadId ${length}`);
}
assert.strictEqual(fpParseActivity({ states: [{ ticket: 5, threadId: "t".repeat(1500), state: "input" }] })[5].thread.length, 1024);

// fp:respond
const [q, a] = parsed.items;
assert.deepStrictEqual({ ...fpRespondMessage(parsed, q, { optionLabel: "Ja (Recommended)" }) },
  { type: "fp:respond", ticket: 12, threadId: "t-1", requestId: "r1", kind: "question", optionLabel: "Ja (Recommended)" });
assert.strictEqual(fpRespondMessage(parsed, q, { optionLabel: "Vielleicht" }), null, "option must be offered");
assert.strictEqual(fpRespondMessage(parsed, q, { text: "   " }), null);
assert.strictEqual(fpRespondMessage(parsed, q, { text: "y".repeat(5000) }).text.length, 4000);
assert.strictEqual(fpRespondMessage(parsed, q, { decision: "accept" }), null);
assert.strictEqual(fpRespondMessage(parsed, a, { decision: "accept" }).decision, "accept");
assert.strictEqual(fpRespondMessage(parsed, a, { decision: "decline" }).detail, "rm -rf /tmp/x && echo '<b>hi</b>'", "approval carries the shown detail unchanged");
assert.strictEqual(fpRespondMessage(parsed, q, { optionLabel: "Nein" }).detail, undefined);
assert.strictEqual(fpRespondMessage(parsed, { ...a, answerable: false }, { decision: "accept" }), null, "non-shell approvals have no buttons");
assert.strictEqual(fpRespondMessage(parsed, a, { decision: "acceptForSession" }), null, "no session-wide approval");
assert.strictEqual(fpRespondMessage(parsed, a, { optionLabel: "Ja" }), null);
assert.strictEqual(fpRespondMessage(parse([question()], { threadId: null }), q, { optionLabel: "Nein" }), null, "no thread");
assert.strictEqual(fpRespondMessage(parsed, { ...q, answerable: false }, { optionLabel: "Nein" }), null, "not answerable");

// fp:responded
assert.deepStrictEqual({ ...fpParseResponded({ ticket: 12, requestId: "r1", result: "gone" }) }, { ticket: 12, requestId: "r1", result: "gone" });
assert.strictEqual(fpParseResponded({ ticket: 12, requestId: "r1", result: "maybe" }), null);
assert.strictEqual(fpParseResponded({ ticket: 0, requestId: "r1", result: "ok" }), null);
assert.strictEqual(fpParseResponded({ ticket: 1, requestId: "", result: "ok" }), null);

// Täuschende Zeichen im Befehl: keine Knöpfe, sichtbar ersetzt
for (const ch of ["\u202E", "\u2066", "\u200B", "\u200F", "\u2060", "\uFEFF", "\u0007", "\r", "\u007F", "\u0085"]) {
  const det = `ls ${ch}-la`;
  const p = parse([approval({ approval: { detail: det, reason: null, tool: null } })]);
  assert.strictEqual(p.items[0].answerable, false, `U+${ch.charCodeAt(0).toString(16)} blocks the buttons`);
  assert.ok(!/[\u202E\u2066\u200B\u200F\u2060\uFEFF\u0007\r\u007F\u0085]/.test(fpVisibleDetail(det)));
  assert.ok(fpVisibleDetail(det).includes("<U+"));
}
assert.strictEqual(parse([approval({ approval: { detail: "a\tb\nc", reason: null, tool: null } })]).items[0].answerable, true, "tab and newline are fine");
assert.strictEqual(fpVisibleDetail("x\u202Ey"), "x<U+202E>y");

// verworfene Optionen
const dropped = (label) => parse([question({ question: { text: "T", multiSelect: false, options: [
  { label: "ok", description: null, recommended: false }, { label, description: null, recommended: false }] } })]).items[0];
assert.strictEqual(dropped("").answerable, false);
assert.strictEqual(dropped("x".repeat(501)).answerable, false);
assert.strictEqual(dropped("fine").answerable, true);

// fp:responded: nur ok beendet die Zeile; gone lässt sie stehen und lädt den Stand neu (fp:requests-get); error lässt sie stehen
assert.deepStrictEqual({ ...fpRespondedAction("ok") }, { finish: true, refetch: false, note: "answered" });
assert.deepStrictEqual({ ...fpRespondedAction("gone") }, { finish: false, refetch: true, note: "gone" });
assert.deepStrictEqual({ ...fpRespondedAction("error") }, { finish: false, refetch: false, note: "failed" });

// Schatten-Körper: nur bei gewählter Option und vorhandener Empfehlung
assert.deepStrictEqual({ ...fpShadowBody(parsed, q, "Nein") },
  { ticket: "12", request_id: "r1", recommended: "Ja (Recommended)", chosen: "Nein" });
assert.strictEqual(fpShadowBody(parsed, q, undefined), null, "free text sends nothing");
assert.strictEqual(fpShadowBody(parsed, a, "x"), null);
const noRec = parse([question({ question: { ...question().question, options: [{ label: "A", description: null, recommended: false }] } })]);
assert.strictEqual(fpShadowBody(noRec, noRec.items[0], "A"), null, "no recommendation, no row");

// Enter-Regel
assert.strictEqual(fpEnterOption("Ja", "true", ["Ja", "Nein"]), "Ja");
assert.strictEqual(fpEnterOption("Ja", "", ["Ja", "Nein"]), null, "unknown reversibility: Enter does nothing");
assert.strictEqual(fpEnterOption("Ja", "false", ["Ja", "Nein"]), null, "not reversible: click only");
assert.strictEqual(fpEnterOption("Ja", "true", ["Ja", "Nein"], "entscheidung"), "Ja");
assert.strictEqual(fpEnterOption("Ja", "true", ["Ja", "Nein"], ""), "Ja", "empty kind is fine");
for (const kind of ["freigabe", "zugang", "abnahme", "auto"]) {
  assert.strictEqual(fpEnterOption("Ja", "true", ["Ja", "Nein"], kind), null, `kind ${kind}: click only`);
}
assert.strictEqual(fpEnterOption("", "true", ["Ja"]), null);
assert.strictEqual(fpEnterOption(undefined, "true", ["Ja"]), null);
assert.strictEqual(fpEnterOption("Ja", "true", ["Nein"]), null, "recommendation not among options");

console.log("requests_logic_test: ok");
