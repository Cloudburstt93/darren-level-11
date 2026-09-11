/* MBJ Photo — redesign concept by HardyWired Tech */

/* Where the booking form posts. Paste a form endpoint URL here to make the form live —
   a Formspree endpoint (https://formspree.io/f/xxxxxxx) or a Web3Forms endpoint
   (https://api.web3forms.com/submit, with your access key added as a hidden field).
   While this is an empty string the form validates and shows its success state without
   sending anything, which is what the concept build ships with. */
const FORM_ENDPOINT = "";

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

  const shots = Array.prototype.slice.call(document.querySelectorAll(".shot"));
  const lightbox = document.getElementById("lightbox");

  if (shots.length >= 4 && lightbox && typeof lightbox.showModal === "function") {
    const lightboxImage = document.getElementById("lightbox-image");
    const lightboxSource = document.getElementById("lightbox-source");
    const counter = document.getElementById("lightbox-counter");
    let current = 0;
    let opener = null;

    const photos = shots.map(function (shot) {
      const img = shot.querySelector("img");
      const src = img.getAttribute("src");
      return {
        jpg: shot.dataset.full || src.replace("-800.jpg", "-1600.jpg"),
        webp: shot.dataset.fullWebp || src.replace("-800.jpg", "-1600.webp"),
        alt: img.getAttribute("alt")
      };
    });

    function render(index) {
      current = (index + photos.length) % photos.length;
      const photo = photos[current];
      lightboxSource.srcset = photo.webp;
      lightboxImage.src = photo.jpg;
      lightboxImage.alt = photo.alt;
      counter.textContent = (current + 1) + " of " + photos.length;
    }

    function open(index, trigger) {
      opener = trigger;
      render(index);
      lightbox.showModal();
    }

    shots.forEach(function (shot, index) {
      shot.addEventListener("click", function () { open(index, shot); });
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
  } else if (lightbox) {
    lightbox.remove();
    shots.forEach(function (shot) { shot.replaceWith.apply(shot, shot.childNodes); });
  }
})();
