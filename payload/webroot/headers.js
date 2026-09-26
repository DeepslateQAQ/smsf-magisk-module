/* Header file model, kept pure so it can be tested without a browser.
 *
 * A headers file is a sequence of lines. Only lines of the form `Name: value`
 * are entries; everything else (comments, blanks, prose) is preserved verbatim,
 * in place. The WebUI edits entries as Key/Value rows and re-emits the file, so
 * comments survive and the shipped file's own documentation is never eaten.
 */
(function () {
  'use strict';

  /* A header name cannot contain ':'; a line starting with '#' is a comment even
     if it looks like an entry (the shipped file documents Content-Type that way). */
  const ENTRY = /^([^:#\s][^:]*):([ \t]*)(.*)$/;

  function parse(text) {
    const lines = String(text == null ? '' : text).split('\n');
    const trailingNewline = lines.length > 0 && lines[lines.length - 1] === '';
    if (trailingNewline) lines.pop();
    const items = lines.map((line) => {
      const match = line.startsWith('#') ? null : ENTRY.exec(line);
      // keep the original spacing after the colon so an untouched entry is
      // re-emitted byte for byte (rows created in the UI default to one space)
      return match
        ? { kind: 'entry', name: match[1].trim(), sep: match[2], value: match[3] }
        : { kind: 'raw', text: line };
    });
    return { items: items, trailingNewline: trailingNewline };
  }

  function serialize(model) {
    const lines = (model.items || []).map((item) => item.kind === 'entry'
      ? item.name + ':' + (item.sep === undefined ? ' ' : item.sep) + item.value
      : item.text);
    return lines.join('\n') + (model.trailingNewline ? '\n' : '');
  }

  /** Round-trip check: parse(serialize(parse(text))) === parse(text). */
  function entries(model) {
    return (model.items || []).filter((item) => item.kind === 'entry');
  }

  globalThis.SMSFWHeaders = { parse: parse, serialize: serialize, entries: entries };
})();
