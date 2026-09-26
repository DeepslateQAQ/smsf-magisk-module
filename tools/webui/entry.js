/*
 * Entry point for the vendored Material Web bundle.
 *
 * Only the components the WebUI actually uses, so the committed bundle stays as
 * small as it can. Everything is bundled locally: devices must never need a CDN
 * (offline, and a WebView has no business fetching third-party code).
 */
import '@material/web/button/filled-button.js';
import '@material/web/button/filled-tonal-button.js';
import '@material/web/button/outlined-button.js';
import '@material/web/button/text-button.js';
import '@material/web/textfield/outlined-text-field.js';
import '@material/web/switch/switch.js';
import '@material/web/select/outlined-select.js';
import '@material/web/select/select-option.js';
import '@material/web/divider/divider.js';
import '@material/web/progress/linear-progress.js';
import '@material/web/chips/assist-chip.js';
import '@material/web/iconbutton/icon-button.js';

// typography: the Material 3 type scale (classes such as .md-typescale-title-medium)
import { styles as typescale } from '@material/web/typography/md-typescale-styles.js';
document.adoptedStyleSheets.push(typescale.styleSheet);
