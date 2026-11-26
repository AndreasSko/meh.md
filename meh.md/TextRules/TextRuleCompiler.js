// Prepares a text rule before it runs, in a JavaScriptCore context that
// also holds acorn. It reads the rule's settings without running any of its
// code, and adds a check to every loop and function so a rule that runs
// too long can be stopped (`__meh_tick`, defined by TextRuleRuntime.js).
//
// compileTextRule(source) returns JSON: { manifest, source } on success, or
// { error: { message, line, column } }.

(() => {
  const RESERVED = "__meh";

  class RuleError extends Error {
    constructor(message, node) {
      super(message);
      this.line = node?.loc?.start.line;
      this.column = node?.loc?.start.column;
    }
  }

  function children(node) {
    const result = [];
    for (const key of Object.keys(node)) {
      if (key === "loc" || key === "start" || key === "end") continue;
      const value = node[key];
      if (Array.isArray(value)) {
        for (const item of value) if (item && typeof item.type === "string") result.push(item);
      } else if (value && typeof value.type === "string") {
        result.push(value);
      }
    }
    return result;
  }

  function walk(node, visit, depth = 0) {
    visit(node, depth);
    for (const child of children(node)) walk(child, visit, depth + 1);
  }

  // A plain value: what JSON can hold, written out in the source.
  function literal(node, what) {
    switch (node.type) {
      case "Literal":
        if (node.regex || typeof node.value === "bigint") break;
        return node.value;
      case "TemplateLiteral":
        if (node.expressions.length === 0) return node.quasis[0].value.cooked;
        break;
      case "UnaryExpression":
        if (node.operator === "-" && node.argument.type === "Literal"
            && typeof node.argument.value === "number") return -node.argument.value;
        break;
      case "ArrayExpression":
        return node.elements.map((element) => {
          if (!element || element.type === "SpreadElement") {
            throw new RuleError(`${what} must be written out as a plain value.`, node);
          }
          return literal(element, what);
        });
      case "ObjectExpression": {
        const object = {};
        for (const property of node.properties) {
          object[propertyName(property, what)] = literal(property.value, what);
        }
        return object;
      }
    }
    throw new RuleError(`${what} must be written out as a plain value.`, node);
  }

  function propertyName(property, what) {
    if (property.type !== "Property" || property.computed || property.kind !== "init") {
      throw new RuleError(`${what} must be written out as a plain value.`, property);
    }
    if (property.key.type === "Identifier") return property.key.name;
    if (property.key.type === "Literal") return String(property.key.value);
    throw new RuleError(`${what} must be written out as a plain value.`, property);
  }

  const SETTINGS = new Set([
    "api", "name", "description", "example", "runsIn", "linksTo", "input", "blocks", "trigger",
    "uses", "options", "start",
  ]);

  // Entries in the order they're written. JavaScript objects list keys
  // that look like numbers first, so read the source, not an object.
  function entries(node, what) {
    if (node.type !== "ObjectExpression") {
      throw new RuleError(`${what} must be an object.`, node);
    }
    return node.properties.map((property) => [propertyName(property, what), property.value]);
  }

  function options(node) {
    return entries(node, "options").map(([key, value]) => {
      const option = { key };
      for (const [name, field] of entries(value, `Option “${key}”`)) {
        if (name === "key") {
          throw new RuleError(`Option “${key}” is named by its key in options, not by a key field.`, field);
        }
        option[name] = name === "choices" && field.type === "ObjectExpression"
          ? entries(field, "choices").map(([choice, title]) => [choice, literal(title, "choices")])
          : literal(field, `Option “${key}”`);
      }
      return option;
    });
  }

  function manifest(call) {
    if (call.arguments.length !== 1 || call.arguments[0].type !== "ObjectExpression") {
      throw new RuleError("rule() takes one object: rule({ name, block(block) { … } }).", call);
    }
    const result = {};
    let block = null;
    for (const property of call.arguments[0].properties) {
      const name = propertyName(property, "The rule");
      if (name === "block") {
        const value = property.value;
        if (value.type !== "FunctionExpression" && value.type !== "ArrowFunctionExpression") {
          throw new RuleError("block must be a function.", property);
        }
        if (value.async || value.generator) {
          throw new RuleError("block must return its result right away, not later.", property);
        }
        block = value;
      } else if (name === "options") {
        result.options = options(property.value);
      } else if (SETTINGS.has(name)) {
        result[name] = literal(property.value, name);
        if (name === "start") result.stateful = true;
      } else {
        throw new RuleError(`Unknown setting “${name}”.`, property);
      }
    }
    if (!block) throw new RuleError("The rule needs a block function.", call);
    if (result.stateful) result.start = JSON.stringify(result.start);
    return result;
  }

  function compile(source) {
    const tree = acorn.parse(source, {
      ecmaVersion: "latest", sourceType: "script", locations: true,
    });
    const calls = [];
    const edits = [];
    walk(tree, (node, depth) => {
      if (node.type === "Identifier" && node.name.startsWith(RESERVED)) {
        throw new RuleError(`Names starting with ${RESERVED} are reserved.`, node);
      }
      if (node.type === "ImportExpression" || node.type === "MetaProperty") {
        throw new RuleError("Rules can’t load other code.", node);
      }
      if (node.type === "CallExpression" && node.callee.type === "Identifier"
          && node.callee.name === "rule") calls.push(node);
      switch (node.type) {
        case "ForStatement": case "ForInStatement": case "ForOfStatement":
        case "WhileStatement": case "DoWhileStatement":
          guard(node.body, depth, "statement");
          break;
        case "FunctionDeclaration": case "FunctionExpression":
          guard(node.body, depth, "statement");
          break;
        case "ArrowFunctionExpression":
          guard(node.body, depth, node.expression ? "expression" : "statement");
          break;
      }
    });
    if (calls.length !== 1) {
      throw new RuleError(calls.length === 0
        ? "The script must call rule({ … }) once."
        : "The script may call rule() only once.", calls[1] ?? tree);
    }

    function guard(body, depth, form) {
      if (form === "expression") {
        edits.push({ at: body.start, text: "(__meh_tick(), ", depth, closes: false });
        edits.push({ at: body.end, text: ")", depth, closes: true });
      } else if (body.type === "BlockStatement") {
        // After a "use strict" prologue, which must stay first to count.
        let directives = 0;
        while (directives < body.body.length && body.body[directives].directive !== undefined) {
          directives++;
        }
        const at = directives > 0 ? body.body[directives - 1].end : body.start + 1;
        edits.push({ at, text: directives > 0 ? ";__meh_tick();" : "__meh_tick();",
          depth, closes: false });
      } else {
        edits.push({ at: body.start, text: "{__meh_tick();", depth, closes: false });
        edits.push({ at: body.end, text: "}", depth, closes: true });
      }
    }

    // At one position, inner constructs close before outer ones, and
    // everything that closes comes before anything that opens.
    edits.sort((a, b) => a.at - b.at
      || (a.closes === b.closes ? (a.closes ? b.depth - a.depth : a.depth - b.depth)
        : (a.closes ? -1 : 1)));
    let protectedSource = "";
    let cursor = 0;
    for (const edit of edits) {
      protectedSource += source.slice(cursor, edit.at) + edit.text;
      cursor = edit.at;
    }
    protectedSource += source.slice(cursor);
    return { manifest: manifest(calls[0]), source: protectedSource };
  }

  globalThis.compileTextRule = (source) => {
    try {
      return JSON.stringify(compile(source));
    } catch (error) {
      // acorn ends its messages with "(line:column)".
      const message = String(error.message).replace(/ \(\d+:\d+\)$/, "");
      // JavaScriptCore's own `line` would point into acorn.
      const at = error instanceof RuleError ? error : error.loc;
      const line = at?.line;
      const column = at?.column;
      return JSON.stringify({ error: { message, line, column } });
    }
  };
})();
