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
index.html          the whole page
styles.css          all styles, tokens at the top of the file
script.js           pricing estimate, form validation, gallery lightbox
images/             optimized JPG + WebP at 800w / 1600w (hero also 2000w)
favicon.png         32px, generated from the MBJ shutter mark
apple-touch-icon.png 180px
robots.txt          Disallow: / while this is a concept
```

## What to change at launch

1. **Remove the concept banner** — the first `<p class="concept-banner">` in
   `index.html`.
2. **Remove `<meta name="robots" content="noindex, nofollow">`** from `<head>`.
3. **Delete `robots.txt`** (or empty the `Disallow:` value).
4. **Set `FORM_ENDPOINT`** at the top of `script.js` to a Formspree or Web3Forms URL,
   or replace the form with a Cal.com embed. Until then the form validates and shows
   its success state without sending anything.
5. **Add real contact details** — phone, email — and real social profile links. There
   is an HTML comment in the footer marking where the social links go. Nothing is
   linked today because the current live site points at generic `facebook.com` /
   `instagram.com` placeholders.
6. **Update the Open Graph and Twitter image paths** in `<head>` from relative paths
   to absolute production URLs, and add `telephone`, `email`, and `sameAs` to the
   JSON-LD block at the bottom of `index.html`.
7. **Confirm the per-person pricing** with Marco — the page states that package prices
   cover one person and each additional person adds $100.
8. **Swap in full-resolution originals** from Marco. The photos here were pulled from
   the current Wix site at the largest size it serves.

## Notes

- No `localStorage` or `sessionStorage` is used.
- The only animation is the hero headline widening once on load; it is disabled under
  `prefers-reduced-motion`.
- Every text/background pair in the palette meets WCAG AA contrast.
