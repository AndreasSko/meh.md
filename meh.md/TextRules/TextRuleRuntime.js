// The world a text rule runs in. It loads before the rule's own (already
// protected) script, in a JavaScriptCore context of its own. The host
// passes `__meh_host` with `now()`: the thread's processor time, in
// milliseconds.
//
// Rules see only the text they are given. There is no network, no files,
// no timers, and no clock or random numbers, so the same block always
// gives the same result and results can be kept until the text changes.

(() => {
  const host = globalThis.__meh_host;
  delete globalThis.__meh_host;
  let definition = null;
  // The rule's own top-level code gets a second, then each call its budget.
  let deadline = host.now() + 1000;
  let expired = false;
  let ticks = 0;

  class TooSlow extends Error {}

  Object.defineProperty(globalThis, "__meh_tick", {
    value() {
      if (expired) throw new TooSlow("The rule took too long.");
      if ((++ticks & 1023) !== 0) return;
      if (host.now() > deadline) {
        expired = true;
        throw new TooSlow("The rule took too long.");
      }
    },
  });

  Object.defineProperty(globalThis, "rule", {
    value(value) {
      if (definition) throw new Error("The script may call rule() only once.");
      definition = value;
    },
  });

  // Remove what would make results depend on more than the block.
  delete globalThis.Date;
  Math.random = undefined;
  delete globalThis.WeakRef;
  delete globalThis.FinalizationRegistry;
  delete globalThis.SharedArrayBuffer;
  delete globalThis.Atomics;

  const freeze = (value) => {
    if (value && (typeof value === "object" || typeof value === "function")) {
      Object.freeze(value);
      if (value.prototype) Object.freeze(value.prototype);
    }
  };

  // After the rule's script ran: keep it from changing shared objects, so
  // one call can't leave something behind for the next.
  Object.defineProperty(globalThis, "__meh_seal", {
    value() {
      if (!definition || typeof definition.block !== "function") {
        throw new Error("The script must call rule({ … }) with a block function.");
      }
      for (const name of Object.getOwnPropertyNames(globalThis)) {
        freeze(globalThis[name]);
      }
      freeze(Object.getPrototypeOf(function* () {}));
      freeze(Object.getPrototypeOf([][Symbol.iterator]()));
      Object.freeze(globalThis);
    },
  });

  const describe = (error) => {
    if (error instanceof TooSlow) return { slow: true, message: error.message };
    const message = error instanceof Error ? error.message : String(error);
    // JavaScriptCore reports where an error was thrown in `line`.
    return { message, line: error?.line };
  };

  // Runs `block` for each request in order. A stateful rule passes each
  // block's state to the next, and stops early once the next block was
  // already run with that state before (its `known` incoming states): from
  // there on, the host's earlier results still hold. Running past the batch
  // budget stops with `more: true`, so the host continues later.
  //
  // request: { blocks: [{ block, known? }], state, context, stateful,
  //            blockBudget, batchBudget }
  // The size limit counts UTF-8 bytes, like the host does.
  const utf8Length = (text) => {
    let bytes = 0;
    for (const character of text) {
      const code = character.codePointAt(0);
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    }
    return bytes;
  };

  const finish = (response) => {
    try {
      return JSON.stringify(response);
    } catch (error) {
      return JSON.stringify({ results: [], error: {
        ...describe(error), message: error instanceof TooSlow ? error.message
          : "Decorations must be plain data, like numbers and text." } });
    }
  };

  Object.defineProperty(globalThis, "__meh_run", {
    value(json) {
      const request = JSON.parse(json);
      const results = [];
      let state = request.state === null ? null : JSON.parse(request.state);
      const batchEnd = host.now() + request.batchBudget;
      for (let index = 0; index < request.blocks.length; index++) {
        const item = request.blocks[index];
        expired = false;
        ticks = 0;
        deadline = host.now() + request.blockBudget;
        let output;
        let decorations = [];
        let nextState;
        try {
          output = definition.block(item.block, state, request.context);
          if (output && typeof output.then === "function") {
            throw new Error("block must return its result right away, not a promise.");
          }
          // Reading the result can run the script's own getters too.
          if (output !== undefined && output !== null && typeof output === "object") {
            if (output.decorations !== undefined) decorations = output.decorations;
            nextState = output.state;
          }
        } catch (error) {
          return finish({ results, error: { ...describe(error), index } });
        }
        if (host.now() > deadline) {
          return finish({ results, error: { slow: true, index,
            message: "The rule took too long." } });
        }
        if (output !== undefined && output !== null && typeof output !== "object") {
          return finish({ results, error: { index,
            message: "block must return an object like { decorations: [] }." } });
        }
        let stateJSON;
        if (request.stateful) {
          if (nextState !== undefined) state = nextState;
          try {
            stateJSON = JSON.stringify(state ?? null);
          } catch (error) {
            return finish({ results, error: { index,
              message: "The state must be plain data, like numbers, text and lists." } });
          }
        }
        if (stateJSON !== undefined && utf8Length(stateJSON) > 16384) {
          return finish({ results, error: { index,
            message: "The rule’s state is too large." } });
        }
        // Keep the decorations as they are now; the script could change the
        // same objects in a later block.
        let plain;
        try {
          plain = JSON.stringify(decorations);
        } catch (error) {
          return finish({ results, error: { ...describe(error), index,
            message: error instanceof TooSlow ? error.message
              : "Decorations must be plain data, like numbers and text." } });
        }
        results.push({ decorations: plain, state: stateJSON });
        const next = request.blocks[index + 1];
        if (request.stateful && next?.known?.includes(stateJSON)) break;
        if (next && host.now() > batchEnd) return finish({ results, more: true });
      }
      return finish({ results });
    },
  });
})();
