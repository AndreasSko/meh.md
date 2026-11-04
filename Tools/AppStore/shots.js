// Copy and layout for every App Store screenshot.
// *word* gets the highlighter, `code` a monospace font. Element positions are in canvas pixels,
// relative to the area below the headline.

const copy = {
  note: {
    h1: "Just *Markdown.*",
    sub: "The same `**bold**` and `- lists` you already know.",
  },
  recents: {
    h1: "Recent notes *and* folders.",
    sub: "What you worked on lately, right at the top. Everything else stays sorted in your folders.",
  },
  sync: {
    theme: "yellow",
    h1: "Sync, *boringly reliable.*",
    sub: "Across iPhone, iPad, and Mac, all through iCloud. No extra account, no subscription.",
  },
  history: {
    h1: "Rewrite *without worry.*",
    sub: "Scrub back through older versions and restore any of them.",
  },
  snippets: {
    h1: "*Snippets* for what you keep typing.",
    sub: "Like today's workout, in one tap. Templates do the same for whole new notes.",
  },
  widgets: {
    h1: "Notes on your *Home Screen.*",
    sub: "Pinned and recent notes, or one note you pick. The + starts a new one.",
  },
};

// The iPhone shows the snippets screen in dark mode, for some contrast.
const themes = { iphone: { snippets: "dark" } };

const center = "left:50%;top:50%;transform:translate(-50%,-50%)";

const layouts = {
  iphone: {
    note: [{ img: "iphone/iphone-note", frame: "phone", w: 980, css: center }],
    recents: [{ img: "iphone/iphone-library", frame: "phone", w: 980, css: center }],
    // The same note on the Mac and the iPhone
    sync: [
      { img: "mac/mac-library", frame: "mac", w: 1500, css: "left:-240px;top:110px" },
      { img: "iphone/iphone-review", frame: "phone", w: 680, css: "right:80px;bottom:80px" },
    ],
    history: [{ img: "iphone/iphone-history", frame: "phone", w: 980, css: center }],
    snippets: [{ img: "dark/iphone-snippets", frame: "phone", w: 980, css: center }],
    // Close-up: the phone runs off the bottom edge so the widgets read large
    widgets: [{ img: "iphone/iphone-widgets", frame: "phone", w: 1180, css: "left:50%;top:40px;transform:translateX(-50%)" }],
  },
  ipad: {
    // Close-up: the iPad runs off the right and bottom edge so the text reads large
    note: [{ img: "ipad/ipad-note", frame: "ipad", w: 2050, css: "left:200px;top:110px" }],
    // The sidebar on its own
    recents: [{ img: "ipad/ipad-library", crop: [0, 290, 560, 1390], scale: 1.45, plain: true, css: "left:50%;top:70px;transform:translateX(-50%)" }],
    // Same note on two devices
    sync: [
      { img: "ipad/ipad-library", frame: "ipad", w: 1500, css: "left:110px;top:70px" },
      { img: "iphone/iphone-review", frame: "phone", w: 640, css: "right:90px;bottom:90px" },
    ],
    // Magnified version scrubber over the device
    history: [
      { img: "ipad/ipad-history", frame: "ipad", w: 1500, css: center },
      { img: "ipad/ipad-history", crop: [1060, 2440, 540, 270], scale: 2.1, css: "left:50%;bottom:150px;transform:translateX(-50%)" },
    ],
    // Close-up of the note and the menu, without the keyboard
    snippets: [{ img: "ipad/ipad-snippets", crop: [545, 170, 1045, 1760], scale: 1.1, plain: true, css: "left:50%;top:60px;transform:translateX(-50%)" }],
    widgets: [{ img: "ipad/ipad-widgets", frame: "ipad", w: 2010, css: "left:50%;top:70px;transform:translateX(-50%)" }],
  },
  mac: {
    // Close-up of just the editor
    note: [{ img: "mac/mac-note", crop: [900, 90, 1460, 1360], scale: 0.97, plain: true, css: "left:50%;top:70px;transform:translateX(-50%)" }],
    // Magnified sidebar next to the window
    recents: [
      { img: "mac/mac-note", frame: "mac", w: 1900, css: "left:150px;top:60px" },
      { img: "mac/mac-note", crop: [0, 90, 560, 1010], scale: 1.3, css: "right:200px;top:20px" },
    ],
    sync: [
      { img: "mac/mac-library", frame: "mac", w: 1960, css: "left:230px;top:60px" },
      { img: "iphone/iphone-review", frame: "phone", w: 560, css: "right:250px;bottom:70px" },
    ],
    history: [
      { img: "mac/mac-history", frame: "mac", w: 2080, css: center },
      { img: "mac/mac-history", crop: [1470, 1480, 580, 315], scale: 1.75, css: "right:330px;bottom:90px" },
    ],
    // Magnified snippet menu over its spot in the toolbar
    snippets: [
      { img: "mac/mac-snippets", frame: "mac", w: 2080, css: center },
      { img: "mac/mac-snippets", crop: [1840, 110, 500, 240], scale: 2, css: "right:220px;top:30px" },
    ],
  },
};
