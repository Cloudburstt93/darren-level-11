#!/usr/bin/env bash
#
# audit.sh — automated small-business website audit
#
#   Usage:  ./audit.sh <domain> [options]
#   Output: ./audits/<domain>-<YYYY-MM-DD>.json   (load it into
#           website-audit-scorecard.html with the "Open file…" button)
#
# ---------------------------------------------------------------------------
# WHAT IS AUTOMATED
#   perf      lighthouse CLI, mobile form factor      -> LCP / INP / CLS / score
#   seo       robots.txt + sitemap.xml + page crawl   -> titles, descriptions,
#                                                        H1s, image alt coverage
#   security  curl headers + openssl cert + DNS TXT   -> headers, cert, SPF,
#                                                        DMARC, DKIM
#   a11y      pa11y against the homepage              -> errors grouped by type
#   hygiene   linkinator                              -> broken links, redirect
#                                                        chains, mixed content
#
# NOT automated — these need a human holding a real phone:
#   mobile    thumb reach, tap targets, real-world scroll behaviour
#   convert   does the contact form actually deliver mail, is the CTA obvious
#
# ---------------------------------------------------------------------------
# SCORING RUBRIC  (the whole point: two runs on the same site, same number)
#
# Every category scores 0-10. Points are accumulated from fixed thresholds,
# then rounded half-up to an integer. No judgement calls, no randomness. A
# category whose tool failed is scored `null` (unscored), never guessed.
#
#   PERF (10 pts)
#     Largest Contentful Paint   <= 2500ms ...... 3.0
#                                <= 4000ms ...... 1.5
#                                 > 4000ms ...... 0.0
#     Responsiveness (INP, or Total Blocking Time when lab INP is
#     unavailable — navigation-mode Lighthouse cannot measure INP):
#                                <= 200ms ....... 2.0
#                                <= 500ms ....... 1.0
#                                 > 500ms ....... 0.0
#     Cumulative Layout Shift    <= 0.10 ........ 2.0
#                                <= 0.25 ........ 1.0
#                                 > 0.25 ........ 0.0
#     Lighthouse perf score      >= 90 .......... 2.0
#                                >= 50 .......... 1.0
#                                 < 50 .......... 0.0
#     Largest opportunity        < 1000ms ....... 1.0
#
#   SEO (10 pts)
#     robots.txt present and not blocking the site ......... 1.5
#     sitemap.xml present, parses, >=1 URL, and at least
#       half of its URLs are on this domain ................ 1.5
#     2.5 x (share of crawled pages with a unique, non-empty <title>)
#     2.0 x (share of crawled pages with a unique, non-empty meta description)
#     1.5 x (share of crawled pages with exactly one <h1>)
#     1.0 x (share of <img> elements carrying a non-empty alt attribute;
#            full credit when the crawled pages contain no images)
#
#   SECURITY (10 pts)
#     Certificate chains to a trusted root and matches host ... 2.5
#     Certificate expiry   > 30 days ......................... 1.0
#                          > 7 days .......................... 0.5
#     Strict-Transport-Security .............................. 1.5
#     X-Content-Type-Options: nosniff ........................ 0.75
#     Clickjacking defence (X-Frame-Options or CSP
#       frame-ancestors) ..................................... 0.75
#     Content-Security-Policy ................................ 1.0
#     Referrer-Policy ........................................ 0.5
#     SPF record published ................................... 1.0
#     DMARC record published ................................. 1.0
#     (DKIM is evidence for the checkbox only; it does not score,
#      because a selector probe can only prove presence, not absence.)
#
#   A11Y (10 pts) — banded on homepage error count, because one error is
#   one barrier regardless of which rule it broke:
#     0 errors ....... 10        6-10 errors ..... 5
#     1-2 errors ..... 8         11-20 errors .... 3
#     3-5 errors ..... 7         21-40 errors .... 2
#                                 40+ errors ..... 1
#
#   HYGIENE (10 pts) — starts at 10, deductions capped so one bad category
#   cannot drive the score below what the others justify:
#     broken links (4xx/5xx)   -1.0 each, capped at -5.0
#     redirect chains          -0.5 each, capped at -2.0
#     insecure http:// links   -0.5 each, capped at -1.5
#     soft 404 (missing page returns 200) ............. -1.0
#     placeholder links (example.com, bare "#", lorem)  -0.5, capped at -0.5
#
# WEIGHTED TOTAL
#   perf 20, mobile 15, convert 15, seo 20, security 15, a11y 10, hygiene 5.
#   Unscored categories are excluded from both halves of the fraction — they
#   are never counted as zero — and the total is normalised back onto 100.
# ---------------------------------------------------------------------------

set -uo pipefail          # deliberately NOT -e: a failing tool must not end the run

VERSION="1.0"
GENERATOR="audit.sh ${VERSION}"

# ---- defaults -------------------------------------------------------------
OUT_DIR="./audits"
MAX_PAGES=25              # sitemap pages to crawl for the SEO category
HTTP_TIMEOUT=25           # seconds per curl request
TOOL_TIMEOUT=300          # seconds per heavyweight tool (lighthouse, pa11y…)
LH_RUNS=1                 # lighthouse runs; >1 takes the median run (see README)
A11Y_RUNS=3               # pa11y runs; the WORST run wins (see README)
KEEP_RAW=0
SKIP=""

# DKIM selectors worth probing. Presence proves DKIM; absence proves nothing,
# which is why DKIM never subtracts points.
DKIM_SELECTORS="default google selector1 selector2 k1 k2 s1 s2 dkim mail smtp
                zoho mandrill sendgrid protonmail1 fm1 everlytickey1 mailjet
                sig1 pic scph0620 dkim1"

# ---- pretty output --------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_CYN=$'\033[36m'
else
  C_R=""; C_B=""; C_DIM=""; C_GRN=""; C_YEL=""; C_RED=""; C_CYN=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s%s%s\n' "$C_CYN" "$C_R" "$C_B" "$*" "$C_R"; }
warn() { printf '%s  ! %s%s\n' "$C_YEL" "$*" "$C_R" >&2; }
die()  { printf '%s  x %s%s\n' "$C_RED" "$*" "$C_R" >&2; exit 2; }

usage() {
  cat <<USAGE
Usage: ./audit.sh <domain> [options]

  <domain>              e.g. example.com  or  https://example.com

Options:
  --out-dir DIR         where to write the JSON     (default: ./audits)
  --max-pages N         sitemap pages to crawl      (default: 25)
  --timeout SEC         per-request HTTP timeout    (default: 25)
  --tool-timeout SEC    per-tool timeout            (default: 300)
  --lh-runs N           lighthouse runs, median wins (default: 1; use 3 for
                        client-facing reports — LCP is genuinely noisy)
  --a11y-runs N         pa11y runs, worst wins       (default: 3; pa11y's
                        contrast check misses issues on some runs)
  --skip LIST           comma-separated categories to skip
                        (perf,seo,security,a11y,hygiene)
  --keep-raw            keep raw tool output next to the JSON
  -h, --help            this text

Environment:
  CHROME_PATH           Chrome/Chromium binary for lighthouse and pa11y
  AUDIT_CHROME_FLAGS    extra flags appended to the Chrome command line
  HTTPS_PROXY           honoured by curl, and passed to openssl s_client

Output: <out-dir>/<domain>-<date>.json — open it in
website-audit-scorecard.html with the "Open file…" button.
USAGE
}

# ---- argument parsing -----------------------------------------------------
DOMAIN_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    --out-dir)      OUT_DIR="${2:-}";      shift 2 || die "--out-dir needs a value" ;;
    --max-pages)    MAX_PAGES="${2:-}";    shift 2 || die "--max-pages needs a value" ;;
    --timeout)      HTTP_TIMEOUT="${2:-}"; shift 2 || die "--timeout needs a value" ;;
    --tool-timeout) TOOL_TIMEOUT="${2:-}"; shift 2 || die "--tool-timeout needs a value" ;;
    --lh-runs)      LH_RUNS="${2:-}";      shift 2 || die "--lh-runs needs a value" ;;
    --a11y-runs)    A11Y_RUNS="${2:-}";    shift 2 || die "--a11y-runs needs a value" ;;
    --skip)         SKIP="${2:-}";         shift 2 || die "--skip needs a value" ;;
    --keep-raw)     KEEP_RAW=1; shift ;;
    -*)             die "unknown option: $1  (try --help)" ;;
    *)              [ -n "$DOMAIN_ARG" ] && die "unexpected argument: $1"
                    DOMAIN_ARG="$1"; shift ;;
  esac
done
[ -n "$DOMAIN_ARG" ] || { usage; exit 2; }

# Normalise: accept https://example.com/path, www.example.com, example.com
DOMAIN=$(printf '%s' "$DOMAIN_ARG" \
         | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##' -e 's/:.*$//' \
         | tr 'A-Z' 'a-z')
[ -n "$DOMAIN" ] || die "could not parse a domain out of: $DOMAIN_ARG"
case "$DOMAIN" in *.*) ;; *) die "'$DOMAIN' does not look like a domain" ;; esac

BASE_URL="https://${DOMAIN}/"
# Email checks belong on the registrable domain, not the www host.
MAIL_DOMAIN="${DOMAIN#www.}"
TODAY=$(date +%Y-%m-%d)

