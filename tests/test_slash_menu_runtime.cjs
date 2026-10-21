// Execute the generated synthetic row, not just its glossary lookup function.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const [filename, language] = process.argv.slice(2);
assert(filename && language, 'Usage: node tests/test_slash_menu_runtime.cjs <generated.js> <locale>');
const labels = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'resources', 'slash-command-glosses.json'), 'utf8'))[language];
let source = fs.readFileSync(filename, 'utf8');
source = source.replace(/export\s*\{[^}]+\};?/, '');
const jsx = (type, props) => ({ type, props });
const context = vm.createContext({ jsx, HighlightedText: 'highlight' });
vm.runInContext(source + '\nthis.renderRow = row;', context);
function nodes(tree) {
  if (Array.isArray(tree)) return tree.flatMap(nodes);
  if (!tree || typeof tree !== 'object') return [];
  return [tree, ...nodes(tree.props?.children)];
}
let checked = 0;
for (const [name, gloss] of Object.entries(labels)) {
  const selected = [];
  const item = Object.freeze({
    type: 'skill', label: name, skillId: name, anthropicDefined: true,
    onAction: id => selected.push(id),
  });
  const tree = context.renderRow(item, 'mo');
  const descendants = nodes(tree);
  const highlighter = descendants.find(node => node.type === 'highlight');
  assert.equal(highlighter.props.text, name, 'English command name must remain unchanged');
  assert.equal(highlighter.props.query, 'mo', 'Search highlighting must keep the original query');
  const translated = descendants.find(node => node.props?.children === gloss);
  assert(translated, `Missing glossary for ${name}`);
  assert.equal(translated.props.className, 'ms-2 text-muted-as-secondary');
  assert.equal(tree.props.role, 'menuitem');
  tree.props.onClick();
  assert.deepEqual(selected, [name], 'Click must send only the original command ID');
  assert.equal(item.label, name);
  checked++;
}
for (const item of [
  { type: 'skill', label: 'model', anthropicDefined: false },
  { type: 'skill', label: 'model' },
  { type: 'skill', label: 'model', anthropicDefined: 'true' },
  { type: 'connector-tool', label: 'model', anthropicDefined: true },
  ...['custom:skill', 'anthropic-skills:docx', 'unknown-command', 'constructor', 'toString', '__proto__'].map(label => ({ type: 'skill', label, anthropicDefined: true })),
  { type: 'skill', label: null, anthropicDefined: true },
  { type: 'skill', label: { name: 'model' }, anthropicDefined: true },
]) {
  const descendants = nodes(context.renderRow(Object.freeze(item), ''));
  assert(!descendants.some(node => node.props?.className === 'ms-2 text-muted-as-secondary'), 'Custom/unknown/connector labels must not be translated');
  assert.equal(descendants.find(node => node.type === 'highlight').props.text, item.label);
  checked++;
}
console.log(`PASS: ${language} rendered rows and original command clicks (${checked} cases)`);
