// Adds up times like the Labs time calculator, as a text rule: a line that
// ends in `=` shows the sum of the times above it, up to the previous `=`
// line or heading. It reads the same values and operators, described in
// docs/time-calculator.md, and shows what a rule that carries state from
// block to block can do.

(() => {
  const UNITS = { d: 86400, h: 3600, m: 60, s: 1 };
  const UNIT_ORDER = { d: 0, h: 1, m: 2, s: 3 };
  const MASK = "￼";

  const isDigit = (c) => c >= "0" && c <= "9";
  const isWord = (c) => c !== undefined && /[\p{L}\p{M}\p{N}_]/u.test(c);
  const isSpace = (c) => c === " " || c === "\t";

  // `1d 2h 5m`, `-3m`, or `0m`.
  function format(seconds) {
    if (seconds === 0) return "0m";
    let rest = Math.abs(seconds);
    const parts = [];
    for (const [unit, size] of Object.entries(UNITS)) {
      const count = Math.floor(rest / size);
      rest -= count * size;
      if (count > 0) parts.push(`${count}${unit}`);
    }
    return (seconds < 0 ? "-" : "") + parts.join(" ");
  }

  // The trailing `=` of a line, unless it closes `==highlight==`.
  function equalsSign(line) {
    let last = line.length;
    while (last > 0 && " \t\r\n".includes(line[last - 1])) last--;
    if (last === 0 || line[last - 1] !== "=") return -1;
    if (last > 1 && line[last - 2] === "=") return -1;
    return last - 1;
  }

  // A value starts at a word boundary, but not inside a number like `v1.5`.
  function canStartValue(line, index) {
    if (index === 0) return true;
    const previous = line[index - 1];
    // Like the built-in calculator, nothing after an emoji or other
    // character outside the basic plane counts.
    if (isWord(previous) || /[\uD800-\uDFFF]/.test(previous)) return false;
    if ((previous === "." || previous === ",") && index > 1 && isDigit(line[index - 2])) return false;
    return true;
  }

  function value(line, start, end) {
    let index = start;
    while (index < end && isDigit(line[index])) index++;
    if (index + 1 < end && (line[index] === "." || line[index] === ",") && isDigit(line[index + 1])) {
      index++;
      while (index < end && isDigit(line[index])) index++;
    }
    const amount = Number(line.slice(start, index).replace(",", "."));
    let unitAt = index;
    while (unitAt < end && isSpace(line[unitAt])) unitAt++;
    const unit = line[unitAt];
    if (unitAt >= end || !(unit in UNITS) || Number.isNaN(amount)) return null;
    const valueEnd = unitAt + 1;
    if (valueEnd < end && isWord(line[valueEnd]) && !isDigit(line[valueEnd])) return null;
    // State is JSON, which has no Infinity.
    const seconds = amount * UNITS[unit];
    if (!Number.isFinite(seconds)) return null;
    return { seconds, unit: UNIT_ORDER[unit], end: valueEnd };
  }

  rule({
    api: 1,
    name: "Time Calculator",
    description: "End a line with = to add up the times above it, like 1h 30m or 45m. Don’t use it in a note together with the Labs time calculator.",
    example: "Flight 2h 55m\nTaxi 25m\nTravel day =",
    runsIn: "chosenNotes",
    input: "plain",
    start: { total: 0, sign: 0 },
    block(block, state) {
      if (block.kind === "heading") return { state: { total: 0, sign: 0 } };
      let { total, sign } = state;
      const decorations = [];
      for (const line of block.lines) {
        const text = line.text;
        let group = null;
        const equals = equalsSign(text);
        const scanEnd = equals >= 0 ? equals : text.length;
        let index = 0;
        while (index < scanEnd) {
          const c = text[index];
          if (c === MASK) {
            // Code, links and list markers don't count, and don't end a sign.
            while (index < scanEnd && text[index] === MASK) index++;
            group = null;
            continue;
          }
          if (c === "+" || c === "-" || c === "−") {
            // `Mon-Fri` is a word, but in `7m-1h` the `-` follows a time.
            if (index === 0 || group?.end === index || !isWord(text[index - 1])) {
              sign = c === "+" ? 1 : -1;
            } else {
              sign = 0;
            }
            group = null;
            index++;
            continue;
          }
          if (isDigit(c) && (group?.end === index || canStartValue(text, index))) {
            const found = value(text, index, scanEnd);
            if (found) {
              const valueSign = group && sign === 0 && found.unit > group.unit
                ? group.sign : (sign || 1);
              const next = total + valueSign * found.seconds;
              if (Number.isFinite(next)) total = next;
              sign = 0;
              group = { end: found.end, sign: valueSign, unit: found.unit };
              index = found.end;
            } else {
              sign = 0;
              group = null;
              while (index < scanEnd && isWord(text[index])) index++;
            }
            continue;
          }
          if (!isSpace(c)) {
            sign = 0;
            group = null;
          }
          index++;
        }
        if (equals >= 0) {
          const rounded = Math.sign(total) * Math.round(Math.abs(total));
          decorations.push({
            kind: "insert", at: line.start + equals + 1, side: "after",
            text: " " + format(rounded), style: "muted",
            label: format(rounded),
          });
          total = 0;
          sign = 0;
        }
      }
      return { decorations, state: { total, sign } };
    },
  });
})();