skipped() { case ",${SKIP}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# Dependency check — everything up front, with install commands, so the run
# never dies halfway through with "command not found".
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) PKG_DNS="brew install bind";        PKG_SSL="brew install openssl";
          PKG_CURL="brew install curl";       PKG_PY="brew install python3" ;;
  *)      PKG_DNS="sudo apt install -y dnsutils"; PKG_SSL="sudo apt install -y openssl";
          PKG_CURL="sudo apt install -y curl";    PKG_PY="sudo apt install -y python3" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

MISSING_CORE=""
MISSING_OPT=""
add_missing() { # add_missing <core|opt> <tool> <install command> <what it costs you>
  local line
  line=$(printf '  %-12s %s\n                 %s' "$2" "$3" "$4")
  if [ "$1" = core ]; then MISSING_CORE="${MISSING_CORE}${line}"$'\n'
  else MISSING_OPT="${MISSING_OPT}${line}"$'\n'; fi
}

have curl    || add_missing core curl    "$PKG_CURL" "nothing can run without it"
have python3 || add_missing core python3 "$PKG_PY"   "used for all parsing and JSON output"
have openssl || add_missing opt  openssl "$PKG_SSL"  "security: no certificate inspection"
have dig     || add_missing opt  dig     "$PKG_DNS"  "security: falls back to DNS-over-HTTPS"

skipped perf    || have lighthouse || add_missing opt lighthouse \
  "npm install -g lighthouse" "perf will be left unscored"
skipped a11y    || have pa11y      || add_missing opt pa11y \
  "npm install -g pa11y"      "a11y will be left unscored"
skipped hygiene || have linkinator || add_missing opt linkinator \
  "npm install -g linkinator" "hygiene will be left unscored"

if [ -n "$MISSING_CORE" ] || [ -n "$MISSING_OPT" ]; then
  say ""
  say "${C_YEL}${C_B}Missing tools${C_R}"
  [ -n "$MISSING_CORE" ] && { say "${C_RED}  required:${C_R}"; printf '%s' "$MISSING_CORE"; }
  [ -n "$MISSING_OPT"  ] && { say "${C_YEL}  optional:${C_R}"; printf '%s' "$MISSING_OPT"; }
  say ""
fi
[ -n "$MISSING_CORE" ] && die "install the required tools above, then re-run"

# Lighthouse and pa11y both drive Chrome. Find one if CHROME_PATH is unset.
if [ -z "${CHROME_PATH:-}" ]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser \
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if have "$c" || [ -x "$c" ]; then CHROME_PATH=$(command -v "$c" || printf '%s' "$c"); break; fi
  done
fi
CHROME_FLAGS="--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage ${AUDIT_CHROME_FLAGS:-}"

