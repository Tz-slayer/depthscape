// Regression test for DepthCompositorRules.js — run with `node test/compositorrules.test.js`.
//
// The shapes below model a real niri tree: the optional rule lives in an
// included file, uses regex namespace forms, and sits next to unrelated rules.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const src = fs.readFileSync(path.join(__dirname, '..', 'qml', 'DepthCompositorRules.js'), 'utf8');
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);
const R = ctx;

let pass = 0, fail = 0;
function check(name, cond, extra) {
    if (cond) { pass++; console.log('  ok   ' + name); }
    else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  got ' + JSON.stringify(extra) : '')); }
}

const USER_CUSTOM = [
    '// Depthscape and parallax use separate backdrop rules.',
    'layer-rule {',
    '    match namespace="^wallpaper-parallax:canvas$"',
    '    place-within-backdrop true',
    '}',
    '',
    'layer-rule {',
    '    match namespace="^depthscape:"',
    '    place-within-backdrop true',
    '}',
    '',
    'window-rule {',
    '    match app-id=r#"^steam_app_3714815795$"# title=r#"^HoYoPlay$"#',
    '}',
    ''
].join('\n');

const TOP_CONFIG = [
    'input {',
    '    keyboard {',
    '        xkb-layout "us"',
    '    }',
    '}',
    '',
    'include "dms/colors.kdl"',
    'include "dms/layout.kdl"',
    'include "dms/local/custom.kdl"',
    ''
].join('\n');

// ---- findIncludes -----------------------------------------------------------
check('expand the include list', JSON.stringify(R.findIncludes(TOP_CONFIG))
    === JSON.stringify(['dms/colors.kdl', 'dms/layout.kdl', 'dms/local/custom.kdl']),
    R.findIncludes(TOP_CONFIG));

check('includes inside comments do not count', R.findIncludes('// include "x.kdl"\ninclude "y.kdl"').join()
    === 'y.kdl', R.findIncludes('// include "x.kdl"\ninclude "y.kdl"'));

// ---- resolveInclude ---------------------------------------------------------
check('include paths resolve against the including file',
    R.resolveInclude('/home/u/.config/niri/config.kdl', 'dms/local/custom.kdl')
        === '/home/u/.config/niri/dms/local/custom.kdl'
    && R.resolveInclude('/home/u/.config/niri/dms/x.kdl', '../y.kdl')
        === '/home/u/.config/niri/y.kdl'
    && R.resolveInclude('/home/u/.config/niri/config.kdl', '/etc/niri.kdl')
        === '/etc/niri.kdl',
    [R.resolveInclude('/home/u/.config/niri/config.kdl', 'dms/local/custom.kdl'),
        R.resolveInclude('/home/u/.config/niri/dms/x.kdl', '../y.kdl'),
        R.resolveInclude('/home/u/.config/niri/config.kdl', '/etc/niri.kdl')]);

// ---- evaluate ---------------------------------------------------------------
function realTree() {
    return {
        '/home/u/.config/niri/config.kdl': TOP_CONFIG,
        '/home/u/.config/niri/dms/colors.kdl': '',
        '/home/u/.config/niri/dms/layout.kdl': '',
        '/home/u/.config/niri/dms/local/custom.kdl': USER_CUSTOM
    };
}

let r = R.evaluate(realTree());
check("the user's real tree reports ok", r.state === 'ok'
    && r.covered.slice().sort().join() === R.namespaces().slice().sort().join()
    && r.unreadable.length === 0, r);

check('the backdrop rule covers every surface', r.covered.length === R.namespaces().length, r.covered);

r = R.evaluate({
    '/n/config.kdl': 'layer-rule {\n    match namespace=r#"^depthscape:wallpaper$"#\n    place-within-backdrop true\n}'
});
check('a regex that covers one surface is partial', r.state === 'partial'
    && r.covered.join() === 'depthscape:wallpaper', r);

check('a raw-string regex still counts', r.ruleCount === 1, r.ruleCount);

r = R.evaluate({ '/n/config.kdl': 'input { keyboard { xkb-layout "us" } }' });
check('no layer-rule is missing', r.state === 'missing' && r.covered.length === 0, r);

r = R.evaluate({
    '/n/config.kdl': 'layer-rule {\n    match namespace="^depthscape:"\n}'
});
check('namespace rules without place-within-backdrop are missing', r.state === 'missing', r);

r = R.evaluate({
    '/n/config.kdl': 'include "dms/local/custom.kdl"',
    '/n/dms/local/custom.kdl': null
});
check('an unreadable include is unknown, never missing', r.state === 'unknown'
    && r.unreadable.indexOf('/n/dms/local/custom.kdl') !== -1, r);

r = R.evaluate({ '/n/config.kdl': 'include "rules/*.kdl"' });
check('a globbed include cannot be walked, so the answer stays unknown',
    r.state === 'unknown' && r.globbed.join() === 'rules/*.kdl', r);

r = R.evaluate({
    '/n/config.kdl': '// layer-rule { match namespace="^depthscape:" place-within-backdrop true }\n'
        + 'input {}\n// place-within-backdrop true'
});
check('comments that mention the words do not count as a rule', r.state === 'missing', r);

r = R.evaluate({
    '/n/config.kdl': 'layer-rule {\n    match namespace="^depthscape://x"\n}'
});
check('a comment inside a quoted regex is not stripped', r.state === 'missing'
    && r.globbed.length === 0, r);

r = R.evaluate({
    '/n/config.kdl': 'layer-rule {\n    match namespace="^depthscape:"\n    place-within-backdrop true\n}\n'
        + 'layer-rule {\n    match namespace=".*"\n    place-within-backdrop true\n}',
    '/n/other.kdl': ''
});
check('several rules collapse into one verdict', r.state === 'ok' && r.ruleCount === 2, r);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
