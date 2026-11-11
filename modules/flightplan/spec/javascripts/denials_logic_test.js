// OP#1890: Logik für das Feld `denials` von fp:activity (Sperren-Zähler), ohne Browser.
// Aufruf: node modules/flightplan/spec/javascripts/denials_logic_test.js
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(path.join(__dirname, "../../app/assets/flightplan/flightplan.js"), "utf8");
const ticketFn = source.match(/function fpTicketNumber[\s\S]*?\n}\n/)[0];
const block = source.match(/\/\/ FP-DENIALS-BEGIN[\s\S]*?\/\/ FP-DENIALS-END/)[0];
const activityFn = source.match(/function fpParseActivity[\s\S]*?\n}\n/)[0];
const priority = source.match(/var FP_RUN_PRIORITY = .*;/)[0];
const idMax = source.match(/var FP_REQ_ID_MAX = .*;/)[0];
const ctx = {};
vm.createContext(ctx);
vm.runInContext(`${ticketFn}\n${priority}\n${idMax}\n${block}\n${activityFn}\nthis.api = { fpParseDenials, fpDenialAttention, fpDenialPillText, fpDenialCategoryLabel, fpDenialRowVisible, fpParseActivity };`, ctx);
const { fpParseDenials, fpDenialAttention, fpDenialPillText, fpDenialCategoryLabel, fpDenialRowVisible, fpParseActivity } = ctx.api;

// Ergebnisse stammen aus einem vm-Kontext (andere Prototypen): vor dem Vergleich über JSON in diese Welt holen.
const plain = (value) => JSON.parse(JSON.stringify(value));
const entry = (extra = {}) => ({ count: 2, protected: false, maxInThread: 2, lastCategory: "sudo", ...extra });

// Parsen: gültige Einträge, Grenzen
let parsed = fpParseDenials({ type: "fp:activity", v: 2, denials: { "1890": entry({ protected: true }), "77": entry({ count: 1, maxInThread: 1 }) } });
assert.deepStrictEqual(plain(parsed[1890]), { count: 2, protected: true, maxInThread: 2, category: "sudo" });
assert.strictEqual(parsed[77].count, 1);
assert.deepStrictEqual(Object.keys(parsed).sort(), ["1890", "77"]);

// Abwärtskompatibel: fehlendes oder kaputtes Feld gilt wie „keine Sperren“, fp:activity bleibt wie vorher
for (const data of [undefined, null, {}, { denials: null }, { denials: [] }, { denials: "x" }, { denials: 5 }, { type: "fp:activity", v: 2, tickets: [3], states: [] }]) {
  assert.deepStrictEqual(plain(fpParseDenials(data)), {}, JSON.stringify(data));
}
const activity = { type: "fp:activity", v: 2, tickets: [5], states: [{ ticket: 5, threadId: "t-5", state: "working" }] };
assert.deepStrictEqual(plain(fpParseActivity({ ...activity, denials: { "5": entry() } })), plain(fpParseActivity(activity)), "denials stört fpParseActivity nicht");
assert.deepStrictEqual(plain(fpParseActivity(activity)), { 5: { state: "working", thread: "t-5" } });

// Untrusted: schlechte Ticketnummern, Zahlen, Kategorien fallen weg oder werden geglättet
parsed = fpParseDenials({ denials: {
  abc: entry(), "0": entry(), "-4": entry(), "1234567890": entry(),
  "10": entry({ count: 0 }), "11": entry({ count: 1.5 }), "12": entry({ count: "3" }), "13": "x", "14": null,
  "20": entry({ lastCategory: "rm -rf /" }), "21": entry({ lastCategory: "<b>x</b>" }), "22": entry({ lastCategory: 5 }),
  "23": entry({ maxInThread: 0 }), "24": entry({ maxInThread: "z" }), "25": entry({ protected: "true" }), "26": entry({ count: 1e12 })
} });
assert.deepStrictEqual(Object.keys(parsed).sort(), ["20", "21", "22", "23", "24", "25", "26"]);
assert.strictEqual(parsed[20].category, "", "Kategorie mit Leerzeichen fällt weg");
assert.strictEqual(parsed[21].category, "");
assert.strictEqual(parsed[22].category, "");
assert.strictEqual(parsed[23].maxInThread, 1);
assert.strictEqual(parsed[24].maxInThread, 1);
assert.strictEqual(parsed[25].protected, false, "nur echtes true zählt");
assert.strictEqual(parsed[26].count, 99999);
assert.strictEqual(Object.keys(fpParseDenials({ denials: Object.fromEntries(Array.from({ length: 300 }, (_, i) => [String(i + 1), entry()])) })).length, 200);

// Rang 1 nur bei Schutzziel oder ab drei Ablehnungen in einem Thread
assert.strictEqual(fpDenialAttention(entry()), false, "zwei Ablehnungen, kein Schutzziel: nur Pille");
assert.strictEqual(fpDenialAttention(entry({ count: 9, maxInThread: 2 })), false, "viele Ablehnungen, aber über Threads verteilt");
assert.strictEqual(fpDenialAttention(entry({ maxInThread: 3 })), true);
assert.strictEqual(fpDenialAttention(entry({ count: 1, maxInThread: 1, protected: true })), true);
assert.strictEqual(fpDenialAttention(undefined), false);

// Texte: Zahl und Kategorie, nie ein Befehl
assert.strictEqual(fpDenialPillText(entry({ count: 4 })), "4 gesperrt");
assert.strictEqual(fpDenialPillText(entry({ count: 1 }), "__N__ blocked"), "1 blocked");
assert.strictEqual(fpDenialCategoryLabel("docker"), "Docker");
assert.strictEqual(fpDenialCategoryLabel("git-push-main"), "Push auf main/master");
assert.strictEqual(fpDenialCategoryLabel("unbekannt"), "Sperrliste");
assert.strictEqual(fpDenialCategoryLabel(""), "Sperrliste");
assert.strictEqual(fpDenialCategoryLabel("constructor"), "Sperrliste", "kein Treffer über die Prototypenkette");
assert.strictEqual(fpDenialCategoryLabel("docker", { docker: "Container" }), "Container");
assert.strictEqual(fpDenialCategoryLabel("docker", { docker: 5 }), "Docker");

// Gesehen: die Zeile bleibt weg, bis neue Sperren dazukommen
assert.strictEqual(fpDenialRowVisible(entry({ protected: true, count: 2 }), 0), true);
assert.strictEqual(fpDenialRowVisible(entry({ protected: true, count: 2 }), 2), false);
assert.strictEqual(fpDenialRowVisible(entry({ protected: true, count: 3 }), 2), true);
assert.strictEqual(fpDenialRowVisible(entry(), 0), false, "ohne Aufmerksamkeit nie eine Zeile");

console.log("denials_logic_test: ok");