# ---------------------------------------------------------------------------
# Result accumulators. One directory per fact so notes can contain anything
# (newlines, quotes, pipes) without any escaping games.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/audit-${DOMAIN}-XXXXXX") || die "cannot create temp dir"
cleanup() { [ "$KEEP_RAW" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
mkdir -p "$WORK/facts" "$WORK/raw"

# set_cat <id> <score|null> <checks space separated> <notes...>
set_cat() {
  local id="$1" score="$2" checks="$3"; shift 3
  printf '%s' "$score"  > "$WORK/facts/$id.score"
  printf '%s' "$checks" > "$WORK/facts/$id.checks"
  printf '%s' "$*"      > "$WORK/facts/$id.notes"
}
# unscored <id> <reason...> — the honest fallback whenever a tool fails
unscored() { local id="$1"; shift; set_cat "$id" null "" "UNSCORED — $*"; }

# finding <severity 1-10> <text...>  — feeds the "worst findings" list
FINDINGS_FILE="$WORK/findings"; : > "$FINDINGS_FILE"
finding() { local sev="$1"; shift; printf '%s\t%s\n' "$sev" "$*" >> "$FINDINGS_FILE"; }

# Round half-up to an integer, clamped to 0..10. Deterministic by construction.
round10() {
  python3 -c 'import sys,decimal
v=decimal.Decimal(sys.argv[1]).quantize(decimal.Decimal("1"),rounding=decimal.ROUND_HALF_UP)
print(max(0,min(10,int(v))))' "$1"
}

# curl wrapper: quiet, follows redirects, bounded, sane UA.
UA="Mozilla/5.0 (compatible; audit.sh/${VERSION}; +website audit)"
fetch()      { curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" "$@"; }
# fetch_to <url> <file> — prints the HTTP status. Retries transient failures
# (curl status 000 = no response) so one dropped packet cannot cost a whole
# category. A real 4xx/5xx is returned immediately; it is an answer, not a flake.
fetch_to() {
  local url="$1" dest="$2" code="" try
  for try in 1 2 3; do
    code=$(curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ] && break
    [ "$try" -lt 3 ] && sleep "$try"
  done
  printf '%s' "${code:-000}"
}
http_code()  { curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

# First meaningful line of a tool's stderr — an "Error: ..." line if there is
# one, otherwise the first line that is not an indented stack frame.
tool_error() {
  { grep -m1 -iE '(^|[^a-z])(error|fatal|refused|timeout|timed out)' "$1" 2>/dev/null \
    || grep -m1 -vE '^[[:space:]]*(at |$)' "$1" 2>/dev/null; } \
  | tr -d '\r' | sed 's/^[[:space:]]*//' | cut -c1-160
}

say ""
say "${C_B}Auditing ${C_CYN}${DOMAIN}${C_R}${C_B} — ${TODAY}${C_R}"
say "${C_DIM}$(printf '%.0s-' $(seq 1 60))${C_R}"

# Is there a website here at all? Everything that reads page content is
# meaningless if the homepage never answers, and scoring those categories
# anyway would produce a confident-looking number about nothing. Certificate
# and DNS facts are independent of HTTP, so those checks still run.
SITE_CODE=$(fetch_to "$BASE_URL" "$WORK/raw/home.html")
SITE_UP=1
if [ "$SITE_CODE" = "000" ]; then
  SITE_UP=0
  warn "${BASE_URL} did not respond after 3 attempts — no DNS, no route, or the server is down."
  warn "Page-content categories (perf, seo, a11y, hygiene) will be left unscored."
  finding 10 "${BASE_URL} does not respond at all — nothing is served to visitors"
fi

# ===========================================================================
# PERF — lighthouse, mobile form factor
# ===========================================================================
audit_perf() {
  if skipped perf;      then unscored perf "skipped with --skip perf"; return; fi
  if [ "$SITE_UP" = 0 ]; then unscored perf "site did not respond — nothing to measure (${BASE_URL})"; return; fi
  if ! have lighthouse; then unscored perf "lighthouse not installed — npm install -g lighthouse"; return; fi

  step "perf — lighthouse (mobile), ${LH_RUNS} run(s), this takes a minute"
  local log="$WORK/raw/lighthouse.log" rc=1 i ok=0 reports=""
  for i in $(seq 1 "$LH_RUNS"); do
    local out="$WORK/raw/lighthouse-${i}.json"
    CHROME_PATH="${CHROME_PATH:-}" timeout "$TOOL_TIMEOUT" lighthouse "$BASE_URL" \
        --only-categories=performance \
        --form-factor=mobile --screenEmulation.mobile \
        --output=json --output-path="$out" --quiet \
        --chrome-flags="$CHROME_FLAGS" >>"$log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$out" ]; then ok=$((ok+1)); reports="$reports $out"; fi
  done

  if [ "$ok" -eq 0 ]; then
    unscored perf "lighthouse exited $rc on all ${LH_RUNS} attempt(s) — $(tool_error "$log")"
    return
  fi

  # Parse the report. Emits shell-safe KEY=VALUE lines, or FAIL=<reason>.
  local parsed
  parsed=$(python3 - $reports <<'PY'
import json, sys

# With several runs, report the MEDIAN run by performance score rather than the
# best or the mean: it is an actually-observed run (so every metric in it is
# internally consistent) and it damps the run-to-run noise that makes LCP swing
# by seconds on the same URL.
loaded = []
for path in sys.argv[1:]:
    try: rep = json.load(open(path))
    except Exception: continue
    if rep.get("runtimeError"): continue
    sc = (rep.get("categories", {}).get("performance", {}) or {}).get("score")
    if sc is None: continue
    loaded.append((sc, rep))

if not loaded:
    print("FAIL=no lighthouse run produced a usable performance score"); sys.exit(0)

loaded.sort(key=lambda x: x[0])
r = loaded[len(loaded) // 2][1]
RUNS = len(loaded)

A = r.get("audits", {})
def num(key):
    a = A.get(key) or {}
    v = a.get("numericValue")
    return None if v is None else float(v)

score = (r.get("categories", {}).get("performance", {}) or {}).get("score")
lcp, cls, tbt = num("largest-contentful-paint"), num("cumulative-layout-shift"), num("total-blocking-time")
inp = num("interaction-to-next-paint")          # absent in navigation mode

# Opportunities, largest projected saving first.
opps = []
for k, a in A.items():
    d = a.get("details") or {}
    if d.get("type") != "opportunity":
        continue
    ms = d.get("overallSavingsMs") or 0
    if ms >= 100:
        opps.append((float(ms), a.get("title", k)))
opps.sort(reverse=True)

out = {
    "SCORE": "" if score is None else str(round(score * 100)),
    "LCP":   "" if lcp   is None else "%.0f" % lcp,
    "CLS":   "" if cls   is None else "%.3f" % cls,
    "TBT":   "" if tbt   is None else "%.0f" % tbt,
    "INP":   "" if inp   is None else "%.0f" % inp,
    "TOPOPP": "" if not opps else "%.0f" % opps[0][0],
    "RUNS": str(RUNS),
}
for k, v in out.items():
    print("%s=%s" % (k, v))
print("OPPS=" + " | ".join("%s (~%.1fs)" % (t, ms / 1000.0) for ms, t in opps[:4]))
PY
)
  case "$parsed" in FAIL=*) unscored perf "lighthouse: ${parsed#FAIL=}"; return ;; esac

  local SCORE="" LCP="" CLS="" TBT="" INP="" TOPOPP="" OPPS="" RUNS=""
  eval "$(printf '%s\n' "$parsed" | sed 's/^\([A-Z]*\)=\(.*\)$/\1=$'"'"'\2'"'"'/')"

  if [ -z "$LCP" ] && [ -z "$SCORE" ]; then
    unscored perf "lighthouse produced no metrics (page may have failed to load)"; return
  fi

  # --- rubric (see header) ---
  local pts checks="" resp_val resp_src
  if [ -n "$INP" ]; then resp_val="$INP"; resp_src="INP"
  else                   resp_val="${TBT:-}"; resp_src="TBT"; fi

  pts=$(python3 -c '
import sys
lcp,cls,sc,resp,top = sys.argv[1:6]
f=lambda s: float(s) if s not in ("","None") else None
lcp,cls,sc,resp,top = f(lcp),f(cls),f(sc),f(resp),f(top)
p=0.0
if lcp  is not None: p += 3.0 if lcp<=2500 else 1.5 if lcp<=4000 else 0.0
if resp is not None: p += 2.0 if resp<=200 else 1.0 if resp<=500 else 0.0
if cls  is not None: p += 2.0 if cls<=0.10 else 1.0 if cls<=0.25 else 0.0
if sc   is not None: p += 2.0 if sc>=90   else 1.0 if sc>=50   else 0.0
p += 1.0 if (top is None or top < 1000) else 0.0
print("%.2f" % p)' "$LCP" "$CLS" "$SCORE" "$resp_val" "$TOPOPP")

  [ -n "$LCP" ]  && [ "$(python3 -c "print(1 if float('$LCP')<=2500 else 0)")" = 1 ] && checks="$checks perf-c0"
  [ -n "$resp_val" ] && [ "$(python3 -c "print(1 if float('$resp_val')<=200 else 0)")" = 1 ] && checks="$checks perf-c1"
  [ -n "$CLS" ]  && [ "$(python3 -c "print(1 if float('$CLS')<=0.10 else 0)")" = 1 ] && checks="$checks perf-c2"
  [ -n "$SCORE" ] && [ "$SCORE" -ge 90 ] 2>/dev/null && checks="$checks perf-c3"
  { [ -z "$TOPOPP" ] || [ "$(python3 -c "print(1 if float('$TOPOPP')<1000 else 0)")" = 1 ]; } && checks="$checks perf-c4"

  local notes resp_note
  if [ -n "$INP" ]; then resp_note="INP ${INP}ms"
  elif [ -n "$TBT" ]; then resp_note="INP not measurable in lab navigation mode; TBT ${TBT}ms used as the responsiveness proxy"
  else resp_note="INP/TBT unavailable"; fi

  notes="Lighthouse ${SCORE:-n/a}/100 (mobile emulation, simulated throttling${RUNS:+, median of ${RUNS} run(s)})
LCP ${LCP:-n/a}ms · CLS ${CLS:-n/a} · ${resp_note}"
  [ -n "$OPPS" ] && notes="${notes}
Top opportunities: ${OPPS}"

  set_cat perf "$(round10 "$pts")" "$checks" "$notes"

  [ -n "$LCP" ] && [ "$(python3 -c "print(1 if float('$LCP')>4000 else 0)")" = 1 ] && \
    finding 9 "LCP is $(python3 -c "print('%.1f'%(float('$LCP')/1000))")s on mobile — visitors stare at a blank screen (target 2.5s)"
  [ -n "$CLS" ] && [ "$(python3 -c "print(1 if float('$CLS')>0.25 else 0)")" = 1 ] && \
    finding 7 "Layout shifts badly while loading (CLS ${CLS}, target 0.10)"
  [ -n "$SCORE" ] && [ "$SCORE" -lt 50 ] 2>/dev/null && \
    finding 8 "Lighthouse mobile performance score is ${SCORE}/100"
}

# ===========================================================================
# SEO — robots.txt, sitemap.xml, then crawl the sitemap's pages
# ===========================================================================
audit_seo() {
  if skipped seo; then unscored seo "skipped with --skip seo"; return; fi
  if [ "$SITE_UP" = 0 ]; then unscored seo "site did not respond — nothing to measure (${BASE_URL})"; return; fi
  step "seo — robots.txt, sitemap.xml, page crawl"

  local robots="$WORK/raw/robots.txt" robots_code robots_ok=0 robots_note
  robots_code=$(fetch_to "${BASE_URL}robots.txt" "$robots")
  if [ "$robots_code" = "200" ] && [ -s "$robots" ]; then
    # A blanket "Disallow: /" under "User-agent: *" hides the whole site.
    if python3 - "$robots" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
blocked, star = False, False
for line in txt.splitlines():
    line = line.split("#", 1)[0].strip()
    if not line or ":" not in line: continue
    k, v = (p.strip() for p in line.split(":", 1))
    k = k.lower()
    if k == "user-agent": star = (v == "*")
    elif k == "disallow" and star and v == "/": blocked = True
sys.exit(1 if blocked else 0)
PY
    then robots_ok=1; robots_note="robots.txt present (HTTP 200), crawlers allowed"
    else robots_note="robots.txt present but contains 'Disallow: /' for all agents — the site is asking to be de-indexed"
         finding 10 "robots.txt blocks all crawlers with 'Disallow: /' — the site cannot rank at all"
    fi
  else
    robots_note="robots.txt missing (HTTP ${robots_code:-error})"
    finding 4 "No robots.txt (HTTP ${robots_code:-error})"
  fi

  # --- locate and parse the sitemap -----------------------------------------
  local sm_ok=0 sm_note sm_urls="$WORK/raw/sitemap-urls.txt" sm_src=""
  : > "$sm_urls"
  local sm_candidates="${BASE_URL}sitemap.xml ${BASE_URL}sitemap_index.xml"
  # robots.txt may name a sitemap somewhere else entirely.
  if [ -s "$robots" ]; then
    local declared
    declared=$(grep -i '^[[:space:]]*sitemap:' "$robots" 2>/dev/null \
               | sed 's/^[[:space:]]*[Ss]itemap:[[:space:]]*//' | tr -d '\r' | head -3)
    [ -n "$declared" ] && sm_candidates="$sm_candidates $declared"
  fi

  local cand code n=0
  for cand in $sm_candidates; do
    [ -s "$sm_urls" ] && break
    n=$((n+1))
    local f="$WORK/raw/sitemap-$n.xml"
    code=$(fetch_to "$cand" "$f")
    [ "$code" = "200" ] && [ -s "$f" ] || continue

    # A sitemap index points at more sitemaps; follow up to 5 of them.
    if grep -qi '<sitemapindex' "$f"; then
      local child cn=0
      for child in $(python3 - "$f" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", xml, re.I)[:5]:
    print(m)
PY
      ); do
        cn=$((cn+1))
        curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" -o "$WORK/raw/sitemap-$n-$cn.xml" "$child" 2>/dev/null
      done
      python3 - "$WORK/raw/sitemap-$n-"*.xml <<'PY' >> "$sm_urls" 2>/dev/null
import re, sys
for p in sys.argv[1:]:
    try: xml = open(p, encoding="utf-8", errors="replace").read()
    except OSError: continue
    for m in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", xml, re.I): print(m.strip())
PY
    else
      python3 - "$f" <<'PY' >> "$sm_urls"
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", xml, re.I): print(m.strip())
PY
    fi
    [ -s "$sm_urls" ] && sm_src="$cand"
  done

  local sm_total=0 sm_onhost=0 sm_offhost=0
  if [ -s "$sm_urls" ]; then
    sm_total=$(wc -l < "$sm_urls" | tr -d ' ')
    sm_onhost=$(grep -ciE "^https?://(www\.)?${DOMAIN#www.}(/|$|\?|#)" "$sm_urls" 2>/dev/null || true)
    sm_offhost=$((sm_total - sm_onhost))
    # Full credit only if the sitemap is mostly about THIS site. A sitemap full
    # of someone else's URLs is a template left half-configured.
    if [ "$sm_total" -gt 0 ] && [ $((sm_onhost * 2)) -ge "$sm_total" ]; then
      sm_ok=1; sm_note="sitemap at ${sm_src} — ${sm_total} URLs, all on this domain"
      [ "$sm_offhost" -gt 0 ] && sm_note="sitemap at ${sm_src} — ${sm_total} URLs (${sm_offhost} point at another domain)"
    else
      sm_note="sitemap at ${sm_src} lists ${sm_total} URLs but only ${sm_onhost} are on ${DOMAIN} — ${sm_offhost} point at a different domain"
      finding 8 "sitemap.xml lists ${sm_offhost} of ${sm_total} URLs on a DIFFERENT domain — looks like a template that was never re-pointed"
    fi
  else
    sm_note="no sitemap.xml found (tried ${BASE_URL}sitemap.xml and any robots.txt Sitemap: line)"
    finding 5 "No sitemap.xml — search engines have to guess which pages exist"
  fi

  # --- build the crawl list -------------------------------------------------
  # Prefer this domain's own sitemap URLs. Strip fragments (#services is the
  # same page as /), dedupe, cap at --max-pages. Homepage always included.
  local crawl="$WORK/raw/crawl.txt"
  python3 - "$sm_urls" "$BASE_URL" "${DOMAIN#www.}" "$MAX_PAGES" <<'PY' > "$crawl"
import sys, urllib.parse as up
src, base, host, cap = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
seen, out = set(), []
def add(u):
    u, _ = up.urldefrag(u)                 # "/#services" is the homepage
    u = u.rstrip()
    if not u.lower().startswith(("http://", "https://")): return
    h = up.urlparse(u).netloc.lower().split(":")[0]
    if h not in (host, "www." + host): return   # only this site
    if u in seen: return
    seen.add(u); out.append(u)
add(base)
try:
    for line in open(src, encoding="utf-8", errors="replace"):
        add(line.strip())
except OSError:
    pass
for u in out[:cap]: print(u)
PY

  local pages_dir="$WORK/raw/pages" map="$WORK/raw/pagemap.tsv"
  mkdir -p "$pages_dir"; : > "$map"
  local i=0 url
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    i=$((i+1))
    local pf; pf=$(printf '%s/%03d.html' "$pages_dir" "$i")
    local pc; pc=$(fetch_to "$url" "$pf")
    printf '%s\t%s\t%s\n' "$url" "$pf" "${pc:-000}" >> "$map"
  done < "$crawl"

  local crawled_ok
  crawled_ok=$(awk -F'\t' '$3=="200"' "$map" 2>/dev/null | wc -l | tr -d ' ')

  if [ "${crawled_ok:-0}" -eq 0 ]; then
    unscored seo "could not fetch a single page to analyse. ${robots_note}. ${sm_note}"
    finding 9 "No page on ${DOMAIN} could be fetched for SEO analysis"
    return
  fi

  # --- analyse the fetched pages -------------------------------------------
  local seo_json="$WORK/raw/seo.json"
  python3 - "$map" <<'PY' > "$seo_json"
import json, re, sys
from html.parser import HTMLParser

class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self._intitle = "", False
        self.desc, self.h1 = "", 0
        self.imgs, self.imgs_alt = 0, 0
    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "title": self._intitle = True
        elif tag == "h1":  self.h1 += 1
        elif tag == "meta":
            if a.get("name", "").lower() == "description":
                self.desc = a.get("content", "").strip()
        elif tag == "img":
            # Decorative images (alt="" + aria-hidden / role=presentation) are
            # correct HTML, so they count as covered rather than as failures.
            self.imgs += 1
            alt = a.get("alt")
            decorative = a.get("aria-hidden") == "true" or a.get("role") in ("presentation", "none")
            if (alt is not None and alt.strip()) or (alt is not None and decorative):
                self.imgs_alt += 1
    def handle_startendtag(self, tag, attrs): self.handle_starttag(tag, attrs)
    def handle_endtag(self, tag):
        if tag == "title": self._intitle = False
    def handle_data(self, d):
        if self._intitle: self.title += d

pages, titles, descs = [], {}, {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3 or parts[2] != "200": continue
    url, path, _ = parts
    try: html = open(path, encoding="utf-8", errors="replace").read()
    except OSError: continue
    p = Page()
    try: p.feed(html)
    except Exception: pass
    t = re.sub(r"\s+", " ", p.title).strip()
    d = re.sub(r"\s+", " ", p.desc).strip()
    pages.append({"url": url, "title": t, "desc": d, "h1": p.h1,
                  "imgs": p.imgs, "imgs_alt": p.imgs_alt})
    if t: titles.setdefault(t, []).append(url)
    if d: descs.setdefault(d, []).append(url)

n = len(pages)
dup_t = {k: v for k, v in titles.items() if len(v) > 1}
dup_d = {k: v for k, v in descs.items() if len(v) > 1}
uniq_t = sum(1 for p in pages if p["title"] and len(titles.get(p["title"], [])) == 1)
uniq_d = sum(1 for p in pages if p["desc"]  and len(descs.get(p["desc"],  [])) == 1)
one_h1 = sum(1 for p in pages if p["h1"] == 1)
imgs   = sum(p["imgs"] for p in pages)
imgs_a = sum(p["imgs_alt"] for p in pages)

print(json.dumps({
    "pages": n,
    "missing_title": sum(1 for p in pages if not p["title"]),
    "unique_title": uniq_t,
    "dup_title_groups": len(dup_t),
    "missing_desc": sum(1 for p in pages if not p["desc"]),
    "unique_desc": uniq_d,
    "dup_desc_groups": len(dup_d),
    "no_h1":    sum(1 for p in pages if p["h1"] == 0),
    "multi_h1": sum(1 for p in pages if p["h1"] > 1),
    "one_h1": one_h1,
    "imgs": imgs, "imgs_alt": imgs_a,
    "alt_pct": (100.0 * imgs_a / imgs) if imgs else 100.0,
    "worst_dup_title": (max(dup_t.items(), key=lambda kv: len(kv[1]))[0][:60] if dup_t else ""),
}))
PY

  if [ ! -s "$seo_json" ]; then
    unscored seo "page analysis failed after fetching ${crawled_ok} pages"; return
  fi

  # --- rubric (see header) --------------------------------------------------
  local seo_res
  seo_res=$(python3 - "$seo_json" "$robots_ok" "$sm_ok" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
robots_ok, sm_ok = sys.argv[2] == "1", sys.argv[3] == "1"
n = max(1, d["pages"])
r_t, r_d = d["unique_title"] / n, d["unique_desc"] / n
r_h, r_a = d["one_h1"] / n, d["alt_pct"] / 100.0
pts = (1.5 if robots_ok else 0) + (1.5 if sm_ok else 0) \
      + 2.5 * r_t + 2.0 * r_d + 1.5 * r_h + 1.0 * r_a
checks = []
if robots_ok: checks.append("seo-c0")
if sm_ok:     checks.append("seo-c1")
if d["unique_title"] == d["pages"] and d["pages"]: checks.append("seo-c2")
if d["unique_desc"]  == d["pages"] and d["pages"]: checks.append("seo-c3")
if d["one_h1"] == d["pages"] and d["alt_pct"] >= 95: checks.append("seo-c4")
print("%.3f" % pts); print(" ".join(checks))
print("%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%s" % (
    d["pages"], d["missing_title"], d["dup_title_groups"], d["unique_title"],
    d["missing_desc"], d["dup_desc_groups"], d["unique_desc"],
    d["no_h1"], d["multi_h1"], d["imgs"], d["alt_pct"], d["worst_dup_title"]))
PY
)
  local seo_pts seo_checks seo_stats
  seo_pts=$(printf '%s\n' "$seo_res" | sed -n 1p)
  seo_checks=$(printf '%s\n' "$seo_res" | sed -n 2p)
  seo_stats=$(printf '%s\n' "$seo_res" | sed -n 3p)
  IFS=$'\t' read -r P_N P_NOTITLE P_DUPT P_UNIQT P_NODESC P_DUPD P_UNIQD P_NOH1 P_MULTIH1 P_IMGS P_ALTPCT P_WORSTDUP \
      <<< "$seo_stats"

  set_cat seo "$(round10 "$seo_pts")" "$seo_checks" \
"${robots_note}
${sm_note}
Crawled ${P_N} page(s) from the sitemap.
Titles: ${P_UNIQT}/${P_N} unique · ${P_NOTITLE} missing · ${P_DUPT} duplicate group(s)
Meta descriptions: ${P_UNIQD}/${P_N} unique · ${P_NODESC} missing · ${P_DUPD} duplicate group(s)
H1: ${P_NOH1} page(s) with none, ${P_MULTIH1} with more than one
Images: ${P_IMGS} found, ${P_ALTPCT}% carry alt text"

  [ "${P_NOTITLE:-0}" -gt 0 ] && finding 8 "${P_NOTITLE} page(s) have no <title> tag"
  [ "${P_DUPT:-0}" -gt 0 ]    && finding 7 "${P_DUPT} group(s) of pages share the same title (e.g. \"${P_WORSTDUP}\") — they compete with each other in search"
  [ "${P_NODESC:-0}" -gt 0 ]  && finding 6 "${P_NODESC} page(s) have no meta description — Google writes its own snippet"
  [ "${P_MULTIH1:-0}" -gt 0 ] && finding 4 "${P_MULTIH1} page(s) have more than one H1"
  [ "${P_NOH1:-0}" -gt 0 ]    && finding 5 "${P_NOH1} page(s) have no H1 at all"
  [ "${P_IMGS:-0}" -gt 0 ] && [ "$(python3 -c "print(1 if float('${P_ALTPCT:-100}')<80 else 0)")" = 1 ] && \
    finding 6 "Only ${P_ALTPCT}% of images have alt text — hurts image search and screen readers"
}

# ===========================================================================
# SECURITY — response headers, TLS certificate, and email DNS records
# ===========================================================================

# dns_txt <name> — dig if present, DNS-over-HTTPS otherwise. Both are real
# lookups; neither invents an answer. An empty result means "not found".
dns_txt() {
  if have dig; then
    dig +short TXT "$1" 2>/dev/null | sed -e 's/" "//g' -e 's/^"//' -e 's/"$//'
  else
    curl -sS --max-time "$HTTP_TIMEOUT" -H 'accept: application/dns-json' \
         "https://dns.google/resolve?name=$1&type=TXT" 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for a in d.get("Answer",[]):
    if a.get("type")==16: print(a.get("data","").replace("\" \"","").strip("\""))'
  fi
}
dns_cname() {
  if have dig; then dig +short CNAME "$1" 2>/dev/null
  else curl -sS --max-time "$HTTP_TIMEOUT" -H 'accept: application/dns-json' \
            "https://dns.google/resolve?name=$1&type=CNAME" 2>/dev/null \
       | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for a in d.get("Answer",[]):
    if a.get("type")==5: print(a.get("data",""))'
  fi
}

audit_security() {
  if skipped security; then unscored security "skipped with --skip security"; return; fi
  if [ "$SITE_UP" = 0 ]; then
    unscored security "site did not respond — headers and certificate not checkable (${BASE_URL})"
    return
  fi
  step "security — headers, certificate, SPF/DMARC/DKIM"

  # --- response headers -----------------------------------------------------
  local hf="$WORK/raw/headers.txt" h_try
  for h_try in 1 2 3; do
    : > "$hf"
    curl -sSI -L --max-time "$HTTP_TIMEOUT" -A "$UA" "$BASE_URL" > "$hf" 2>/dev/null
    # Some servers answer HEAD differently (or not at all) — fall back to a GET
    # whose body we throw away, keeping only the headers.
    if [ ! -s "$hf" ] || ! grep -qiE '^HTTP/' "$hf"; then
      curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" -o /dev/null -D "$hf" "$BASE_URL" 2>/dev/null
    fi
    # A transient network blip must not cost the whole category, so retry until
    # we see a real response from the site rather than nothing at all.
    grep -qiE '^HTTP/[0-9.]+ [123]' "$hf" && break
    [ "$h_try" -lt 3 ] && sleep "$h_try"
  done

  # Only the final response in a redirect chain counts. A proxy's
  # "HTTP/1.1 200 Connection Established" preamble is NOT a response from the
  # site — counting it as one is how an unreachable host ends up "scored".
  local hlast="$WORK/raw/headers-final.txt"; : > "$hlast"
  if [ -s "$hf" ] && grep -qiE '^HTTP/' "$hf"; then
    python3 - "$hf" <<'PY' > "$hlast"
import re, sys
blocks, cur = [], []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if re.match(r"^HTTP/", line):
        if cur: blocks.append(cur)
        cur = [line]
    elif cur:
        cur.append(line)
if cur: blocks.append(cur)
# Skip proxy "200 Connection Established" preambles and redirect hops.
real = [b for b in blocks if not re.search(r"connection established", b[0], re.I)]
sys.stdout.write("".join(real[-1] if real else []))
PY
  fi
  local hdr_ok=0 hdr_status=""
  hdr_status=$(head -1 "$hlast" 2>/dev/null | awk '{print $2}')
  # >=400 means we are looking at an error page. Whether it came from the site
  # or from something in the middle, its headers are not evidence about the
  # site's configuration, so refuse to score them.
  if [ -n "$hdr_status" ] && [ "$hdr_status" -lt 400 ] 2>/dev/null; then hdr_ok=1; fi
  hdr() { [ -s "$hlast" ] && grep -iE "^$1:" "$hlast" 2>/dev/null | head -1 | sed "s/^[^:]*:[[:space:]]*//" | tr -d '\r'; }

  local H_HSTS H_NOSNIFF H_XFO H_CSP H_REF H_PERM
  H_HSTS=$(hdr 'strict-transport-security'); H_NOSNIFF=$(hdr 'x-content-type-options')
  H_XFO=$(hdr 'x-frame-options');            H_CSP=$(hdr 'content-security-policy')
  H_REF=$(hdr 'referrer-policy');            H_PERM=$(hdr 'permissions-policy')

  local has_hsts=0 has_nosniff=0 has_frame=0 has_csp=0 has_ref=0
  [ -n "$H_HSTS" ] && has_hsts=1
  printf '%s' "$H_NOSNIFF" | grep -qi 'nosniff' && has_nosniff=1
  { [ -n "$H_XFO" ] || printf '%s' "$H_CSP" | grep -qi 'frame-ancestors'; } && has_frame=1
  [ -n "$H_CSP" ] && has_csp=1
  [ -n "$H_REF" ] && has_ref=1

  # --- TLS certificate ------------------------------------------------------
  local cert_ok=0 cert_days="" cert_issuer="" cert_subject="" cert_note="" cert_measured=0
  if ! have openssl; then
    cert_note="certificate not inspected (openssl not installed)"
  else
    local sargs=""
    # openssl does not read HTTPS_PROXY on its own; hand it over explicitly so
    # the check works from behind a corporate proxy too.
    if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]; then
      local p="${HTTPS_PROXY:-$https_proxy}"; p="${p#http://}"; p="${p#https://}"; p="${p%/}"
      sargs="-proxy $p"
    fi
    local so="$WORK/raw/openssl.txt" pem="$WORK/raw/cert.pem" c_try
    # A dropped handshake is a failed measurement, not a failed certificate.
    # Retry before concluding anything about the site's TLS.
    for c_try in 1 2 3; do
      : > "$pem"
      echo | timeout 30 openssl s_client $sargs -connect "${DOMAIN}:443" \
              -servername "$DOMAIN" > "$so" 2>&1
      sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$so" \
        | awk '/BEGIN/{n++} n==1' > "$pem"
      [ -s "$pem" ] && break
      [ "$c_try" -lt 3 ] && sleep "$c_try"
    done

    if [ -s "$pem" ]; then
      cert_measured=1
      cert_issuer=$(openssl x509 -in "$pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' | tr -d '\r')
      cert_subject=$(openssl x509 -in "$pem" -noout -subject 2>/dev/null | sed 's/^subject=//' | tr -d '\r')
      local enddate; enddate=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
      [ -n "$enddate" ] && cert_days=$(python3 -c '
import sys, datetime
try:
    d = datetime.datetime.strptime(sys.argv[1].strip(), "%b %d %H:%M:%S %Y %Z")
    print(int((d - datetime.datetime.utcnow()).total_seconds() // 86400))
except Exception:
    pass' "$enddate")
      grep -q 'Verify return code: 0 (ok)' "$so" && cert_ok=1
      if [ "$cert_ok" = 1 ]; then
        cert_note="certificate valid — issued by ${cert_issuer:-unknown}, ${cert_days:-?} days until expiry"
      else
        local vr; vr=$(grep -m1 'Verify return code:' "$so" | sed 's/.*Verify return code: //')
        cert_note="certificate did NOT verify — ${vr:-unknown reason} (issuer ${cert_issuer:-unknown})"
        finding 10 "TLS certificate does not verify: ${vr:-unknown reason} — browsers will show a security warning"
      fi
    else
      cert_note="could not retrieve a certificate from ${DOMAIN}:443 (3 attempts)"
    fi
  fi

  # --- email authentication -------------------------------------------------
  local spf dmarc dkim_found="" has_spf=0 has_dmarc=0 dmarc_policy=""
  spf=$(dns_txt "$MAIL_DOMAIN" | grep -i '^v=spf1' | head -1)
  [ -n "$spf" ] && has_spf=1
  dmarc=$(dns_txt "_dmarc.${MAIL_DOMAIN}" | grep -i '^v=DMARC1' | head -1)
  if [ -n "$dmarc" ]; then
    has_dmarc=1
    dmarc_policy=$(printf '%s' "$dmarc" | tr ';' '\n' | grep -i '^[[:space:]]*p=' | head -1 | tr -d ' ' | cut -d= -f2)
  fi
  local sel
  for sel in $DKIM_SELECTORS; do
    [ -n "$dkim_found" ] && break
    if dns_txt "${sel}._domainkey.${MAIL_DOMAIN}" | grep -qi 'v=DKIM1\|p='; then dkim_found="$sel"
    elif [ -n "$(dns_cname "${sel}._domainkey.${MAIL_DOMAIN}")" ]; then dkim_found="$sel (CNAME)"; fi
  done

  # --- rubric (see header) --------------------------------------------------
  local pts checks=""
  pts=$(python3 -c '
import sys
ok, days, hsts, nosniff, frame, csp, ref, spf, dmarc = [x for x in sys.argv[1:10]]
days = int(days) if days.lstrip("-").isdigit() else None
p = 0.0
if ok == "1":
    p += 2.5
    if days is not None: p += 1.0 if days > 30 else 0.5 if days > 7 else 0.0
p += 1.5  if hsts    == "1" else 0
p += 0.75 if nosniff == "1" else 0
p += 0.75 if frame   == "1" else 0
p += 1.0  if csp     == "1" else 0
p += 0.5  if ref     == "1" else 0
p += 1.0  if spf     == "1" else 0
p += 1.0  if dmarc   == "1" else 0
print("%.2f" % p)' "$cert_ok" "${cert_days:-x}" "$has_hsts" "$has_nosniff" "$has_frame" \
      "$has_csp" "$has_ref" "$has_spf" "$has_dmarc")

  [ "$cert_ok" = 1 ] && checks="$checks security-c0"
  [ -n "$cert_days" ] && [ "$cert_days" -gt 30 ] 2>/dev/null && checks="$checks security-c1"
  [ "$has_hsts" = 1 ] && [ "$has_nosniff" = 1 ] && [ "$has_frame" = 1 ] && checks="$checks security-c2"
  [ "$has_csp" = 1 ] && [ "$has_ref" = 1 ] && checks="$checks security-c3"
  [ "$has_spf" = 1 ] && [ "$has_dmarc" = 1 ] && [ -n "$dkim_found" ] && checks="$checks security-c4"

  local present="" missing=""
  add_hdr() { # add_hdr <0|1> <name>
    if [ "$1" = 1 ]; then present="${present}${present:+, }$2"
    else missing="${missing}${missing:+, }$2"; fi
  }
  add_hdr "$has_hsts"    "Strict-Transport-Security"
  add_hdr "$has_nosniff" "X-Content-Type-Options"
  add_hdr "$has_frame"   "X-Frame-Options/frame-ancestors"
  add_hdr "$has_csp"     "Content-Security-Policy"
  add_hdr "$has_ref"     "Referrer-Policy"
  [ -n "$present" ] || present="none"
  [ -n "$missing" ] || missing="none"

  local csp_note="absent" dkim_note
  [ -n "$H_CSP" ] && csp_note="$H_CSP"
  if [ -n "$dkim_found" ]; then dkim_note="selector \"${dkim_found}\" answered"
  else dkim_note="no common selector answered (this does not prove DKIM is absent)"; fi

  if [ "$cert_measured" = 0 ] && have openssl; then
    unscored security "TLS handshake with ${DOMAIN}:443 failed on 3 attempts, so the certificate could not be measured — and 3.5 of this category's 10 points depend on it. Everything that WAS measured: headers present: ${present}; headers missing: ${missing}; SPF: ${spf:-not published}; DMARC: ${dmarc:-not published}; DKIM: ${dkim_note}"
    finding 6 "Could not complete a TLS handshake with ${DOMAIN}:443 after 3 attempts — re-run to confirm whether this is the site or your connection"
    return
  fi

  if [ "$hdr_ok" = 0 ]; then
    unscored security "could not read a valid response from ${BASE_URL}$(
        [ -n "$hdr_status" ] && printf ' (final status %s)' "$hdr_status") — \
header checks need a real 2xx/3xx response, and an error page's headers are not the site's"
    finding 7 "No usable HTTP response from ${BASE_URL}${hdr_status:+ (status ${hdr_status})}"
    return
  fi

  set_cat security "$(round10 "$pts")" "$checks" \
"${cert_note}
Headers present: ${present}
Headers missing: ${missing}
HSTS: ${H_HSTS:-absent}
CSP: ${csp_note}
Referrer-Policy: ${H_REF:-absent} · Permissions-Policy: ${H_PERM:-absent}
SPF: ${spf:-not published}
DMARC: ${dmarc:-not published}${dmarc_policy:+ (policy p=${dmarc_policy})}
DKIM: ${dkim_note}"

  [ "$has_spf" = 0 ]   && finding 7 "No SPF record on ${MAIL_DOMAIN} — anyone can spoof email from this domain"
  [ "$has_dmarc" = 0 ] && finding 7 "No DMARC record on ${MAIL_DOMAIN} — no policy telling mail servers what to do with spoofed mail"
  [ "$has_dmarc" = 1 ] && [ "$dmarc_policy" = "none" ] && \
    finding 3 "DMARC is set to p=none — it monitors spoofing but does not stop it"
  [ "$has_hsts" = 0 ]  && finding 5 "No HSTS header — first visit can be downgraded to plain HTTP"
  [ "$has_csp" = 0 ]   && finding 4 "No Content-Security-Policy header"
  [ -n "$cert_days" ] && [ "$cert_days" -lt 30 ] 2>/dev/null && \
    finding 9 "TLS certificate expires in ${cert_days} days"
}

# ===========================================================================
# A11Y — pa11y against the homepage, errors grouped by type
# ===========================================================================
audit_a11y() {
  if skipped a11y; then unscored a11y "skipped with --skip a11y"; return; fi
  if [ "$SITE_UP" = 0 ]; then unscored a11y "site did not respond — nothing to measure (${BASE_URL})"; return; fi
  if ! have pa11y; then unscored a11y "pa11y not installed — npm install -g pa11y"; return; fi

  step "a11y — pa11y (WCAG 2.1 AA) on the homepage"
  local cfg="$WORK/pa11y.json" out="$WORK/raw/pa11y.json" log="$WORK/raw/pa11y.log"
  python3 - "${CHROME_PATH:-}" "$CHROME_FLAGS" <<'PY' > "$cfg"
import json, sys
exe, flags = sys.argv[1], sys.argv[2].split()
launch = {"args": flags}
if exe: launch["executablePath"] = exe
print(json.dumps({"chromeLaunchConfig": launch}))
PY

  # Reference copy of the raw HTML. If curl can see a <title> but pa11y's
  # browser reports "no title element", the browser landed on a network error
  # page instead of the site — that is a failed run, not an accessibility
  # finding, and reporting it would be a lie dressed up as evidence.
  local ref="$WORK/raw/a11y-ref.html" ref_has_title=0
  [ "$(fetch_to "$BASE_URL" "$ref")" = "200" ] && grep -qi '<title[ >]' "$ref" && ref_has_title=1

  # Give the browser real time to finish loading: a 25s HTTP timeout is fine for
  # curl but far too tight for Chrome rendering a page with third-party embeds.
  local pa_timeout=$(( HTTP_TIMEOUT * 2000 ))
  [ "$pa_timeout" -lt 60000 ] && pa_timeout=60000

  # pa11y is genuinely non-deterministic on JS-rendered pages: consecutive runs
  # against an unchanged URL have produced 16, 16, 16 and then 0 contrast
  # errors, because HTML_CodeSniffer sometimes runs before styles settle. So
  # run it several times and keep the WORST run. An accessibility error is an
  # existence proof — a run that found a contrast failure proves it is there,
  # while a run that missed it proves nothing. Reporting the optimistic run
  # would tell a client their site is fine when it is not.
  # --include-notices is requested purely as a render signal: a fully rendered
  # page yields dozens of notices, so a run with very few audited a stub.
  local rc=0 attempt reports="" ok=0
  for attempt in $(seq 1 "$A11Y_RUNS"); do
    local out_n="$WORK/raw/pa11y-${attempt}.json"
    timeout "$TOOL_TIMEOUT" pa11y "$BASE_URL" --reporter json --standard WCAG2AA \
        --config "$cfg" --timeout "$pa_timeout" --wait 2500 --include-notices \
        > "$out_n" 2>"$log"
    rc=$?
    # pa11y exits 2 when it finds issues — that is a successful run, not a crash.
    { [ $rc -ne 0 ] && [ $rc -ne 2 ]; } && continue
    [ -s "$out_n" ] || continue
    # A document with no <title> when the HTML demonstrably has one means the
    # browser landed on an error page. Discard that run entirely.
    if [ "$ref_has_title" = 1 ] && grep -q 'NoTitleEl' "$out_n"; then continue; fi
    ok=$((ok+1)); reports="$reports $out_n"
  done

  if [ "$ok" -eq 0 ]; then
    unscored a11y "pa11y produced no usable run in ${A11Y_RUNS} attempt(s) (exit $rc) — $(tool_error "$log")"
    return
  fi
  cp $(printf '%s' "$reports" | awk '{print $1}') "$out" 2>/dev/null

  local res
  res=$(python3 - $reports <<'PY'
import json, sys, collections

# Keep the run with the most errors; break ties on total issue count so a
# fuller render wins. Every error in the chosen run was actually observed, so
# the reported counts stay internally consistent with one real run.
runs = []
for path in sys.argv[1:]:
    try: issues = json.load(open(path))
    except Exception: continue
    if isinstance(issues, dict): issues = issues.get("issues", [])
    e = [i for i in issues if i.get("type") == "error"]
    runs.append((len(e), len(issues), e))

if not runs:
    print("FAIL\tno pa11y run could be parsed"); sys.exit(0)

runs.sort(key=lambda r: (r[0], r[1]))
spread = ", ".join(str(r[0]) for r in runs)
errs = runs[-1][2]

# Group by what a human would actually go and fix, not by raw rule id.
BUCKETS = [
    ("1_1_1",  "images missing alt text"),
    ("1_4_3",  "colour contrast below AA"),
    ("1_4_6",  "colour contrast below AAA"),
    ("F68",    "form inputs without labels"),
    ("4_1_2",  "controls missing name/role/value"),
    ("3_1_1",  "document language not set"),
    ("H42",    "heading markup misused"),
    ("G141",   "heading order skips levels"),
    ("2_4_1",  "no way to skip repeated blocks"),
    ("2_4_2",  "page title missing or empty"),
    ("1_3_1",  "structure/relationships not marked up"),
]
counts, codes = collections.Counter(), collections.Counter()
for i in errs:
    code = i.get("code", "")
    codes[code] += 1
    for frag, label in BUCKETS:
        if frag in code:
            counts[label] += 1
            break
    else:
        counts[code.split(".")[-1] or "other"] += 1

flags = {
    "alt":      any("1_1_1" in c for c in codes),
    "contrast": any("1_4_3" in c for c in codes),
    "labels":   any(("F68" in c) or ("4_1_2" in c) for c in codes),
    "lang":     any("3_1_1" in c for c in codes),
    "headings": any(("H42" in c) or ("G141" in c) for c in codes),
}
print("OK\t%d\t%s\t%d" % (len(errs), spread, len(runs)))
print(" | ".join("%s: %d" % (k, v) for k, v in counts.most_common()))
print(" ".join(k for k, v in flags.items() if v))
PY
)
  case "$res" in FAIL*) unscored a11y "pa11y output unreadable: $(printf '%s' "$res" | cut -f2)"; return ;; esac

  local errs bytype flags spread nruns
  errs=$(printf '%s\n' "$res" | sed -n 1p | cut -f2)
  spread=$(printf '%s\n' "$res" | sed -n 1p | cut -f3)
  nruns=$(printf '%s\n' "$res" | sed -n 1p | cut -f4)
  bytype=$(printf '%s\n' "$res" | sed -n 2p)
  flags=$(printf '%s\n' "$res" | sed -n 3p)

  # --- rubric (see header): banded on error count ---------------------------
  local score
  score=$(python3 -c '
e = int("'"$errs"'")
print(10 if e==0 else 8 if e<=2 else 7 if e<=5 else 5 if e<=10 else 3 if e<=20 else 2 if e<=40 else 1)')

  local checks=""
  [ "$errs" -eq 0 ] && checks="$checks a11y-c0"
  case " $flags " in *" alt "*)      ;; *) checks="$checks a11y-c1" ;; esac
  case " $flags " in *" contrast "*) ;; *) checks="$checks a11y-c2" ;; esac
  case " $flags " in *" labels "*)   ;; *) checks="$checks a11y-c3" ;; esac
  case " $flags " in *" lang "*|*" headings "*) ;; *) checks="$checks a11y-c4" ;; esac

  set_cat a11y "$score" "$checks" \
"pa11y / HTML_CodeSniffer, WCAG 2.1 AA, homepage only.
${errs} error(s) total — worst of ${nruns} run(s); counts observed: ${spread}.
By type — ${bytype:-none}"

  [ "$errs" -gt 20 ] && finding 7 "${errs} accessibility errors on the homepage (${bytype})"
  case " $flags " in *" contrast "*) finding 6 "Colour contrast below WCAG AA — text is hard to read for older eyes and in sunlight" ;; esac
  case " $flags " in *" alt "*)      finding 6 "Images on the homepage have no alt text" ;; esac
  case " $flags " in *" labels "*)   finding 7 "Form controls have no associated labels — screen readers cannot announce them" ;; esac
  case " $flags " in *" lang "*)     finding 4 "Page language is not declared (<html lang>)" ;; esac
}

