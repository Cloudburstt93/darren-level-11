# Website audit toolkit

Two files that work as a pair:

| File | What it does |
|---|---|
| `audit.sh` | Runs the automated checks against a domain and writes a pre-filled JSON file. |
| `website-audit-scorecard.html` | The scorecard you hand the client. Loads that JSON with **Open file…**, lets you fill in the human-judgement parts, then prints to PDF. |

```bash
./audit.sh hardynevisweb.com
# -> ./audits/hardynevisweb.com-2026-09-14.json
```

Then open `website-audit-scorecard.html` in a browser, click **Open file…**, pick
the JSON. Five categories arrive already scored with the measured numbers in the
notes. Two are deliberately left blank for you.

---

## Install

```bash
npm install -g lighthouse pa11y linkinator     # the three heavy tools
sudo apt install -y curl openssl dnsutils      # Debian/Ubuntu
brew install curl openssl bind                 # macOS
```

`python3` is required — it does all the parsing and writes the JSON. It ships
with macOS and every mainstream Linux.

You don't have to install everything up front. `audit.sh` checks on startup and
prints the exact install command for anything missing. Missing *optional* tools
just leave their category unscored; only `curl` and `python3` stop the run.

---

## Usage

```
./audit.sh <domain> [options]

  --out-dir DIR         where to write the JSON     (default: ./audits)
  --max-pages N         sitemap pages to crawl      (default: 25)
  --timeout SEC         per-request HTTP timeout    (default: 25)
  --tool-timeout SEC    per-tool timeout            (default: 300)
  --lh-runs N           lighthouse runs, median wins (default: 1)
  --a11y-runs N         pa11y runs, worst wins       (default: 3)
  --skip LIST           comma-separated: perf,seo,security,a11y,hygiene
  --keep-raw            keep every tool's raw output next to the JSON
  -h, --help
```

The domain can be written any way you like — `example.com`,
`www.example.com`, `https://example.com/pricing` all normalise to the same
thing.

**For a report you're actually charging for, use `--lh-runs 3`.** See
*Reproducibility* below.

Useful combinations:

```bash
./audit.sh example.com --lh-runs 3 --keep-raw   # client-facing, with evidence
./audit.sh example.com --skip perf              # skip the slow one
./audit.sh example.com --max-pages 100          # big site
```

---

## What is automated, and what isn't

| Category | Weight | Tool |
|---|---|---|
| Performance | 20 | `lighthouse`, mobile form factor |
| SEO Foundations | 20 | `curl` + sitemap crawl + HTML parse |
| Security & Trust | 15 | `curl -I`, `openssl s_client`, `dig` |
| Accessibility | 10 | `pa11y` (HTML_CodeSniffer, WCAG 2.1 AA) |
| Site Hygiene | 5 | `linkinator` |
| **Mobile Experience** | 15 | **you, with a real phone** |
| **Conversion** | 15 | **you, acting like a customer** |

Mobile and Conversion come back unscored on purpose. A headless browser at
375px wide is not a thumb, and no script can tell you whether the contact form
actually delivers mail. Both arrive with a numbered checklist in their notes —
work through it on your phone and score them in the card.

---

## The rubric

Every category scores 0–10 from fixed thresholds, then rounds half-up. There is
no judgement and no randomness in the scoring: **feed the same measurements in,
get the same number out.** The same rubric lives in the comment block at the top
of `audit.sh`, so the script and this file can't drift apart.

### Performance — 10 pts
| Measurement | Points |
|---|---|
| LCP ≤ 2500ms | 3.0 |
| LCP ≤ 4000ms | 1.5 |
| Responsiveness ≤ 200ms | 2.0 |
| Responsiveness ≤ 500ms | 1.0 |
| CLS ≤ 0.10 | 2.0 |
| CLS ≤ 0.25 | 1.0 |
| Lighthouse score ≥ 90 | 2.0 |
| Lighthouse score ≥ 50 | 1.0 |
| Largest opportunity < 1000ms | 1.0 |

