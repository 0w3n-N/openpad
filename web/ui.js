// Toolbar that fits the screen: on narrower screens, groups of buttons move
// into a pop-over behind one button (e.g. colors and widths on an iPad in
// portrait, and the drawing tools too on a phone).

export function fitToolbar({ button, pop, levels }) {
  const anchors = levels.map(([, groups]) => {
    const a = document.createComment('toolbar');
    groups[0].before(a);
    return a;
  });
  const apply = () => {
    let any = false;
    levels.forEach(([maxWidth, groups], i) => {
      if (window.innerWidth <= maxWidth) {
        pop.append(...groups);
        any = true;
      } else anchors[i].after(...groups);
    });
    button.hidden = !any;
    if (!any) pop.hidden = true;
  };
  window.addEventListener('resize', apply);
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