# ===========================================================================
# HYGIENE — linkinator for broken links, plus redirect / mixed-content / 404 probes
# ===========================================================================
audit_hygiene() {
  if skipped hygiene; then unscored hygiene "skipped with --skip hygiene"; return; fi
  if [ "$SITE_UP" = 0 ]; then unscored hygiene "site did not respond — nothing to measure (${BASE_URL})"; return; fi
  if ! have linkinator; then unscored hygiene "linkinator not installed — npm install -g linkinator"; return; fi

  step "hygiene — linkinator crawl"
  local out="$WORK/raw/linkinator.json" log="$WORK/raw/linkinator.log"
  # NOTE: no --silent. linkinator's --silent prints only FAILING links, which
  # would leave us blind to the rest of the inventory (mixed content, redirect
  # candidates, total link count).
  timeout "$TOOL_TIMEOUT" linkinator "$BASE_URL" --recurse --format json \
      --timeout $((HTTP_TIMEOUT * 1000)) --concurrency 10 \
      --skip '^mailto:|^tel:|^sms:|^javascript:' > "$out" 2>"$log"
  local rc=$?
  # linkinator exits non-zero when links are broken — still a valid report.
  if [ ! -s "$out" ] || ! head -c1 "$out" | grep -q '{'; then
    unscored hygiene "linkinator exited $rc with no usable report — $(tool_error "$log")"
    return
  fi

  # Split the report into: broken links, http:// links, placeholder links, and
  # the list of on-domain URLs worth re-probing for redirects.
  local probe="$WORK/raw/probe.txt" hyg="$WORK/raw/hygiene.json"
  python3 - "$out" "${DOMAIN#www.}" "$probe" <<'PY' > "$hyg"
import json, sys, urllib.parse as up
report, host, probe_path = sys.argv[1], sys.argv[2], sys.argv[3]
try: d = json.load(open(report))
except Exception as e:
    print(json.dumps({"error": str(e)})); sys.exit(0)

links = d.get("links", [])
# Some hosts (Instagram, LinkedIn, Cloudflare) answer an automated crawler with
# 429/403/999 while serving real visitors perfectly well. Calling those "broken"
# in front of a client is a false accusation, so they are reported separately
# and never scored against the site.
BOT_BLOCK = {403, 405, 429, 503, 999}
broken, blocked, mixed, placeholder, internal = [], [], [], [], []
seen = set()
for l in links:
    u = (l.get("url") or "").strip()
    if not u or u in seen: continue
    seen.add(u)
    state, status = l.get("state"), l.get("status")
    if state == "BROKEN":
        rec = {"url": u, "status": status, "parent": l.get("parent") or ""}
        (blocked if status in BOT_BLOCK else broken).append(rec)
    if u.lower().startswith("http://"):
        mixed.append(u)
    low = u.lower()
    if ("example.com" in low or "example.org" in low or "lorem" in low
            or low.endswith("/#") or low == "#"):
        placeholder.append(u)
    h = up.urlparse(u).netloc.lower().split(":")[0]
    if h in (host, "www." + host) and u.lower().startswith("https://"):
        internal.append(u)

with open(probe_path, "w") as f:
    f.write("\n".join(internal[:40]))      # bounded: redirect probing costs a request each

broken.sort(key=lambda b: (b["status"] or 0), reverse=True)
print(json.dumps({
    "total": len(seen), "broken": broken, "broken_n": len(broken),
    "blocked": blocked[:5], "blocked_n": len(blocked),
    "mixed": mixed[:10], "mixed_n": len(mixed),
    "placeholder": placeholder[:10], "placeholder_n": len(placeholder),
}))
PY

  # Redirect hops: linkinator reports the final status, not the path taken, so
  # re-request each internal link and ask curl how many hops it needed.
  local redir_list="$WORK/raw/redirects.txt"; : > "$redir_list"
  local u nr fin
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    read -r nr fin <<EOF
$(curl -sS -L --max-time "$HTTP_TIMEOUT" -A "$UA" -o /dev/null -w '%{num_redirects} %{url_effective}' "$u" 2>/dev/null)
EOF
    [ -n "${nr:-}" ] && [ "$nr" -ge 1 ] 2>/dev/null && printf '%s\t%s\t%s\n' "$nr" "$u" "$fin" >> "$redir_list"
  done < "$probe"
  local redir_n chain_n
  redir_n=$(wc -l < "$redir_list" | tr -d ' ')
  chain_n=$(awk -F'\t' '$1>=2' "$redir_list" 2>/dev/null | wc -l | tr -d ' ')

  # Soft-404 probe: a page that cannot exist should answer 404, not 200.
  local probe404 code404 soft404=0
  probe404="${BASE_URL}audit-sh-probe-$(date +%s)-does-not-exist"
  code404=$(http_code "$probe404")
  [ "$code404" = "200" ] && soft404=1

  local res
  res=$(python3 - "$hyg" "$redir_n" "$soft404" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d: print("FAIL\t%s" % d["error"]); sys.exit(0)
redir, soft = int(sys.argv[2]), sys.argv[3] == "1"
b, m, p = d["broken_n"], d["mixed_n"], d["placeholder_n"]
pts = 10.0
pts -= min(5.0, b * 1.0)
pts -= min(2.0, redir * 0.5)
pts -= min(1.5, m * 0.5)
pts -= 1.0 if soft else 0.0
pts -= min(0.5, p * 0.5)
pts = max(0.0, pts)
checks = []
if b == 0: checks.append("hygiene-c0")
if redir == 0: checks.append("hygiene-c1")
if m == 0: checks.append("hygiene-c2")
if not soft: checks.append("hygiene-c3")
if p == 0: checks.append("hygiene-c4")
worst = " | ".join("%s -> %s" % (x["url"][:70], x["status"]) for x in d["broken"][:5])
blocked = " | ".join("%s -> %s" % (x["url"][:60], x["status"]) for x in d.get("blocked", []))
print("OK\t%.2f" % pts)
print(" ".join(checks))
print("%d\t%d\t%d\t%d\t%s\t%d\t%s" % (d["total"], b, m, p, worst, d.get("blocked_n", 0), blocked))
PY
)
  case "$res" in FAIL*) unscored hygiene "linkinator report unreadable: $(printf '%s' "$res" | cut -f2)"; return ;; esac

  local pts checks stats TOTAL BROKEN MIXED PLACE WORST BLOCKED_N BLOCKED
  pts=$(printf '%s\n' "$res" | sed -n 1p | cut -f2)
  checks=$(printf '%s\n' "$res" | sed -n 2p)
  stats=$(printf '%s\n' "$res" | sed -n 3p)
  IFS=$'\t' read -r TOTAL BROKEN MIXED PLACE WORST BLOCKED_N BLOCKED <<< "$stats"

  local redir_examples
  redir_examples=$(head -3 "$redir_list" | awk -F'\t' '{printf "%s (%s hop%s) -> %s; ", $2, $1, ($1==1?"":"s"), $3}')

  set_cat hygiene "$(round10 "$pts")" "$checks" \