*Responsiveness:* Lighthouse cannot measure INP in navigation mode — INP needs
real interactions. When it isn't available the script uses **Total Blocking
Time**, the accepted lab proxy, and says so explicitly in the notes. It never
prints a number it didn't measure.

### SEO — 10 pts
| Measurement | Points |
|---|---|
| robots.txt present and not blocking the site | 1.5 |
| sitemap.xml present, parses, ≥1 URL, ≥50% of URLs on this domain | 1.5 |
| share of crawled pages with a unique, non-empty `<title>` | × 2.5 |
| share of crawled pages with a unique, non-empty meta description | × 2.0 |
| share of crawled pages with exactly one `<h1>` | × 1.5 |
| share of `<img>` elements with a non-empty `alt` | × 1.0 |

The last four are proportional, not pass/fail — 8 of 10 pages with unique
titles scores 2.0, not 0. Images marked `aria-hidden="true"` or
`role="presentation"` with `alt=""` count as correctly handled, because they
are. A page with no images at all gets the full alt point.

### Security — 10 pts
| Measurement | Points |
|---|---|
| Certificate chains to a trusted root and matches the host | 2.5 |
| Certificate expiry > 30 days | 1.0 |
| Certificate expiry > 7 days | 0.5 |
| `Strict-Transport-Security` | 1.5 |
| `X-Content-Type-Options: nosniff` | 0.75 |
| `X-Frame-Options` or CSP `frame-ancestors` | 0.75 |
| `Content-Security-Policy` | 1.0 |
| `Referrer-Policy` | 0.5 |
| SPF record published | 1.0 |
| DMARC record published | 1.0 |

DKIM is probed across ~20 common selectors and reported, but **never scored**.
Finding a selector proves DKIM exists; not finding one proves nothing, because
the selector could be named anything. Scoring on it would punish sites for
using an unusual name.

### Accessibility — 10 pts
Banded on homepage error count — one error is one barrier regardless of which
rule it broke:

| Errors | 0 | 1–2 | 3–5 | 6–10 | 11–20 | 21–40 | 40+ |
|---|---|---|---|---|---|---|---|
| Score | 10 | 8 | 7 | 5 | 3 | 2 | 1 |

Errors are also grouped by type in the notes (contrast, missing alt, unlabelled
inputs, language, heading order) so you know what to quote for.

pa11y is run **3 times and the worst run wins** (`--a11y-runs`). This is not
paranoia — see *Reproducibility*.

### Site Hygiene — 10 pts
Starts at 10, with capped deductions:

| Problem | Deduction | Cap |
|---|---|---|
| Broken link (4xx/5xx) | −1.0 each | −5.0 |
| Link that doesn't resolve in one hop | −0.5 each | −2.0 |
| Insecure `http://` link | −0.5 each | −1.5 |
| Missing page returns 200 instead of 404 | −1.0 | — |
| Placeholder link (`example.com`, bare `#`, lorem) | −0.5 | −0.5 |

Links answering **403, 405, 429, 503 or 999** are reported as *blocked by bot
protection*, not as broken, and are not scored against the site. Instagram and
LinkedIn routinely rate-limit crawlers while serving real visitors fine —
calling those "broken links" in front of a client is a false accusation.

### The weighted total

Weights sum to 100: perf 20, mobile 15, convert 15, seo 20, security 15,
a11y 10, hygiene 5.

**Unscored categories are excluded from both halves of the fraction — never
counted as zero.** A fresh run with mobile and convert blank is scored out of
the 70 points that were actually measured and then normalised to 100, and both
the terminal and the card say so (`70 of 100 pts scored`). Fill the two manual
categories in and the total re-computes over the full 100.

---

## Reproducibility

The *rubric* is deterministic. The *measurements* are not, and the honest
caveat is that Lighthouse is the noisy one. A real example from this repo —
three consecutive runs against the same URL, seconds apart:

```
run 1   score 0.81   LCP 3411ms
run 2   score 0.55   LCP 9089ms
run 3   score 0.57   LCP 8951ms
```

