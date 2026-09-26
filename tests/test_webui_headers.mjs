/*
 * Round-trip tests for the headers editor model. No browser needed: the model is
 * pure, so the WebUI's "edit rows and save" path can be checked here.
 *
 *   bun tests/test_webui_headers.mjs
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dir, '..');
await import(join(ROOT, 'payload/webroot/headers.js'));
const H = globalThis.SMSFWHeaders;

let pass = 0;
let fail = 0;
const check = (name, got, want) => {
  if (got === want) { pass++; console.log('  ok   - ' + name); }
  else { fail++; console.log('  FAIL - ' + name + "\n    got  " + JSON.stringify(got) + "\n    want " + JSON.stringify(want)); }
};

// 1. the shipped file must survive a load/save cycle byte for byte
const shipped = readFileSync(join(ROOT, 'payload/config/headers.txt'), 'utf8');
check('shipped headers.txt round-trips byte-identically', H.serialize(H.parse(shipped)), shipped);
check('shipped headers.txt has no entries (all comments)', H.entries(H.parse(shipped)).length, 0);

// 2. a hostile file: interleaved comments, duplicates, empty value, CRLF-less tail
const hostile = [
  '# leading comment',
  'Content-Type: application/json',
  '# comment between entries',
  'X-Api-Key: abc',
  'X-Api-Key: def',
  'X-Empty:',
  '',
  'trailing prose',
].join('\n');
check('hostile file round-trips byte-identically', H.serialize(H.parse(hostile)), hostile);
check('entries are recognised, comments are not', H.entries(H.parse(hostile)).length, 4);

// 3. a file without a trailing newline must not gain one
check('no trailing newline is preserved', H.serialize(H.parse('A: 1')), 'A: 1');
check('trailing newline is preserved', H.serialize(H.parse('A: 1\n')), 'A: 1\n');

// 4. editing one value keeps every other line exactly where it was
const model = H.parse(hostile);
H.entries(model).find((e) => e.name === 'X-Api-Key').value = 'changed';
check('editing rewrites only that entry',
  H.serialize(model),
  hostile.replace('X-Api-Key: abc', 'X-Api-Key: changed'));

// 5. removing an entry removes exactly its line
const model2 = H.parse(hostile);
model2.items = model2.items.filter((item) => !(item.kind === 'entry' && item.name === 'X-Empty'));
check('removing an entry drops only its line',
  H.serialize(model2),
  hostile.split('\n').filter((line) => line !== 'X-Empty:').join('\n'));

console.log('\nheaders model tests: ' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
