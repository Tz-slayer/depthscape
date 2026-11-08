// Does the compositor config place our surfaces in Niri's shared backdrop?
//
// WHY THIS EXISTS
//
// Depthscape uses a shared backdrop across workspaces. Check whether a niri
// layer rule places all of its surfaces there, including rules in included files.
//
// This module answers the question by reading the config the way niri does:
// start at `config.kdl` and follow every `include`. It is pure text in, result
// out, so it can be unit-tested without a compositor.
//
// The one thing it deliberately does NOT do is guess. If the top file or any
// include cannot be read, or an include path has a glob niri might expand, the
// answer is "unknown" — an unfounded "missing" would be worse than silence.

const NAMESPACES = ["depthscape:wallpaper", "depthscape:foreground"];

const INCLUDE_RE = /^\s*include\s+"([^"]+)"\s*$/gm;
const SINGLE_QUOTE_INCLUDE_RE = /^\s*include\s+'([^']+)'\s*$/gm;

/// Strip comments without touching quoted strings: a `//` is only a comment
/// when an even number of double quotes precedes it on that line. KDL raw
/// strings (`r#"…"#`) are left alone, which is fine because they contain regexes,
/// not comments.
function stripComments(text) {
    return text.split("\n").map(line => {
        let quoteCount = 0;
        for (let i = 0; i < line.length; i++) {
            const ch = line[i];
            if (ch === '"')
                quoteCount++;
            if (ch === '/' && line[i + 1] === '/' && quoteCount % 2 === 0)
                return line.slice(0, i);
        }
        return line;
    }).join("\n");
}

/// Every `layer-rule { … }` body, brace-matched. Blocks are returned as raw
/// text including any nesting; the caller only needs substring tests.
function layerRuleBodies(text) {
    const clean = stripComments(text);
    const out = [];
    const openRe = /layer-rule\s*\{/g;
    let m;
    while ((m = openRe.exec(clean)) !== null) {
        let depth = 1;
        let i = m.index + m[0].length;
        while (i < clean.length && depth > 0) {
            if (clean[i] === "{")
                depth++;
            else if (clean[i] === "}")
                depth--;
            i++;
        }
        if (depth === 0)
            out.push(clean.slice(m.index + m[0].length, i - 1));
        openRe.lastIndex = i;
    }
    return out;
}

/// Every value on a `namespace=` line, as plain text. Handles the three shapes
/// niri accepts: `"…"`, `'…'` and the KDL raw string `r#"…"#` (regexes full of
/// backslashes and quotes are why the last one exists).
function namespaceValues(body) {
    const values = [];
    const lineRe = /(^|\s)namespace\s*=\s*(?:r#"([^"]*)"#|"([^"]*)"|'([^']*)')/g;
    let m;
    while ((m = lineRe.exec(body)) !== null) {
        if (m[2] !== undefined)
            values.push(m[2]);
        else if (m[3] !== undefined)
            values.push(m[3]);
        else if (m[4] !== undefined)
            values.push(m[4]);
    }
    return values;
}

function hasPlaceWithinBackdrop(body) {
    return /place-within-backdrop\s+true/.test(body)
        || /place-within-backdrop\s*=\s*true/.test(body);
}

/// Does a namespace pattern match a surface name the way niri's regex does?
function patternMatches(pattern, name) {
    if (!pattern)
        return false;
    try {
        return new RegExp(pattern).test(name);
    } catch (error) {
        // A regex niri accepts but JS does not (Rust-only syntax). Fall back to
        // a plain substring test so a working rule is not reported broken.
        return name.indexOf(pattern) !== -1;
    }
}

/// Relative paths this file pulls in. Includes without a path are not niri's
/// shape and are ignored.
// QML's `.js` imports run in a plain QJSEngine script context, which has no
// ESM: functions are exported by simply being top-level declarations, and the
// importer reads them off the resulting object. Same convention as
// `DepthAutoColor.js` and `DepthScrollMath.js` — do not add `export` here.

function findIncludes(text) {
    const out = [];
    const clean = stripComments(text);
    const res = [INCLUDE_RE, SINGLE_QUOTE_INCLUDE_RE];
    for (const re of res) {
        let m;
        while ((m = re.exec(clean)) !== null)
            out.push(m[1]);
    }
    return out;
}

/// True when the include path is something we can resolve to exactly one file.
/// Glob patterns are left to niri: we do not know its directory, so a rule
/// behind a glob makes the answer "unknown" instead of "missing".
function includeHasGlob(path) {
    return path.indexOf("*") !== -1 || path.indexOf("?") !== -1
        || path.indexOf("[") !== -1;
}

function resolveInclude(fromFile, relative) {
    if (relative.startsWith("/"))
        return relative;
    const dir = fromFile.replace(/\/[^/]*$/, "");
    const parts = (dir === "" ? "" : dir + "/") + relative;
    const stack = [];
    for (const part of parts.split("/")) {
        if (part === "" || part === ".")
            continue;
        if (part === "..") {
            stack.pop();
            continue;
        }
        stack.push(part);
    }
    return "/" + stack.join("/");
}

/// The whole check.
///
/// `files` maps absolute path -> text, or -> null when that path could not be
/// read. Every path the walk reached must be present and non-null for the
/// answer to be a verdict; otherwise it is "unknown".
///
/// Returns
///   { state: "ok" | "partial" | "missing" | "unknown",
///     covered: [namespace…],          which surfaces are placed
///     ruleCount, filesRead, unreadable: [path…], globbed: [path…] }
function evaluate(files) {
    const unreadable = Object.keys(files).filter(p => files[p] === null);
    const globbed = [];
    for (const path of Object.keys(files)) {
        const text = files[path];
        if (text === null)
            continue;
        for (const inc of findIncludes(text))
            if (includeHasGlob(inc))
                globbed.push(inc);
    }
    if (unreadable.length > 0 || globbed.length > 0)
        return {
            state: "unknown",
            covered: [],
            ruleCount: 0,
            filesRead: Object.keys(files).length,
            unreadable,
            globbed
        };

    const covered = [];
    let ruleCount = 0;
    let anyRule = false;
    for (const path of Object.keys(files)) {
        for (const body of layerRuleBodies(files[path])) {
            anyRule = true;
            if (!hasPlaceWithinBackdrop(body))
                continue;
            for (const pattern of namespaceValues(body)) {
                for (const name of NAMESPACES) {
                    if (covered.indexOf(name) === -1 && patternMatches(pattern, name))
                        covered.push(name);
                }
            }
        }
    }
    ruleCount = anyRule ? Object.keys(files).reduce((n, p) => n + layerRuleBodies(files[p]).length, 0) : 0;
    let state = "missing";
    if (covered.length === NAMESPACES.length)
        state = "ok";
    else if (covered.length > 0)
        state = "partial";
    return {
        state,
        covered,
        ruleCount,
        filesRead: Object.keys(files).length,
        unreadable: [],
        globbed: []
    };
}

function namespaces() {
    return NAMESPACES.slice();
}