"linkinator crawled ${TOTAL} unique link(s) from ${BASE_URL}.
Broken (4xx/5xx): ${BROKEN}${WORST:+ — ${WORST}}
Blocked by bot protection (not counted against the score): ${BLOCKED_N:-0}${BLOCKED:+ — ${BLOCKED}}
Redirects: ${redir_n} link(s) do not resolve in one hop (${chain_n} take 2+ hops)${redir_examples:+ — ${redir_examples}}
Insecure http:// links: ${MIXED}
Placeholder links: ${PLACE}
Missing-page probe returned HTTP ${code404}$([ "$soft404" = 1 ] && printf ' — soft 404, should be 404')"

  [ "${BROKEN:-0}" -gt 0 ] && finding 8 "${BROKEN} broken link(s) — visitors hit dead ends (${WORST})"
  [ "${MIXED:-0}" -gt 0 ]  && finding 6 "${MIXED} insecure http:// link(s) — browsers flag mixed content"
  [ "$soft404" = 1 ]       && finding 5 "Missing pages return HTTP 200 instead of 404 — search engines index junk URLs"
  [ "${redir_n:-0}" -gt 3 ] && finding 3 "${redir_n} links redirect instead of pointing at the final URL"
}

# ===========================================================================
# MOBILE / CONVERT — deliberately not automated
# ===========================================================================
audit_manual() {
  set_cat mobile null "" \
"NOT AUTOMATED — do this on a real phone, on cellular, not a desktop browser at 375px.
1. Load the site on 4G with the cache cleared. Time how long until you can read something.
2. Try to tap every button and link with your thumb. Anything under ~48px or crowded together, note it.
3. Turn the phone sideways. Does anything overflow or scroll horizontally?
4. Open the contact form. Does the number field raise a number pad? Does the keyboard cover the Submit button?
5. Scroll with the sticky header and any chat widget or cookie bar on screen — how much content is actually left visible?
Score it 0-10 in the card and tick the boxes you verified."

  set_cat convert null "" \
"NOT AUTOMATED — judge this as a customer trying to hire them, on a phone.
1. Without scrolling, can you find the phone number, and does tapping it start a call?
2. On each page, what is the one action they want? Is it obvious within 3 seconds?
3. Actually submit the contact form with your own address. Did it arrive? Did you get a confirmation?
4. Can you find hours, service area and any pricing signal without hunting?
5. Is there anything that builds trust — real reviews, photos of real work, licence or insurance numbers, a guarantee?
Score it 0-10 in the card and tick the boxes you verified."
}

