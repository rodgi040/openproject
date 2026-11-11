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
vm.runInContext(`${ticketFn}\n${block}\nthis.api = { fpParseRequests, fpRespondMessage, fpParseResponded, fpShadowBody, fpEnterOption };`, ctx);
const { fpParseRequests, fpRespondMessage, fpParseResponded, fpShadowBody, fpEnterOption } = ctx.api;

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
assert.strictEqual(parse([question({ requestId: "" }), question({ requestId: 5 }), question({ requestId: "x".repeat(201) })]).items.length, 0);
assert.strictEqual(parse([question({ question: { text: "", options: [] } })]).items.length, 0);
assert.strictEqual(parse([approval({ approval: { detail: "  " } })]).items.length, 0);
assert.strictEqual(parse([question()], { threadId: 7 }).threadId, null);
assert.strictEqual(parse([question({ answerable: false })]).items[0].answerable, false);
assert.strictEqual(parse([question({ question: { ...question().question, multiSelect: true } })]).items[0].answerable, false);
assert.strictEqual(parse([approval({ approval: { detail: "x".repeat(20001), reason: null, tool: null } })]).items[0].answerable, false);
assert.strictEqual(parse(Array.from({ length: 30 }, (_, i) => question({ requestId: `r${i}` }))).items.length, 20);

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

// Schatten-Körper: nur bei gewählter Option und vorhandener Empfehlung
assert.deepStrictEqual({ ...fpShadowBody(parsed, q, "Nein") },
  { ticket: "12", request_id: "r1", recommended: "Ja (Recommended)", chosen: "Nein" });
assert.strictEqual(fpShadowBody(parsed, q, undefined), null, "free text sends nothing");
assert.strictEqual(fpShadowBody(parsed, a, "x"), null);
const noRec = parse([question({ question: { ...question().question, options: [{ label: "A", description: null, recommended: false }] } })]);
assert.strictEqual(fpShadowBody(noRec, noRec.items[0], "A"), null, "no recommendation, no row");

// Enter-Regel
assert.strictEqual(fpEnterOption("Ja", "true", ["Ja", "Nein"]), "Ja");
assert.strictEqual(fpEnterOption("Ja", "", ["Ja", "Nein"]), "Ja", "unknown reversibility still takes it");
assert.strictEqual(fpEnterOption("Ja", "false", ["Ja", "Nein"]), null, "not reversible: click only");
assert.strictEqual(fpEnterOption("", "true", ["Ja"]), null);
assert.strictEqual(fpEnterOption(undefined, "true", ["Ja"]), null);
assert.strictEqual(fpEnterOption("Ja", "true", ["Nein"]), null, "recommendation not among options");

console.log("requests_logic_test: ok");
