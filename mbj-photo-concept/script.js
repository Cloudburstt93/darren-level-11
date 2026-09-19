/* MBJ Photo — redesign concept by HardyWired Tech */

/* The booking endpoint lives on the form's own action attribute in index.html, not
   here, so the form still posts when this script fails to load. */

(function () {
  "use strict";

  /* ------------------------------------------------------------------ navigation */

  const navToggle = document.getElementById("nav-toggle");
  const siteNav = document.getElementById("site-nav");
  const workButton = document.getElementById("work-button");
  const workMenu = document.getElementById("work-menu");

  function setExpanded(button, open) {
    button.setAttribute("aria-expanded", open ? "true" : "false");
  }

  function closeWorkMenu() {
    if (!workMenu || workMenu.hidden) { return; }
    workMenu.hidden = true;
    setExpanded(workButton, false);
  }

  function closeNav() {
    if (!siteNav) { return; }
    siteNav.classList.remove("open");
    setExpanded(navToggle, false);
    closeWorkMenu();
  }

  if (workButton && workMenu) {
    workButton.addEventListener("click", function () {
      const willOpen = workMenu.hidden;
      workMenu.hidden = !willOpen;
      setExpanded(workButton, willOpen);
    });
  }

  if (navToggle && siteNav) {
    navToggle.addEventListener("click", function () {
      const willOpen = !siteNav.classList.contains("open");
      siteNav.classList.toggle("open", willOpen);
      setExpanded(navToggle, willOpen);
      if (!willOpen) { closeWorkMenu(); }
    });
  }

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Escape") { return; }
    if (workMenu && !workMenu.hidden) {
      closeWorkMenu();
      workButton.focus();
    } else if (siteNav && siteNav.classList.contains("open")) {
      closeNav();
      navToggle.focus();
    }
  });

  document.addEventListener("click", function (event) {
    const header = event.target.closest(".site-header");
    if (!header) { closeNav(); }
  });

  /* The menu is a dropdown on wide screens and a panel on narrow ones; reset the
     state when crossing between them so nothing is left stranded open. */
  window.addEventListener("resize", closeNav);

  /* ------------------------------------------------------------- pricing estimate */

  const form = document.getElementById("booking-form");

  if (form) {
    /* Hand validation over to this script only once it is running. Without it the
       browser's own required/type checks stay in charge. */
    form.noValidate = true;

    const FORM_ENDPOINT = form.getAttribute("action") || "";
    const packageSelect = document.getElementById("package");
    const peopleInput = document.getElementById("people");
    const estimateTotal = document.getElementById("estimate-total");
    const estimateMath = document.getElementById("estimate-math");
    const formWrap = document.getElementById("book-form-wrap");
    const formStatus = document.getElementById("form-status");

    /* Prices come from the markup so the page has one source of truth: the <option>
       data-price attributes, and data-extra-person on the form. Change them there. */
    const PACKAGE_PRICES = {};
    Array.prototype.forEach.call(packageSelect.options, function (option) {
      if (option.value) { PACKAGE_PRICES[option.value] = Number(option.dataset.price); }
    });
    const EXTRA_PERSON = Number(form.dataset.extraPerson) || 100;

    function updateEstimate() {
      const base = PACKAGE_PRICES[packageSelect.value];
      const people = parseInt(peopleInput.value, 10);

      if (!base || !people || people < 1) {
        estimateTotal.textContent = "From $300";
        estimateMath.textContent = "Choose a package and the number of people to see your total.";
        return;
      }

      const extra = people - 1;
      const total = base + extra * EXTRA_PERSON;
      estimateTotal.textContent = "$" + total.toLocaleString("en-US");
      estimateMath.textContent = extra === 0
        ? "$" + base + " package for one person."
        : "$" + base + " package + " + extra + " additional " +
          (extra === 1 ? "person" : "people") + " × $" + EXTRA_PERSON + ".";
    }

    packageSelect.addEventListener("change", updateEstimate);
    peopleInput.addEventListener("input", updateEstimate);
    updateEstimate();

    document.querySelectorAll(".package-link").forEach(function (link) {
      link.addEventListener("click", function () {
        packageSelect.value = link.dataset.package;
        updateEstimate();
        clearError(packageSelect);
      });
    });

    /* ----------------------------------------------------------------- validation */

    const RULES = [
      { el: document.getElementById("name"), test: function (v) { return v.trim().length > 0; },
        message: "Please enter your name." },
      { el: document.getElementById("email"), test: function (v) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()); },
        message: "Please enter an email address so I can reply." },
      { el: document.getElementById("session-type"), test: function (v) { return v !== ""; },
        message: "Please choose a session type." },
      { el: packageSelect, test: function (v) { return v !== ""; },
        message: "Please choose a package." },
      { el: peopleInput, test: function (v) { return /^\d+$/.test(v.trim()) && parseInt(v, 10) >= 1; },
        message: "Please enter how many people will be in the session (1 or more)." }
    ];

    function showError(el, message) {
      const error = document.getElementById(el.id + "-error");
      el.closest(".field").classList.add("invalid");
      el.setAttribute("aria-invalid", "true");
      error.textContent = message;
      error.hidden = false;
    }

    function clearError(el) {
      const error = document.getElementById(el.id + "-error");
      el.closest(".field").classList.remove("invalid");
      el.removeAttribute("aria-invalid");
      error.textContent = "";
      error.hidden = true;
    }

    RULES.forEach(function (rule) {
      const handler = function () {
        if (rule.test(rule.el.value)) { clearError(rule.el); }
      };
      rule.el.addEventListener("input", handler);
      rule.el.addEventListener("change", handler);
    });

    function validate() {
      let firstInvalid = null;
      RULES.forEach(function (rule) {
        if (rule.test(rule.el.value)) {
          clearError(rule.el);
        } else {
          showError(rule.el, rule.message);
          if (!firstInvalid) { firstInvalid = rule.el; }
        }
      });
      return firstInvalid;
    }

    function showSent() {
      const sent = document.createElement("div");
      sent.className = "sent";
      sent.tabIndex = -1;
      const heading = document.createElement("h3");
      heading.textContent = "Request sent";
      const line = document.createElement("p");
      line.textContent = "Thanks! I’ll reach out soon to confirm your date and location.";
      sent.append(heading, line);
      formWrap.replaceChildren(sent);
      sent.focus();
    }

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      formStatus.textContent = "";

      const firstInvalid = validate();
      if (firstInvalid) {
        firstInvalid.focus();
        return;
      }

      const submitButton = form.querySelector(".btn-submit");
      submitButton.disabled = true;

      if (!FORM_ENDPOINT) {
        /* Concept state: nothing to post to yet, so confirm without sending. */
        showSent();
        return;
      }

      fetch(FORM_ENDPOINT, {
        method: "POST",
        headers: { "Accept": "application/json" },
        body: new FormData(form)
      }).then(function (response) {
        if (!response.ok) { throw new Error("Request failed: " + response.status); }
        showSent();
      }).catch(function () {
        submitButton.disabled = false;
        formStatus.textContent =
          "Sorry — that request didn’t send. Please try again in a moment.";
      });
    });
  }

  /* --------------------------------------------------------------------- lightbox */

  /* Shared by the session-page photo grids and the home page carousel below —
     each supplies its own photo list and its own trigger(s); everything else
     (keyboard, swipe, focus return, backdrop close) behaves identically either
     way. Returns null if there is nothing to wire it to. */
  function wireLightbox(photos, triggerSpecs) {
    const lightbox = document.getElementById("lightbox");
    if (!photos.length || !lightbox || typeof lightbox.showModal !== "function") {
      return null;
    }
    const lightboxImage = document.getElementById("lightbox-image");
    const lightboxSource = document.getElementById("lightbox-source");
    const counter = document.getElementById("lightbox-counter");
    let current = 0;
    let opener = null;

    function render(index) {
      current = (index + photos.length) % photos.length;
      const photo = photos[current];
      lightboxSource.srcset = photo.webp;
      lightboxImage.src = photo.jpg;
      lightboxImage.alt = photo.alt;
      counter.textContent = (current + 1) + " of " + photos.length;
    }

    function open(index, trigger) {
      opener = trigger || null;
      render(index);
      lightbox.showModal();
    }

    triggerSpecs.forEach(function (spec) {
      spec.el.addEventListener("click", function () {
        open(typeof spec.index === "function" ? spec.index() : spec.index, spec.el);
      });
    });

    document.getElementById("lightbox-prev").addEventListener("click", function () { render(current - 1); });
    document.getElementById("lightbox-next").addEventListener("click", function () { render(current + 1); });
    document.getElementById("lightbox-close").addEventListener("click", function () { lightbox.close(); });

    lightbox.addEventListener("keydown", function (event) {
      if (event.key === "ArrowLeft") { event.preventDefault(); render(current - 1); }
      if (event.key === "ArrowRight") { event.preventDefault(); render(current + 1); }
    });

    /* Clicking the backdrop (outside the image column) closes the viewer. */
    lightbox.addEventListener("click", function (event) {
      if (event.target === lightbox) { lightbox.close(); }
    });

    lightbox.addEventListener("close", function () {
      if (opener) { opener.focus(); opener = null; }
    });

    let touchStartX = null;
    lightbox.addEventListener("touchstart", function (event) {
      touchStartX = event.changedTouches[0].clientX;
    }, { passive: true });

    lightbox.addEventListener("touchend", function (event) {
      if (touchStartX === null) { return; }
      const dx = event.changedTouches[0].clientX - touchStartX;
      if (Math.abs(dx) > 40) { render(dx < 0 ? current + 1 : current - 1); }
      touchStartX = null;
    }, { passive: true });

    return { open: open };
  }

  const workCarousel = document.getElementById("work-carousel");

  if (workCarousel) {
    wireCarousel(workCarousel);
  } else {
    /* Session pages: unchanged from before this was extracted into a function —
       same >= 4 threshold, same graceful removal below it. */
    const shots = Array.prototype.slice.call(document.querySelectorAll(".shot"));
    const lightbox = document.getElementById("lightbox");

    if (shots.length >= 4 && lightbox) {
      const photos = shots.map(function (shot) {
        const img = shot.querySelector("img");
        const src = img.getAttribute("src");
        return {
          jpg: shot.dataset.full || src.replace("-800.jpg", "-1600.jpg"),
          webp: shot.dataset.fullWebp || src.replace("-800.jpg", "-1600.webp"),
          alt: img.getAttribute("alt")
        };
      });
      wireLightbox(photos, shots.map(function (shot, index) { return { el: shot, index: index }; }));
    } else if (lightbox) {
      lightbox.remove();
      shots.forEach(function (shot) { shot.replaceWith.apply(shot, shot.childNodes); });
    }
  }

  /* ------------------------------------------------------------------ carousel */

  /* One photo at a time, right to left, autoplaying with full visitor control.
     Clicking the current photo opens it in the same lightbox used elsewhere,
     starting at whatever the carousel is showing; the lightbox then browses
     the complete set, same as the grid does on session pages. */
  function wireCarousel(root) {
    const dataEl = document.getElementById("work-carousel-photos");
    const photos = dataEl ? JSON.parse(dataEl.textContent) : [];
    if (photos.length < 2) { return; }

    const stage = document.getElementById("carousel-stage");
    const slide = document.getElementById("carousel-slide");
    const prevBtn = document.getElementById("carousel-prev");
    const nextBtn = document.getElementById("carousel-next");
    const playBtn = document.getElementById("carousel-play");
    const playIcon = document.getElementById("carousel-play-icon");
    const counter = document.getElementById("carousel-counter");
    const INTERVAL_MS = 5000;
    const DECODE_CAP_MS = 800;
    const CONTROLS_MS = 4000;

    const layers = ["a", "b"].map(function (letter) {
      return {
        el: document.getElementById("carousel-layer-" + letter),
        source: document.getElementById("carousel-source-" + letter),
        img: document.getElementById("carousel-image-" + letter),
        holds: 0 /* which photo this layer currently has loaded */
      };
    });

    const reduceMotion = window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const canHover = !window.matchMedia || window.matchMedia("(hover: hover)").matches;

    let active = 0;   /* which layer is on screen */
    let index = 0;    /* the photo on screen */
    let queued = 0;   /* the photo the newest transition is heading for */
    let playing = false;
    let timer = null;
    let seq = 0;      /* lets a newer transition discard an older one's result */

    function load(layer, photoIndex) {
      if (layer.holds === photoIndex) { return; }
      const photo = photos[photoIndex];
      layer.source.srcset = photo.webp800 + " 800w, " + photo.webp1600 + " 1600w";
      layer.img.srcset = photo.jpg800 + " 800w, " + photo.jpg1600 + " 1600w";
      layer.img.src = photo.jpg800;
      layer.img.alt = photo.alt;
      layer.img.width = photo.w;
      layer.img.height = photo.h;
      layer.holds = photoIndex;
    }

    /* Resolves once the layer's photo can be painted on the very next frame.
       The cap keeps one slow or broken file from stalling the slideshow: the
       worst case is that it fades in a beat early, which is what the previous
       version did on every single change. */
    function ready(layer) {
      const decoded = layer.img.decode
        ? layer.img.decode().catch(function () {})
        : Promise.resolve();
      return Promise.race([decoded, new Promise(function (resolve) {
        window.setTimeout(resolve, DECODE_CAP_MS);
      })]);
    }

    /* Swaps which layer is on screen. Everything here runs in one frame, with
       the incoming photo already decoded, so the change reads as a single
       crossfade instead of the old photo showing through the animation. */
    function swap(direction) {
      const incoming = layers[1 - active];
      const outgoing = layers[active];

      incoming.el.classList.add("no-anim");
      incoming.el.classList.remove("from-next", "from-prev");
      outgoing.el.classList.remove("from-next", "from-prev");
      if (direction && !reduceMotion) {
        /* The new photo settles in from the side it came from; the old one
           drifts out the other way. */
        incoming.el.classList.add(direction === "next" ? "from-next" : "from-prev");
        outgoing.el.classList.add(direction === "next" ? "from-prev" : "from-next");
      }
      void incoming.el.offsetWidth; /* land the starting offset without animating it */
      incoming.el.classList.remove("no-anim");

      outgoing.el.classList.remove("is-current");
      outgoing.el.setAttribute("aria-hidden", "true");
      incoming.el.classList.add("is-current");
      incoming.el.removeAttribute("aria-hidden");
      active = 1 - active;
    }

    function show(photoIndex, direction) {
      const to = (photoIndex + photos.length) % photos.length;
      const token = ++seq;
      const incoming = layers[1 - active];
      queued = to;

      /* If this layer is still fading out from the last change, cut the fade
         dead before reusing it — otherwise loading the next photo into it
         would swap the picture mid-fade, in plain view. */
      incoming.el.classList.add("no-anim");
      void incoming.el.offsetWidth;

      load(incoming, to);
      ready(incoming).then(function () {
        if (token !== seq) { return; } /* a newer change already took over */
        index = to;
        swap(direction);
        counter.textContent = (index + 1) + " of " + photos.length;
        /* Park the photo after this one on the now-idle layer so the next
           change has nothing left to fetch or decode. The wait outlasts the
           crossfade, which is still showing that layer. */
        window.setTimeout(function () {
          if (token === seq) { load(layers[1 - active], (index + 1) % photos.length); }
        }, 700);
      });
    }

    function stopAutoplay() {
      if (timer) { window.clearInterval(timer); timer = null; }
    }

    function setPlaying(value) {
      playing = value;
      playIcon.textContent = playing ? "❙❙" : "▶";
      playBtn.setAttribute("aria-label", playing ? "Pause slideshow" : "Play slideshow");
      playBtn.setAttribute("aria-pressed", playing ? "true" : "false");
      /* Don't make the counter a live region while it's changing on its own
         every few seconds — that would read out to screen readers on a timer
         nobody asked for. It becomes live once the visitor takes control. */
      counter.setAttribute("aria-live", playing ? "off" : "polite");
      stopAutoplay();
      if (playing) { timer = window.setInterval(function () { show(queued + 1, "next"); }, INTERVAL_MS); }
    }

    /* Manual interaction stops autoplay for good, matching normal carousel
       etiquette: once a visitor takes the wheel, it stays theirs. */
    function manual(direction) {
      show(queued + (direction === "next" ? 1 : -1), direction);
      if (playing) { setPlaying(false); }
    }

    /* The controls sit on the photo and stay invisible until someone reaches
       for them. Hover and keyboard focus are handled in CSS; this covers touch,
       where there is no hover to reveal them with. */
    let hideControls = null;
    function flashControls() {
      if (canHover) { return; } /* hover and focus already handle it in CSS */
      stage.classList.add("controls-visible");
      if (hideControls) { window.clearTimeout(hideControls); }
      hideControls = window.setTimeout(function () {
        stage.classList.remove("controls-visible");
      }, CONTROLS_MS);
    }

    prevBtn.addEventListener("click", function () { manual("prev"); flashControls(); });
    nextBtn.addEventListener("click", function () { manual("next"); flashControls(); });
    playBtn.addEventListener("click", function () { setPlaying(!playing); flashControls(); });

    if (!canHover) {
      /* Registered before the lightbox's own handler below, so it can take the
         first tap: on a touch screen that tap brings the controls up rather
         than jumping straight into the photo viewer. */
      slide.addEventListener("click", function (event) {
        const alreadyUp = stage.classList.contains("controls-visible");
        flashControls();
        if (!alreadyUp) {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
      });
    }

    let touchStartX = null;
    root.addEventListener("touchstart", function (event) {
      touchStartX = event.changedTouches[0].clientX;
    }, { passive: true });
    root.addEventListener("touchend", function (event) {
      if (touchStartX === null) { return; }
      const dx = event.changedTouches[0].clientX - touchStartX;
      if (Math.abs(dx) > 40) { manual(dx < 0 ? "next" : "prev"); flashControls(); }
      touchStartX = null;
    }, { passive: true });

    root.addEventListener("keydown", function (event) {
      if (event.key === "ArrowLeft") { event.preventDefault(); manual("prev"); }
      if (event.key === "ArrowRight") { event.preventDefault(); manual("next"); }
    });

    /* The second photo waits until the page itself has finished loading — a
       carousel below the fold has no business competing with the hero for
       bandwidth, and autoplay doesn't move for another five seconds. */
    function primeSecond() {
      window.setTimeout(function () {
        if (seq === 0) { load(layers[1 - active], 1); }
      }, 400);
    }
    if (document.readyState === "complete") { primeSecond(); }
    else { window.addEventListener("load", primeSecond); }

    setPlaying(!reduceMotion); /* never autostart motion someone asked to reduce */

    wireLightbox(
      photos.map(function (p) { return { jpg: p.jpg1600, webp: p.webp1600, alt: p.alt }; }),
      [{ el: slide, index: function () { return index; } }]
    );
  }
})();