# ===========================================================================
# RUN
# ===========================================================================
audit_manual
audit_perf
audit_seo
audit_security
audit_a11y
audit_hygiene

# ---------------------------------------------------------------------------
# Emit the scorecard JSON (schema 1 — see restore() in
# website-audit-scorecard.html for the contract these keys satisfy).
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR" || die "cannot create output directory: $OUT_DIR"
OUT_FILE="${OUT_DIR%/}/${DOMAIN}-${TODAY}.json"

python3 - "$WORK/facts" "$OUT_FILE" "$DOMAIN" "$BASE_URL" "$TODAY" "$GENERATOR" <<'PY'
import json, os, sys
facts, out_file, domain, url, date, generator = sys.argv[1:7]

# Category order and the number of checkboxes each one has. This mirrors the
# CATS array in website-audit-scorecard.html exactly; the checkbox ids are
# built the same way the card builds them: f"{cat}-c{i}".
CATS = [("perf", 5), ("mobile", 5), ("convert", 5), ("seo", 5),
        ("security", 5), ("a11y", 5), ("hygiene", 5)]

def read(cat, ext, default=""):
    p = os.path.join(facts, "%s.%s" % (cat, ext))
    try:
        with open(p, encoding="utf-8", errors="replace") as f: return f.read()
    except OSError:
        return default

