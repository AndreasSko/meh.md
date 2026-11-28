// Links Bible references written in German or English, such as
// `Johannes 3:16`, `Joh 3,16.18` or `1. Mose 1:1`, to the New World
// Translation in JW Library or on jw.org.
//
// A reference only becomes a link when its chapter and verse exist, so
// times like `Mark 2:30` or `Mi 10:30` stay plain text.
//
// Verse counts follow the KJV versification, which the New World
// Translation uses too. They come from OpenBible.info's Bible Passage
// Reference Parser: Copyright (c) 2011-2026 Stephen Smith, MIT License,
// in bible-passage-reference-parser-license.txt next to this script.

(() => {
  // Per book: German names, then English names. The first is the name
  // shown in labels; the rest are abbreviations and other spellings.
  const BOOKS = [
    ["1. Mose|1Mo|1 Mos|Genesis|Gen", "Genesis|Gen|Ge|Gn"],
    ["2. Mose|2Mo|2 Mos|Exodus|Ex", "Exodus|Exod|Ex"],
    ["3. Mose|3Mo|3 Mos|Levitikus|Lev", "Leviticus|Lev|Le"],
    ["4. Mose|4Mo|4 Mos|Numeri|Num", "Numbers|Num|Nu"],
    ["5. Mose|5Mo|5 Mos|Deuteronomium|Dtn", "Deuteronomy|Deut|De|Dt"],
    ["Josua|Jos", "Joshua|Josh|Jos"],
    ["Richter|Ri", "Judges|Judg|Jg"],
    ["Ruth|Rut|Ru", "Ruth|Ru"],
    ["1. Samuel|1Sa|1 Sam", "1 Samuel|1Sa|1 Sam"],
    ["2. Samuel|2Sa|2 Sam", "2 Samuel|2Sa|2 Sam"],
    ["1. Könige|1Kö|1 Kön", "1 Kings|1Ki|1 Kgs"],
    ["2. Könige|2Kö|2 Kön", "2 Kings|2Ki|2 Kgs"],
    ["1. Chronika|1Ch|1 Chr|1 Chronik", "1 Chronicles|1Ch|1 Chr|1 Chron"],
    ["2. Chronika|2Ch|2 Chr|2 Chronik", "2 Chronicles|2Ch|2 Chr|2 Chron"],
    ["Esra|Esr", "Ezra|Ezr"],
    ["Nehemia|Neh|Ne", "Nehemiah|Neh|Ne"],
    ["Esther|Est", "Esther|Esth|Est|Es"],
    ["Hiob|Ijob|Hi", "Job"],
    ["Psalm|Psalmen|Ps", "Psalms|Psalm|Psa|Ps"],
    ["Sprüche|Spr", "Proverbs|Prov|Pr"],
    ["Prediger|Kohelet|Pred|Koh|Pr", "Ecclesiastes|Eccl|Ec"],
    ["Hohes Lied|Hoheslied|Hoh|Hld", "Song of Solomon|Song of Songs|Song|Ca"],
    ["Jesaja|Jes", "Isaiah|Isa"],
    ["Jeremia|Jer", "Jeremiah|Jer"],
    ["Klagelieder|Klgl|Klg", "Lamentations|Lam|La"],
    ["Hesekiel|Ezechiel|Hes|Ez", "Ezekiel|Ezek|Eze"],
    ["Daniel|Dan|Da", "Daniel|Dan|Da"],
    ["Hosea|Hos", "Hosea|Hos|Ho"],
    ["Joel|Joe", "Joel|Joe"],
    ["Amos|Am", "Amos|Am"],
    ["Obadja|Obd|Ob", "Obadiah|Obad|Ob"],
    ["Jona|Jon", "Jonah|Jon"],
    ["Micha|Mi", "Micah|Mic"],
    ["Nahum|Nah", "Nahum|Nah|Na"],
    ["Habakuk|Hab", "Habakkuk|Hab"],
    ["Zephanja|Zef|Ze", "Zephaniah|Zeph|Zep"],
    ["Haggai|Hag", "Haggai|Hag"],
    ["Sacharja|Sach", "Zechariah|Zech|Zec"],
    ["Maleachi|Mal", "Malachi|Mal"],
    ["Matthäus|Matth|Mat|Mt", "Matthew|Matt|Mt"],
    ["Markus|Mark|Mar|Mk", "Mark|Mk|Mr"],
    ["Lukas|Luk|Lu|Lk", "Luke|Lu|Lk"],
    ["Johannes|Joh", "John|Joh|Jn"],
    ["Apostelgeschichte|Apg", "Acts|Ac"],
    ["Römer|Röm|Rö", "Romans|Rom|Ro"],
    ["1. Korinther|1Ko|1 Kor", "1 Corinthians|1Co|1 Cor"],
    ["2. Korinther|2Ko|2 Kor", "2 Corinthians|2Co|2 Cor"],
    ["Galater|Gal", "Galatians|Gal|Ga"],
    ["Epheser|Eph", "Ephesians|Eph"],
    ["Philipper|Phil|Php", "Philippians|Phil|Php"],
    ["Kolosser|Kol", "Colossians|Col"],
    ["1. Thessalonicher|1Th|1 Thess", "1 Thessalonians|1Th|1 Thess"],
    ["2. Thessalonicher|2Th|2 Thess", "2 Thessalonians|2Th|2 Thess"],
    ["1. Timotheus|1Ti|1 Tim", "1 Timothy|1Ti|1 Tim"],
    ["2. Timotheus|2Ti|2 Tim", "2 Timothy|2Ti|2 Tim"],
    ["Titus|Tit", "Titus|Tit"],
    ["Philemon|Phlm|Phm", "Philemon|Phlm|Phm"],
    ["Hebräer|Hebr|Heb", "Hebrews|Heb"],
    ["Jakobus|Jak", "James|Jas"],
    ["1. Petrus|1Pe|1 Petr", "1 Peter|1Pe|1 Pet"],
    ["2. Petrus|2Pe|2 Petr", "2 Peter|2Pe|2 Pet"],
    ["1. Johannes|1Jo|1 Joh", "1 John|1Jo|1 Jn"],
    ["2. Johannes|2Jo|2 Joh", "2 John|2Jo|2 Jn"],
    ["3. Johannes|3Jo|3 Joh", "3 John|3Jo|3 Jn"],
    ["Judas|Jud", "Jude"],
    ["Offenbarung|Offb|Off", "Revelation|Rev|Re"],
  ];

  // Verses per chapter, per book in the order above.
  const VERSES = [
    [31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26],
    [22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38],
    [17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34],
    [54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13],
    [46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12],
    [18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33],
    [36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25],
    [22,23,18,22],
    [28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13],
    [27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25],
    [53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53],
    [18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30],
    [54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30],
    [17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23],
    [11,70,13,24,17,22,28,36,15,44],
    [11,20,32,23,19,19,73,18,38,39,36,47,31],
    [22,23,15,17,14,14,10,17,32,3],
    [22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17],
    [6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6],
    [33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31],
    [18,26,22,16,20,12,29,17,18,20,10,14],
    [17,17,11,16,16,13,13,14],
    [31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24],
    [19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34],
    [22,22,66,22,22],
    [28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35],
    [21,49,30,37,31,28,28,27,27,21,45,13],
    [11,23,5,19,15,11,16,14,17,15,12,14,16,9],
    [20,32,21],
    [15,16,15,13,27,14,17,14,15],
    [21],
    [17,10,10,11],
    [16,13,12,13,15,16,20],
    [15,13,19],
    [17,20,19],
    [18,15,20],
    [15,23],
    [21,13,10,14,11,15,14,23,17,12,17,14,9,21],
    [14,17,18,6],
    [25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20],
    [45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20],
    [80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53],
    [51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25],
    [26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31],
    [32,29,31,25,21,23,25,39,33,21,36,21,14,23,33,27],
    [31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24],
    [24,17,18,18,21,18,16,24,15,18,33,21,14],
    [24,21,29,31,26,18],
    [23,22,21,32,33,24],
    [30,30,21,23],
    [29,23,25,18],
    [10,20,13,18,28],
    [12,17,18],
    [20,15,16,16,25,21],
    [18,26,17,22],
    [16,15,15],
    [25],
    [14,18,19,16,14,20,28,13,28,39,40,29,25],
    [27,26,18,17,20],
    [25,25,22,19,14],
    [21,22,18],
    [10,29,24,21,21],
    [13],
    [14],
    [25],
    [20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21],
  ];

  // Book names that are also first names or words. They only link with a
  // verse, so `Ruth 2` or `Daniel 3` in a list of people stay plain.
  const NAMES = new Set([
    "Acts", "Amos", "Daniel", "Esra", "Esther", "Ezra", "Hosea", "James",
    "Jakobus", "Job", "Joel", "John", "Johannes", "Jona", "Jonah", "Judges",
    "Lukas", "Luke", "Mark", "Markus", "Micah", "Micha", "Nahum", "Numbers",
    "Richter", "Ruth", "Song", "Titus",
  ]);

  // Short abbreviations that are also common words, like German `Da` or
  // `Ob`. They only link as `Da 2:44`, with a colon.
  const STRICT = new Set(["Am", "Da", "De", "Es", "Ex", "Hi", "Mi", "Ne", "Ob"]);

  const LOCALE = { de: "X", en: "E" };
  const LANGUAGES = ["de", "en"];

  const space = "[\\s\\u00A0\\u202F]";
  const dash = `${space}?[-–—]${space}?`;

  // "number|stem" in lower case -> every alias it can stand for.
  const aliases = new Map();
  const stems = new Set();
  BOOKS.forEach((names, index) => {
    LANGUAGES.forEach((language, column) => {
      for (const alias of names[column].split("|")) {
        const numbered = /^([1-5])\.?\s?(.+)$/.exec(alias);
        const number = numbered ? numbered[1] : "";
        const stem = numbered ? numbered[2] : alias;
        const key = `${number}|${stem.toLowerCase()}`;
        if (!aliases.has(key)) aliases.set(key, []);
        aliases.get(key).push({ book: index + 1, language, stem });
        stems.add(stem);
      }
    });
  });

  const stemPattern = [...stems]
    .sort((a, b) => b.length - a.length)
    .map((stem) => stem.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/ /g, `${space}+`))
    .join("|");

  // 1 number, 2 book, 3 chapter, 4 separator, 5 verse, 6 f/ff,
  // 7 range end (verse, or chapter when 8 is set), 8 range end verse.
  const REFERENCE = new RegExp(
    `(?<![\\p{L}\\p{N}])(?:([1-5])\\.?${space}?)?(${stemPattern})(?!\\p{L})\\.?${space}?` +
      `(\\d{1,3})(?:([:,])(\\d{1,3})(ff?(?!\\p{L}))?(?:${dash}(\\d{1,3})(?:[:,](\\d{1,3}))?)?)?` +
      `(?!\\d|:\\d)`,
    "giud"
  );

  // What may follow a reference: `, 18`, `; 4:2`, or `.18` and `; 4,2`
  // when the reference used a comma. 1 separator, 2 chapter or verse,
  // 3 verse, 4 f/ff, 5 range end, 6 range end verse.
  const MORE = {
    ":": new RegExp(
      `(${space}*[,;]${space}*)(\\d{1,3})(?::(\\d{1,3}))?(ff?(?!\\p{L}))?` +
        `(?:${dash}(\\d{1,3})(?::(\\d{1,3}))?)?(?!\\d|[:,]\\d)`,
      "yu"
    ),
    ",": new RegExp(
      `(\\.|${space}*;${space}*)(\\d{1,3})(?:,(\\d{1,3}))?(ff?(?!\\p{L}))?` +
        `(?:${dash}(\\d{1,3})(?:,(\\d{1,3}))?)?(?!\\d|[.,]\\d)`,
      "yu"
    ),
  };

  // A time right after the numbers, as in `Am 3:15 Uhr`.
  const TIME = /^[\s\u00A0]?(?:Uhr|h|am|pm|a\.m\.|p\.m\.|min)(?!\p{L})/iu;

  function chapters(book) {
    return VERSES[book - 1];
  }

  function exists(book, chapter, verse) {
    const counts = chapters(book);
    return chapter >= 1 && chapter <= counts.length &&
      (verse === 0 || (verse >= 1 && verse <= counts[chapter - 1]));
  }

  function code(book, chapter, verse) {
    return String(book).padStart(2, "0") + String(chapter).padStart(3, "0") +
      String(verse).padStart(3, "0");
  }

  function isCapitalized(text) {
    const first = text[0];
    return first !== first.toLowerCase() && first === first.toUpperCase();
  }

  // The alias a match stands for, or nothing when its case, its
  // separator or the reading language rule it out.
  function alias(number, written, separator, hasVerse, options) {
    if (!isCapitalized(written)) return null;
    const short = written.length <= 3;
    if (short && STRICT.has(written) && (separator !== ":" || !hasVerse)) return null;
    let candidates = (aliases.get(`${number}|${written.toLowerCase()}`) ?? []).filter(
      (candidate) =>
        (!short || candidate.stem === written) &&
        // English never writes `John 3,16`.
        (candidate.language === "de" || separator !== ",")
    );
    if (candidates.length === 0) return null;
    if (options.language !== "auto") {
      const preferred = candidates.filter((c) => c.language === options.language);
      if (preferred.length > 0) candidates = preferred;
    }
    const books = new Set(candidates.map((c) => c.book));
    const chosen =
      candidates.find((c) => c.language === options.preferred) ?? candidates[0];
    // A name both languages share, like `Ruth` or `Ps`, reads in the
    // preferred language. So does a name that means different books,
    // like `Pr`: Proverbs in English, Ecclesiastes (Prediger) in German.
    const language =
      options.language !== "auto" ? options.language
      : books.size > 1 || candidates.some((c) => c.language !== chosen.language)
        ? options.preferred
        : chosen.language;
    return { book: chosen.book, language, stem: chosen.stem };
  }

  function name(book, language) {
    return BOOKS[book - 1][LANGUAGES.indexOf(language)].split("|")[0];
  }

  function link(start, end, book, language, from, to, options) {
    const [chapter, verse] = from;
    const bible = to ? `${code(book, ...from)}-${code(book, ...to)}` : code(book, chapter, verse);
    const query = `wtlocale=${LOCALE[language]}&prefer=lang&bible=${bible}&pub=nwtsty`;
    const url = options.open === "web"
      ? `https://www.jw.org/finder?${query}`
      : `jwlibrary:///finder?bible=${bible}&wtlocale=${LOCALE[language]}`;
    let label = `${name(book, language)} ${chapter}`;
    if (verse > 0) label += `:${verse}`;
    if (to) label += to[0] === chapter ? `–${to[1]}` : `–${to[0]}:${to[1]}`;
    return { kind: "link", start, end, url, label };
  }

  // The end of a range, or nothing when there is none or it is invalid.
  function rangeEnd(book, chapter, verse, suffix, endA, endB) {
    if (suffix === "f") return exists(book, chapter, verse + 1) ? [chapter, verse + 1] : undefined;
    if (suffix === "ff") return [chapter, chapters(book)[chapter - 1]];
    if (endA === undefined) return undefined;
    const end = endB === undefined ? [chapter, Number(endA)] : [Number(endA), Number(endB)];
    const after = end[0] > chapter || (end[0] === chapter && end[1] > verse);
    return after && end[1] > 0 && exists(book, ...end) ? end : null;
  }

  function references(text, options) {
    const found = [];
    const matches = [...text.matchAll(REFERENCE)];
    matches.forEach((match, index) => {
      const nextStart = matches[index + 1]?.index ?? text.length;
      let start = match.index;
      let number = match[1] ?? "";
      const written = match[2].replace(/[\s\u00A0\u202F]+/g, " ");
      const separator = match[4];
      const hasVerse = match[5] !== undefined;
      let matched = alias(number, written, separator, hasVerse, options);
      // `5 Joh 3:16` is not a book called "5 Joh"; try `Joh 3:16`.
      if (!matched && number) {
        matched = alias("", written, separator, hasVerse, options);
        number = "";
        start = match.indices[2][0];
      }
      if (!matched) return;
      const { book, language, stem } = matched;
      if (TIME.test(text.slice(match.index + match[0].length))) return;

      let chapter = Number(match[3]);
      let verse = hasVerse ? Number(match[5]) : 0;
      const singleChapter = chapters(book).length === 1;
      const fullName = number !== "" || stem.length >= 4;
      if (!hasVerse) {
        if (!fullName) return;
        if (singleChapter) {
          // `Judas 3` is verse 3; the book has one chapter.
          [chapter, verse] = [1, chapter];
        } else if (NAMES.has(stem)) {
          return;
        }
      }
      // Verse 0 means a whole chapter, but only when no verse was written.
      if ((hasVerse && verse === 0) || !exists(book, chapter, verse)) return;
      const end = hasVerse ? rangeEnd(book, chapter, verse, match[6], match[7], match[8]) : undefined;
      if (end === null) return;
      found.push(link(start, match.index + match[0].length, book, language,
        [chapter, verse], end, options));
      if (!hasVerse) return;

      // More verses and chapters of the same book.
      const more = MORE[separator];
      more.lastIndex = match.index + match[0].length;
      let lastChapter = end ? end[0] : chapter;
      let lastVerse = end ? end[1] : verse;
      for (let next; (next = more.exec(text)) && next.index < nextStart;) {
        const numberStart = next.index + next[1].length;
        const nextEnd = next.index + next[0].length;
        if (TIME.test(text.slice(nextEnd))) break;
        const newChapter = next[3] !== undefined;
        if (next[1].trim() === ";" && !newChapter) break;
        const from = newChapter ? [Number(next[2]), Number(next[3])] : [lastChapter, Number(next[2])];
        // `Joh 3:16, 5 Leute` lists nothing: verses only go forward.
        if (!newChapter && from[1] <= lastVerse) break;
        if (from[1] === 0 || !exists(book, ...from)) break;
        const to = rangeEnd(book, ...from, next[4], next[5], next[6]);
        if (to === null) break;
        found.push(link(numberStart, nextEnd, book, language, from, to, options));
        [lastChapter, lastVerse] = to ?? from;
        more.lastIndex = nextEnd;
      }
    });
    return found;
  }

  rule({
    api: 1,
    name: "Bible References",
    description: "Links references like John 3:16 or Joh 3,16 to the Bible in JW Library or on jw.org. Reads German and English book names. A name both languages use, like Genesis, follows Ambiguous Names.",
    example: "Today’s text: John 3:16. Also read Psalm 23 and Röm 8:28, 38.",
    linksTo: ["jwlibrary:///finder?", "https://www.jw.org/finder?"],
    input: "plain",
    // Paragraphs without a digit never reach the script.
    trigger: "\\d",
    uses: ["locale"],
    options: {
      open: {
        title: "Open In",
        type: "choice",
        choices: { app: "JW Library", web: "jw.org" },
        default: "app",
      },
      language: {
        title: "Bible Language",
        type: "choice",
        choices: { auto: "Match the Reference", de: "Deutsch", en: "English" },
        default: "auto",
      },
      preferred: {
        title: "Ambiguous Names",
        type: "choice",
        choices: { auto: "Device Language", de: "Deutsch", en: "English" },
        default: "auto",
      },
    },
    block(block, state, context) {
      const options = { ...context.options };
      // Names both languages write the same, like Genesis or Ruth.
      if (options.preferred === "auto") {
        options.preferred = String(context.locale).startsWith("de") ? "de" : "en";
      }
      return { decorations: references(block.text, options) };
    },
  });
})();
