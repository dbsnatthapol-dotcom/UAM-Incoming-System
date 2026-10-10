// read-doc — reads a packing list (mode "doc") or a carton label (mode "tag") with Gemini.
// Secrets: GEMINI_API_KEY (required), GEMINI_MODEL (optional, default gemini-2.5-flash).
// The caller must send the site key in header x-site-key (same code the app uses to write data).
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-site-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const DOC_PROMPT = `You are reading photos of a printed incoming-goods packing list / delivery note at a Thai auto-parts factory (customer is often Royal Enfield). Photos may be rotated 90 or 180 degrees, wrinkled, or have handwriting on top. There may be several photos (pages); read photo 1 first.
Extract EVERY printed table row from ALL photos, in reading order.
Rules:
- partNo: copy exactly as printed, including suffixes like "/B" or "/A" (examples: "RAT00566/B", "150324/A", "RAJ00538/B").
- desc: the printed description text.
- box: the BOX / carton number for the row if the sheet has such a column (the cell may be merged across several rows: repeat the value on each row). Empty string if none.
- packing: the printed Packing number as an integer, or null.
- qty: the printed Quantity number as an integer (remove commas). If there is no Quantity column, use packing.
- IGNORE handwritten numbers, ticks, circles, strike lines, highlighter, signatures and handwritten remarks. Only printed values count.
- confidence: 0..1 for each row; below 0.8 if any character is blurred, cut off, or covered by handwriting.
- Also read printed header info if present: supplier/brand, model, document title, document number, date.
Reply with only JSON in this shape:
{"supplier":null,"model":null,"title":null,"docNo":null,"docDate":null,"lines":[{"partNo":"RAT00566/B","desc":"SPOKE 1, REAR, TUBELESS, 17 X 3.5\\"","box":"4","packing":2250,"qty":2250,"confidence":0.95}]}`;

const TAG_PROMPT = (parts: string[]) => `This is a photo of a printed carton label at goods receiving. Read the PART CODE (part number, e.g. "RAJ00238/D") and the QUANTITY (pieces in this carton, integer). Ignore weights, dates, times and employee names.
${parts.length ? `Part numbers expected on this delivery: ${parts.join(", ")}. If the label clearly matches one of them, use that exact spelling.` : ""}
Reply with only JSON: {"partCode":"RAJ00238/D","qty":100,"partName":"SPACER, WHEEL","confidence":0.95}. Use null for anything you cannot read.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: cfg } = await admin.from("app_config").select("value").eq("key", "site_key").maybeSingle();
    if (!cfg || req.headers.get("x-site-key") !== cfg.value) return json({ error: "bad_site_key" }, 401);

    const key = Deno.env.get("GEMINI_API_KEY");
    if (!key) return json({ error: "no_gemini_key" }, 503);
    const model = Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash";

    const { mode, images, parts } = await req.json();
    if (!Array.isArray(images) || !images.length || images.length > 8) return json({ error: "bad_images" }, 400);
    const prompt = mode === "tag" ? TAG_PROMPT(Array.isArray(parts) ? parts.slice(0, 150).map(String) : []) : DOC_PROMPT;

    const body = {
      contents: [{
        role: "user",
        parts: [{ text: prompt }, ...images.map((i: { mime?: string; data: string }) => ({
          inline_data: { mime_type: i.mime || "image/jpeg", data: i.data },
        }))],
      }],
      generationConfig: { responseMimeType: "application/json", temperature: 0 },
    };
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify(body),
    });
    const out = await r.json();
    if (!r.ok) return json({ error: "gemini_error", status: r.status, detail: out?.error?.message || "" }, 502);
    const text: string = (out?.candidates?.[0]?.content?.parts || []).map((p: { text?: string }) => p.text || "").join("");
    let parsed: unknown = null;
    try { parsed = JSON.parse(text); } catch {
      const m = text.match(/[\{\[][\s\S]*[\}\]]/);
      if (m) { try { parsed = JSON.parse(m[0]); } catch { parsed = null; } }
    }
    if (!parsed) return json({ error: "unparseable", raw: text.slice(0, 1500) }, 502);
    return json({ ok: true, model, result: parsed });
  } catch (e) {
    return json({ error: "server_error", detail: String((e as Error)?.message || e) }, 500);
  }
});