doc = {"schema": 1,
       "meta": {"domain": domain, "url": url, "date": date, "generator": generator},
       "categories": {}}

for cat, n in CATS:
    raw = read(cat, "score").strip()
    score = None
    if raw and raw != "null":
        try: score = max(0, min(10, int(float(raw))))
        except ValueError: score = None
    ticked = set(read(cat, "checks").split())
    doc["categories"][cat] = {
        "score": score,
        "notes": read(cat, "notes").strip(),
        "checks": {"%s-c%d" % (cat, i): ("%s-c%d" % (cat, i)) in ticked for i in range(n)},
    }

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
rc=$?
[ $rc -eq 0 ] && [ -s "$OUT_FILE" ] || die "failed to write $OUT_FILE"

if [ "$KEEP_RAW" -eq 1 ]; then
  RAW_DEST="${OUT_DIR%/}/${DOMAIN}-${TODAY}-raw"
  rm -rf "$RAW_DEST"; cp -R "$WORK/raw" "$RAW_DEST" 2>/dev/null && \
    say "${C_DIM}raw tool output kept in ${RAW_DEST}${C_R}"
fi

# ---------------------------------------------------------------------------
# Terminal summary
# ---------------------------------------------------------------------------
say ""
say "${C_B}$(printf '%.0s=' $(seq 1 60))${C_R}"
say "${C_B}  ${DOMAIN}${C_R}  ${C_DIM}${TODAY}${C_R}"
say "${C_B}$(printf '%.0s=' $(seq 1 60))${C_R}"

