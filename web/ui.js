// Toolbar that fits the screen: when the buttons don't fit, groups of them move
// into a pop-over behind one button, in the order of `levels` (e.g. colors and
// widths first, then the drawing tools). It measures instead of using fixed
// screen widths, because a section name in the pager, the Live badge or the
// theme's font all change what fits: `watch` lists what can change on its own.

export function fitToolbar({ bar, button, pop, levels, watch = [] }) {
  const anchors = levels.map((groups) => {
    const a = document.createComment('toolbar');
    groups[0].before(a);
    return a;
  });
  const holder = button.parentElement;
  const show = (on) => {
    button.hidden = !on;
    holder.hidden = !on; // no empty group (and divider) in the toolbar
  };
  const apply = () => {
    if (!bar.clientWidth) return; // not on screen: measured when it is
    levels.forEach((groups, i) => anchors[i].after(...groups));
    show(false);
    let moved = 0;
    while (moved < levels.length && bar.scrollWidth > bar.clientWidth) {
      show(true);
      pop.append(...levels[moved++]);
    }
    for (let i = moved - 1; i >= 0; i--) pop.append(...levels[i]); // the last to move goes first
    if (!moved) pop.hidden = true;
  };
  const observer = new ResizeObserver(apply);
  for (const el of [bar, ...watch]) observer.observe(el);
  apply();
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    pop.hidden = !pop.hidden;
  });
  document.addEventListener('pointerdown', (e) => {
    if (!pop.hidden && !pop.contains(e.target) && !button.contains(e.target)) pop.hidden = true;
  });
  return apply;
}

// Esc closes a dialog without setting returnValue, and Safari keeps the last
// one: an "ok" left over from the previous dialog would read as a yes.
export function showDialog(dlg) {
  dlg.returnValue = '';
  dlg.showModal();
}

// Cancel buttons are type="button", closed here. A form's first submit button
// is the one Return presses, and that must be OK or Save, not Cancel.
export function closeOnCancel() {
  document.addEventListener('click', (e) => {
    const b = e.target.closest?.('dialog button[value="cancel"]');
    if (b) b.closest('dialog').close('cancel');
  });
}

// A modal dialog keeps everything outside it under its backdrop, so a toast
// shown while one is open goes inside it (and comes back out when it closes).
export function placeToast(t) {
  const open = document.querySelectorAll('dialog[open]');
  (open[open.length - 1] || document.body).append(t);
}