That is a 5.7-second spread on an unchanged site. So:

- `--lh-runs 3` runs Lighthouse three times and reports the **median run** —
  not the best, and not an average. A median is a real observed run, so every
  metric in it is internally consistent with the others.
- Run from a stable network. Results from a hotel Wi-Fi tell you about the
  hotel Wi-Fi.

**pa11y is flaky in a more dangerous direction.** Four consecutive runs against
the same URL gave 16, 16, 16 and then **0** contrast errors — HTML_CodeSniffer
sometimes runs before the page's styles settle, and silently finds nothing.

A score of 10/10 that should have been 3/10 is the worst possible failure for
this tool: it tells a client their site is fine when it isn't. So pa11y runs
three times and **the worst run wins**. An accessibility error is an existence
proof — a run that found a contrast failure proves the failure is real, while a
run that missed it proves nothing at all. Runs where the browser clearly landed
on a stub or an error page are discarded entirely rather than counted as clean.

The notes record exactly what happened, so you can see the spread yourself:

```
16 error(s) total — worst of 3 run(s); counts observed: 16, 16, 16.
```

- Security, SEO and Hygiene are stable — the same site gives the same headers,
  certificate, DNS records, link graph and page structure every time.

---

## When a tool fails

One tool falling over never kills the run. The category is scored `null`,
the reason goes in its notes, and everything else continues:

```
SEO Foundations    wt 20  ··········  —/10 could not fetch a single page to analyse
```

```json
"seo": { "score": null, "notes": "UNSCORED — could not fetch a single page…", "checks": {…} }
```

**A category is never scored from a guess.** Unscored is always better than
invented — a made-up number in a client report is worse than an honest gap.
Specifically:

- Transient network failures are retried (3 attempts, backing off) before
  anything is called a failure.
- If pa11y's browser lands on an error page instead of the site, the run is
  retried and then abandoned. It will not report "no page title" as an
  accessibility finding when the page demonstrably has one.
- If `dig` is missing, DNS falls back to DNS-over-HTTPS via `curl`. Both are
  real lookups.
- Checkboxes are ticked only where the evidence supports them, independently
  of the score.

---

## Output format

`audits/<domain>-<date>.json`, schema 1:

```json
{
  "schema": 1,
  "meta": { "domain": "example.com", "url": "https://example.com/",
            "date": "2026-09-14", "generator": "audit.sh 1.0" },
  "categories": {
    "perf": {
      "score": 4,
      "notes": "Lighthouse 57/100 …\nLCP 8951ms · CLS 0.000 …",
      "checks": { "perf-c0": false, "perf-c1": false, "perf-c2": true,
                  "perf-c3": false, "perf-c4": false }
    }
  }
}
```

Category ids: `perf`, `mobile`, `convert`, `seo`, `security`, `a11y`,
`hygiene`. Checkbox ids are `{category}-c0` … `{category}-c4`, in the order the
checks appear in the `CATS` array in `website-audit-scorecard.html`. `score` is
an integer 0–10 or `null`. The card's `restore()` is tolerant: missing
categories, checks and notes fall back to defaults.

The card's **Save JSON** button writes the same shape back out, so you can
re-open an audit you've already annotated.

---

## Troubleshooting

**`lighthouse` or `pa11y` can't find Chrome** — set `CHROME_PATH`:

```bash
export CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

Extra Chrome flags go in `AUDIT_CHROME_FLAGS`.

**Behind a corporate proxy** — `curl` and the Node tools pick up `HTTPS_PROXY`
on their own. `openssl` doesn't, so the script passes it `-proxy` explicitly
when the variable is set. Nothing needs configuring by hand.

**A whole category is unscored and you want to know why** — re-run with
`--keep-raw`. Every tool's raw output lands in
`audits/<domain>-<date>-raw/` for you to read.

**Sanity-check the toolkit itself** — `--skip` one category at a time to
isolate which tool is misbehaving on a given site.