python3 - "$WORK/facts" "$FINDINGS_FILE" "${C_GRN}" "${C_YEL}" "${C_RED}" "${C_DIM}" "${C_B}" "${C_R}" <<'PY'
import os, sys
facts, findings_file, GRN, YEL, RED, DIM, B, R = sys.argv[1:9]

# Weights match CATS in website-audit-scorecard.html. They sum to 100.
CATS = [("perf", "Performance", 20), ("mobile", "Mobile Experience", 15),
        ("convert", "Conversion", 15), ("seo", "SEO Foundations", 20),
        ("security", "Security & Trust", 15), ("a11y", "Accessibility", 10),
        ("hygiene", "Site Hygiene", 5)]

def read(cat, ext):
    try:
        with open(os.path.join(facts, "%s.%s" % (cat, ext)), encoding="utf-8",
                  errors="replace") as f: return f.read()
    except OSError:
        return ""

pts = wt = 0.0
rows = []
for cat, name, w in CATS:
    raw = read(cat, "score").strip()
    try: score = None if (not raw or raw == "null") else int(float(raw))
    except ValueError: score = None
    if score is None:
        bar, col, shown = "·" * 10, DIM, "  —"
        note = read(cat, "notes").strip().splitlines()
        reason = note[0] if note else ""
        if reason.startswith("UNSCORED — "): reason = reason[len("UNSCORED — "):]
        elif reason.startswith("NOT AUTOMATED"): reason = "needs a human with a phone"
        rows.append((name, w, shown, bar, col, reason[:46]))
    else:
        pts += (score / 10.0) * w; wt += w
        col = GRN if score >= 8 else YEL if score >= 5 else RED
        bar = "#" * score + "." * (10 - score)
        rows.append((name, w, "%3d" % score, bar, col, ""))

for name, w, shown, bar, col, reason in rows:
    print("  %-18s %swt %2d%s  %s%s%s  %s%s/10%s %s%s%s"
          % (name, DIM, w, R, col, bar, R, col, shown.strip(), R, DIM, reason, R))

print("")
if wt:
    total = round((pts / wt) * 100)
    col = GRN if total >= 80 else YEL if total >= 50 else RED
    scope = "all categories" if wt == 100 else "%d of 100 weight points scored" % wt
    print("  %sWEIGHTED TOTAL  %s%d/100%s  %s(%s)%s" % (B, col, total, R, DIM, scope, R))
else:
    print("  %sWEIGHTED TOTAL  —  (nothing could be scored)%s" % (DIM, R))

print("")
try:
    with open(findings_file, encoding="utf-8", errors="replace") as f:
        found = []
        for line in f:
            sev, _, text = line.rstrip("\n").partition("\t")
            if text:
                try: found.append((int(sev), text))
                except ValueError: pass
except OSError:
    found = []

if found:
    found.sort(key=lambda x: -x[0])
    print("  %sWORST FINDINGS%s" % (B, R))
    for i, (sev, text) in enumerate(found[:3], 1):
        col = RED if sev >= 8 else YEL if sev >= 5 else DIM
        print("   %s%d.%s %s%s%s" % (B, i, R, col, text, R))
    if len(found) > 3:
        print("   %s+ %d more in the notes%s" % (DIM, len(found) - 3, R))
else:
    print("  %sNo findings recorded.%s" % (DIM, R))
PY

say ""
say "  ${C_B}JSON${C_R}  ${OUT_FILE}"
say "  ${C_DIM}Open website-audit-scorecard.html and load it with \"Open file…\"${C_R}"
say "  ${C_DIM}mobile and convert are left unscored on purpose — see their notes.${C_R}"
say ""
exit 0
