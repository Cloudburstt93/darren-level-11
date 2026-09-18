# MBJ Photo — website redesign concept

A one-page redesign concept for [MBJ Photo](https://www.mbjphoto.com) (photographer
Marco Beltran Jurado, Grand Junction, Colorado), built by HardyWired Tech as a pitch
piece. **This is not the live site.**

Plain HTML, CSS, and vanilla JavaScript. No framework, no build step, no dependencies.

## Run it locally

Any static file server works. From inside this folder:

```bash
python3 -m http.server 5500
# or
npx serve -l 5500
```

Then open http://localhost:5500.

Opening `index.html` directly from the file system mostly works, but use a server so
paths and the `<dialog>` lightbox behave exactly as they will in production.

## Deploy to Vercel

This folder is the whole site — push it to a GitHub repository and import it in Vercel:

1. Create a repo and push this folder's contents to it.
2. In Vercel, **Add New → Project**, import the repo.
3. Framework preset: **Other**. Build command: leave empty. Output directory: leave
   empty (the repository root is served as-is). If this folder sits inside a larger
   repo, set **Root Directory** to `mbj-photo-concept`.
4. Deploy.

File names are all lowercase and every path uses forward slashes, because Vercel's
servers are case-sensitive even when Windows and macOS are not.

## Layout

```
index.html                                    home
portfolio/index.html                          all sessions        ->  /portfolio
portfolio-collections/portfolio/<slug>/       one page per session
styles.css                                    all styles, tokens at the top
script.js                                     nav, pricing estimate, validation, lightbox
images/                                       home page photos, 800w/1600w JPG + WebP
images/projects/                              session photos, 700w + native JPG + WebP
favicon.png  apple-touch-icon.png
404.html                                      served for any missing URL
sitemap.xml                                   all 20 pages, regenerated with the site
robots.txt                                    Disallow: / while this is a concept
```

`404.html` uses root-relative paths throughout, because it is served in place of a URL
at any depth — a relative stylesheet would 404 alongside the page it was meant to
style. `sitemap.xml` and `robots.txt` both name the production domain, which comes from
the same `ORIGIN` constant as the social tags.

Project URLs deliberately match the ones the live Wix site already uses
(`/portfolio-collections/portfolio/marquez-family`), so the 18 pages Google has
indexed keep working instead of 404ing on launch day. Each page is a real directory
with an `index.html`, so it needs no rewrite rules on any static host.

## Navigation

The header carries a **Work** dropdown listing all 18 sessions plus "All work". It is a
button with `aria-expanded`, not a hover menu: it opens on click, closes on Escape
(returning focus to the button) or on a click outside, and collapses behind a **Menu**
button below 900px. Everything works from the keyboard.

## Regenerating the pages

The HTML is generated from the live portfolio data rather than hand-maintained, so
adding a session means re-running the generator, not copying a file. The generator
scripts live outside this folder (they are build tooling, not site files).

## Before this goes anywhere: confirm the per-person price

**Marco's current site states two different figures for the same thing.**

- The home page says: "Each additional person added to any shoot: +$100"
- All three services in his live Wix booking system say: "Each Additional Person
  is $200"

On a family of four booking the $450 package that is the difference between $750
and $1,050. This page uses the **$100** figure from the home page. Confirm which is
right before showing anyone a total.

To change it, edit both of these (they are marked with comments):

- `EXTRA_PERSON` in the page generator, which writes the sentence under the packages
- `data-extra-person` on the `<form>` in `index.html`, which the live estimate reads

## What to change at launch

1. **Confirm the per-person price** — see above. This is the only item that can
   quote a client the wrong number.
2. **Remove the concept banner** — the first `<p class="concept-banner">` in
   `index.html`.
3. **Remove `<meta name="robots" content="noindex, nofollow">`** from `<head>`.
4. **Delete `robots.txt`** (or empty the `Disallow:` value).
5. **Decide how booking works.** Right now "Pick a time on my calendar" links out to
   Marco's existing Wix booking page so nothing he relies on is lost. At launch,
   either embed that calendar on this page or replace it with a Cal.com embed.
6. **Give the booking form an endpoint.** Put a Formspree
   (`https://formspree.io/f/xxxxxxx`) or Web3Forms (`https://api.web3forms.com/submit`,
   plus a hidden `access_key` field) URL on the form's own `action` attribute in
   `index.html` — `FORM_ENDPOINT` in the page generator writes it there. It lives on
   the form rather than in the script so the form still posts if JavaScript fails to
   load; `script.js` reads it from the action and enhances the submit with inline
   validation and the in-page confirmation. While it is empty the form validates,
   confirms without sending, and a `<noscript>` note says so.
7. **Add real contact details** — phone and email. Neither appears anywhere on his
   current site, so there was nothing to carry over.
8. **Add a photo of Marco and two lines about him** to the "Moments that become
   treasures" section. People are hiring a person to make them feel comfortable on
   camera, and right now they never see his face. The section is built to take a
   portrait beside the text.
9. **Add real social profile links** — there is an HTML comment in the footer marking
   where. Nothing is linked today because his current footer icons point at bare
   `facebook.com` / `instagram.com` / `x.com` / `tiktok.com` / `youtube.com`.
10. **Check the share domain.** Open Graph needs absolute URLs, so every page's
    social tags are built from one constant — `ORIGIN` in the page generator, set to
    `https://www.mbjphoto.com`. If the site goes live anywhere else first (a Vercel
    preview domain, say), change that one value and rebuild, or shared links will show
    a blank card. Also add `telephone`, `email`, and `sameAs` to the JSON-LD block at
    the bottom of `index.html`.
11. **Swap in full-resolution originals** from Marco. The photos here were pulled from
    the current Wix site at the largest size it serves.

## What the current site already does that this concept does not

Worth knowing before the pitch, because these are live today:

- **Online booking.** `mbjphoto.com/book-online` works, with three bookable services:
  Essential $300, Classic $450, Premium $600. The packages on this page are named to
  match those, since that is what a client sees at checkout. His home page calls the
  same three "Package 1/2/3"; his booking descriptions carry both names.
- **A store.** Published product pages for framed photos, prints, digital downloads
  and graduation prints across four categories. This one-page concept does not
  replace the store, and it would need its own plan.
- **A duration mismatch.** His booking system books all three services as 60-minute
  slots, while the descriptions say 30–45 minutes, 60 minutes, and 1–2 hours. This
  page uses the descriptions.

## Things Marco should look at

- **Nine of his eighteen session URLs are `untitled-project-86f7e7` and similar.** The
  titles are fine ("Medina family", "Creative Creations"); only the URLs were never
  named. Renaming them is worth doing, with redirects from the old ones.
- **The session descriptions say "our", the rest of the site says "I".** His project
  copy ("our passion for capturing authentic connections") is carried over verbatim
  rather than silently rewritten.
- **Alt text on session photos is provenance, not description.** Where Marco captioned
  a photo his caption is used (85 of the 108 here); the rest read "Photograph from the
  <session> session". Only the home page images were reviewed one by one and given
  specific alt text. Writing real alt text for the full library is a task for launch.
- **Each session page shows 6 photographs** out of the 7-18 he has per session, and says
  so. The template takes as many as you give it.

## Notes

- No `localStorage` or `sessionStorage` is used.
- The only animation is the hero headline widening once on load; it is disabled under
  `prefers-reduced-motion`.
- Every text/background pair in the palette meets WCAG AA contrast.
